use std::fs;
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct AppConfig {
    pub auto_start: bool,
    pub web: WebConfig,
    pub vnt: VntConfig,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            auto_start: true,
            web: WebConfig::default(),
            vnt: VntConfig::default(),
        }
    }
}

impl AppConfig {
    pub fn load(path: &Path) -> Result<Self> {
        let content = fs::read_to_string(path)
            .with_context(|| format!("读取配置失败：{}", path.display()))?;
        let config: Self = serde_json::from_str(&content)
            .with_context(|| format!("解析 JSON 配置失败：{}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        self.web.validate()?;
        self.vnt.validate()
    }

    pub async fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let content = serde_json::to_string_pretty(self).context("序列化配置失败")?;
        let temporary_path = path.with_extension("json.tmp");
        tokio::fs::write(&temporary_path, format!("{content}\n"))
            .await
            .with_context(|| format!("写入临时配置失败：{}", temporary_path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&temporary_path, std::fs::Permissions::from_mode(0o600))
                .await
                .with_context(|| format!("设置配置权限失败：{}", temporary_path.display()))?;
        }
        tokio::fs::rename(&temporary_path, path)
            .await
            .with_context(|| format!("替换配置失败：{}", path.display()))?;
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct WebConfig {
    pub listen: IpAddr,
    pub port: u16,
    pub access_token: Option<String>,
}

impl Default for WebConfig {
    fn default() -> Self {
        Self {
            listen: IpAddr::V4(Ipv4Addr::LOCALHOST),
            port: 18080,
            access_token: None,
        }
    }
}

impl WebConfig {
    fn validate(&self) -> Result<()> {
        if self.port == 0 {
            bail!("WebUI 端口不能为 0")
        }

        let token = self.access_token.as_deref().map(str::trim);
        if !self.listen.is_loopback() && token.is_none_or(str::is_empty) {
            bail!("WebUI 监听非本机地址时，access_token 不能为空")
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct VntConfig {
    pub server_addresses: Vec<String>,
    pub network_code: String,
    pub device_id: Option<String>,
    pub device_name: String,
    pub tun_name: String,
    pub virtual_ip: Option<Ipv4Addr>,
    pub password: Option<String>,
    pub channel_mode: ChannelMode,
    pub mtu: u16,
    pub compress: bool,
    pub rtx: bool,
    pub fec: bool,
    pub no_tun: bool,
    pub no_nat: bool,
    pub allow_port_mapping: bool,
    pub udp_stun: Vec<String>,
    pub tcp_stun: Vec<String>,
    pub tunnel_port: Option<u16>,
    pub input_routes: Vec<String>,
    pub output_routes: Vec<String>,
    pub port_mappings: Vec<String>,
}

impl Default for VntConfig {
    fn default() -> Self {
        Self {
            server_addresses: Vec::new(),
            network_code: String::new(),
            device_id: None,
            device_name: "vntc-linux".to_string(),
            tun_name: "vnt0".to_string(),
            virtual_ip: None,
            password: None,
            channel_mode: ChannelMode::All,
            mtu: 1400,
            compress: false,
            rtx: false,
            fec: false,
            no_tun: false,
            no_nat: false,
            allow_port_mapping: false,
            udp_stun: Vec::new(),
            tcp_stun: Vec::new(),
            tunnel_port: None,
            input_routes: Vec::new(),
            output_routes: Vec::new(),
            port_mappings: Vec::new(),
        }
    }
}

impl VntConfig {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.server_addresses.is_empty()
            || self
                .server_addresses
                .iter()
                .any(|address| address.trim().is_empty())
        {
            bail!("至少需要一个非空 server_addresses")
        }
        if self.network_code.trim().is_empty() {
            bail!("network_code 不能为空")
        }
        if self.network_code.chars().count() > 32 {
            bail!("network_code 不能超过 32 个字符")
        }
        if self.device_name.trim().is_empty() || self.device_name.chars().count() > 128 {
            bail!("device_name 长度必须为 1 到 128 个字符")
        }
        if self.tun_name.trim().is_empty() {
            bail!("tun_name 不能为空")
        }
        if !(576..=1500).contains(&self.mtu) {
            bail!("mtu 必须在 576 到 1500 之间")
        }
        if self
            .device_id
            .as_deref()
            .is_some_and(|id| id.chars().count() > 64)
        {
            bail!("device_id 不能超过 64 个字符")
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ChannelMode {
    #[default]
    All,
    RelayOnly,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_config() -> AppConfig {
        let mut config = AppConfig::default();
        config.vnt.server_addresses = vec!["quic://127.0.0.1:2225".to_string()];
        config.vnt.network_code = "test-network".to_string();
        config
    }

    #[test]
    fn accepts_local_webui_with_valid_vnt_config() {
        assert!(valid_config().validate().is_ok());
    }

    #[test]
    fn rejects_remote_webui_without_token() {
        let mut config = valid_config();
        config.web.listen = "0.0.0.0".parse().unwrap();
        config.web.access_token = None;

        let error = config.validate().unwrap_err().to_string();
        assert!(error.contains("access_token"));
    }

    #[test]
    fn accepts_remote_webui_with_short_non_empty_token() {
        let mut config = valid_config();
        config.web.listen = "0.0.0.0".parse().unwrap();
        config.web.access_token = Some("luojiang".to_string());

        assert!(config.validate().is_ok());
    }

    #[test]
    fn rejects_invalid_mtu() {
        let mut config = valid_config();
        config.vnt.mtu = 1600;

        let error = config.validate().unwrap_err().to_string();
        assert!(error.contains("mtu"));
    }

    #[test]
    fn rejects_unknown_json_fields() {
        let json = r#"{
            "web": {"listen": "127.0.0.1", "port": 18080, "access_token": null},
            "vnt": {
                "server_addresses": ["quic://127.0.0.1:2225"],
                "network_code": "test",
                "unexpected": true
            }
        }"#;

        assert!(serde_json::from_str::<AppConfig>(json).is_err());
    }

    #[tokio::test]
    async fn saved_config_can_be_loaded_again() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        let config = valid_config();

        config.save(&path).await.unwrap();
        let loaded = AppConfig::load(&path).unwrap();

        assert_eq!(loaded.vnt.network_code, "test-network");
        assert_eq!(loaded.web.port, 18080);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn saved_config_is_owner_readable_only() {
        use std::os::unix::fs::PermissionsExt;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("config.json");
        valid_config().save(&path).await.unwrap();

        let mode = std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}
