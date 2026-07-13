use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct AppSettings {
    pub theme_mode: String,
    pub theme_accent: String,
    pub refresh_interval_seconds: u64,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            theme_mode: "system".to_string(),
            theme_accent: "blue".to_string(),
            refresh_interval_seconds: 5,
        }
    }
}

impl AppSettings {
    pub fn path_for(config_path: &Path) -> PathBuf {
        config_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("settings.json")
    }

    pub fn load(config_path: &Path) -> Result<Self> {
        let path = Self::path_for(config_path);
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = fs::read_to_string(&path)
            .with_context(|| format!("读取 WebUI 设置失败：{}", path.display()))?;
        let settings: Self = serde_json::from_str(&content)
            .with_context(|| format!("解析 WebUI 设置失败：{}", path.display()))?;
        settings.validate()?;
        Ok(settings)
    }

    pub fn validate(&self) -> Result<()> {
        if !["light", "dark", "system"].contains(&self.theme_mode.as_str()) {
            bail!("theme_mode 必须是 light、dark 或 system");
        }
        if !["blue", "green", "purple", "orange"].contains(&self.theme_accent.as_str()) {
            bail!("theme_accent 不受支持");
        }
        if ![2, 5, 10, 30, 60].contains(&self.refresh_interval_seconds) {
            bail!("刷新间隔必须是 2、5、10、30 或 60 秒");
        }
        Ok(())
    }

    pub async fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let content = serde_json::to_string_pretty(self).context("序列化 WebUI 设置失败")?;
        let temporary = path.with_extension("json.tmp");
        tokio::fs::write(&temporary, format!("{content}\n"))
            .await
            .with_context(|| format!("写入 WebUI 设置失败：{}", temporary.display()))?;
        tokio::fs::rename(&temporary, path)
            .await
            .with_context(|| format!("替换 WebUI 设置失败：{}", path.display()))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_supported_appearance_and_intervals() {
        assert!(AppSettings::default().validate().is_ok());
        let mut invalid = AppSettings::default();
        invalid.refresh_interval_seconds = 3;
        assert!(invalid.validate().is_err());
    }
}
