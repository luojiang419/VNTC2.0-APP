use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::config::VntConfig;
use crate::vnt_service::to_core_config;

pub const PROFILE_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct NetworkProfile {
    pub id: String,
    pub name: String,
    pub vnt: VntConfig,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProfileStore {
    pub schema_version: u32,
    pub default_profile_id: String,
    pub next_id: u64,
    pub profiles: Vec<NetworkProfile>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProfileInput {
    pub name: String,
    pub vnt: VntConfig,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProfileBackup {
    pub schema_version: u32,
    pub default_profile_id: String,
    pub profiles: Vec<NetworkProfile>,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportMode {
    Merge,
    Replace,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ImportProfiles {
    pub mode: ImportMode,
    pub backup: ProfileBackup,
}

impl ProfileStore {
    pub fn path_for(config_path: &Path) -> PathBuf {
        config_path
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .join("profiles.json")
    }

    pub fn load_or_migrate(config_path: &Path, legacy: &VntConfig) -> Result<Self> {
        let path = Self::path_for(config_path);
        if path.exists() {
            let content = fs::read_to_string(&path)
                .with_context(|| format!("读取配置档案失败：{}", path.display()))?;
            let store: Self = serde_json::from_str(&content)
                .with_context(|| format!("解析配置档案失败：{}", path.display()))?;
            store.validate()?;
            return Ok(store);
        }

        let store = Self::from_legacy(legacy.clone());
        if config_path.exists() {
            store.save_sync(&path)?;
        }
        Ok(store)
    }

    pub fn from_legacy(vnt: VntConfig) -> Self {
        Self {
            schema_version: PROFILE_SCHEMA_VERSION,
            default_profile_id: "profile-1".to_string(),
            next_id: 2,
            profiles: vec![NetworkProfile {
                id: "profile-1".to_string(),
                name: "默认配置".to_string(),
                vnt,
            }],
        }
    }

    pub fn validate(&self) -> Result<()> {
        if self.schema_version != PROFILE_SCHEMA_VERSION {
            bail!("不支持的配置档案版本：{}", self.schema_version);
        }
        if self.profiles.is_empty() {
            bail!("至少需要保留一个配置");
        }
        if !self
            .profiles
            .iter()
            .any(|profile| profile.id == self.default_profile_id)
        {
            bail!("默认配置不存在");
        }
        let mut ids = HashSet::new();
        for profile in &self.profiles {
            Self::validate_input(&ProfileInput {
                name: profile.name.clone(),
                vnt: profile.vnt.clone(),
            })?;
            if profile.id.trim().is_empty() {
                bail!("配置 ID 不能为空");
            }
            if !ids.insert(&profile.id) {
                bail!("配置 ID 重复：{}", profile.id);
            }
        }
        Ok(())
    }

    pub fn validate_input(input: &ProfileInput) -> Result<()> {
        let name = input.name.trim();
        if name.is_empty() || name.chars().count() > 64 {
            bail!("配置名称长度必须为 1 到 64 个字符");
        }
        input.vnt.validate()?;
        to_core_config(&input.vnt)?;
        Ok(())
    }

    pub fn default_profile(&self) -> &NetworkProfile {
        self.profiles
            .iter()
            .find(|profile| profile.id == self.default_profile_id)
            .expect("validated profile store always has a default")
    }

    pub fn find(&self, id: &str) -> Option<&NetworkProfile> {
        self.profiles.iter().find(|profile| profile.id == id)
    }

    pub fn create(&mut self, input: ProfileInput) -> Result<NetworkProfile> {
        Self::validate_input(&input)?;
        let profile = NetworkProfile {
            id: format!("profile-{}", self.next_id),
            name: input.name.trim().to_string(),
            vnt: input.vnt,
        };
        self.next_id += 1;
        self.profiles.push(profile.clone());
        Ok(profile)
    }

    pub fn update(&mut self, id: &str, input: ProfileInput) -> Result<NetworkProfile> {
        Self::validate_input(&input)?;
        let profile = self
            .profiles
            .iter_mut()
            .find(|profile| profile.id == id)
            .with_context(|| format!("配置不存在：{id}"))?;
        profile.name = input.name.trim().to_string();
        profile.vnt = input.vnt;
        Ok(profile.clone())
    }

    pub fn copy(&mut self, id: &str) -> Result<NetworkProfile> {
        let source = self
            .find(id)
            .with_context(|| format!("配置不存在：{id}"))?
            .clone();
        self.create(ProfileInput {
            name: format!("{} 副本", source.name),
            vnt: source.vnt,
        })
    }

    pub fn remove(&mut self, id: &str) -> Result<()> {
        if self.profiles.len() == 1 {
            bail!("至少需要保留一个配置");
        }
        if id == self.default_profile_id {
            bail!("默认配置不能删除，请先设置其他默认配置");
        }
        let before = self.profiles.len();
        self.profiles.retain(|profile| profile.id != id);
        if before == self.profiles.len() {
            bail!("配置不存在：{id}");
        }
        Ok(())
    }

    pub fn set_default(&mut self, id: &str) -> Result<()> {
        if self.find(id).is_none() {
            bail!("配置不存在：{id}");
        }
        self.default_profile_id = id.to_string();
        Ok(())
    }

    pub fn backup(&self) -> ProfileBackup {
        ProfileBackup {
            schema_version: self.schema_version,
            default_profile_id: self.default_profile_id.clone(),
            profiles: self.profiles.clone(),
        }
    }

    pub fn import(&mut self, request: ImportProfiles) -> Result<()> {
        if request.backup.schema_version != PROFILE_SCHEMA_VERSION {
            bail!("不支持的备份版本：{}", request.backup.schema_version);
        }
        let mut candidate = match request.mode {
            ImportMode::Replace => Self {
                schema_version: PROFILE_SCHEMA_VERSION,
                default_profile_id: request.backup.default_profile_id,
                next_id: 1,
                profiles: request.backup.profiles,
            },
            ImportMode::Merge => {
                let mut value = self.clone();
                for profile in request.backup.profiles {
                    value.create(ProfileInput {
                        name: profile.name,
                        vnt: profile.vnt,
                    })?;
                }
                value
            }
        };
        candidate.recalculate_next_id();
        candidate.validate()?;
        *self = candidate;
        Ok(())
    }

    pub async fn save(&self, path: &Path) -> Result<()> {
        self.validate()?;
        let content = serde_json::to_string_pretty(self).context("序列化配置档案失败")?;
        let temporary = path.with_extension("json.tmp");
        tokio::fs::write(&temporary, format!("{content}\n"))
            .await
            .with_context(|| format!("写入配置档案失败：{}", temporary.display()))?;
        tokio::fs::rename(&temporary, path)
            .await
            .with_context(|| format!("替换配置档案失败：{}", path.display()))?;
        Ok(())
    }

    fn save_sync(&self, path: &Path) -> Result<()> {
        let content = serde_json::to_string_pretty(self).context("序列化配置档案失败")?;
        fs::write(path, format!("{content}\n"))
            .with_context(|| format!("迁移配置档案失败：{}", path.display()))
    }

    fn recalculate_next_id(&mut self) {
        let maximum = self
            .profiles
            .iter()
            .filter_map(|profile| profile.id.strip_prefix("profile-"))
            .filter_map(|value| value.parse::<u64>().ok())
            .max()
            .unwrap_or(0);
        self.next_id = maximum + 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_vnt() -> VntConfig {
        VntConfig {
            server_addresses: vec!["quic://127.0.0.1:2225".to_string()],
            network_code: "test".to_string(),
            device_id: Some("profile-store-test".to_string()),
            ..VntConfig::default()
        }
    }

    #[test]
    fn migrates_legacy_config_into_default_profile() {
        let store = ProfileStore::from_legacy(valid_vnt());
        assert_eq!(store.profiles.len(), 1);
        assert_eq!(store.default_profile().vnt.network_code, "test");
    }

    #[test]
    fn supports_profile_crud_and_default_switch() {
        let mut store = ProfileStore::from_legacy(valid_vnt());
        let created = store
            .create(ProfileInput {
                name: "第二网络".to_string(),
                vnt: valid_vnt(),
            })
            .unwrap();
        store.set_default(&created.id).unwrap();
        store.remove("profile-1").unwrap();
        assert_eq!(store.default_profile_id, created.id);
        assert_eq!(store.profiles.len(), 1);
    }

    #[tokio::test]
    async fn saves_and_loads_profiles() {
        let directory = tempfile::tempdir().unwrap();
        let config_path = directory.path().join("config.json");
        fs::write(&config_path, "{}").unwrap();
        let path = ProfileStore::path_for(&config_path);
        let store = ProfileStore::from_legacy(valid_vnt());
        store.save(&path).await.unwrap();
        let loaded = ProfileStore::load_or_migrate(&config_path, &valid_vnt()).unwrap();
        assert_eq!(loaded.default_profile_id, "profile-1");
    }
}
