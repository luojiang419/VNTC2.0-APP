use std::collections::VecDeque;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokio::sync::RwLock;

const LOG_CAPACITY: usize = if cfg!(feature = "openwrt") { 64 } else { 500 };

#[derive(Clone, Debug, Serialize)]
pub struct LogEntry {
    pub timestamp_unix: u64,
    pub level: String,
    pub message: String,
}

pub struct RuntimeLog {
    entries: RwLock<VecDeque<LogEntry>>,
}

impl Default for RuntimeLog {
    fn default() -> Self {
        Self {
            entries: RwLock::new(VecDeque::new()),
        }
    }
}

impl RuntimeLog {
    pub async fn push(&self, level: &str, message: impl Into<String>) {
        let mut message = message.into();
        if cfg!(feature = "openwrt") && message.len() > 1024 {
            let mut end = 1024;
            while !message.is_char_boundary(end) {
                end -= 1;
            }
            message.truncate(end);
            message.shrink_to_fit();
        }
        let mut entries = self.entries.write().await;
        if entries.len() >= LOG_CAPACITY {
            entries.pop_front();
        }
        entries.push_back(LogEntry {
            timestamp_unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            level: level.to_string(),
            message,
        });
    }

    pub async fn snapshot(&self) -> Vec<LogEntry> {
        self.entries.read().await.iter().cloned().collect()
    }

    pub async fn clear(&self) {
        self.entries.write().await.clear();
    }

    pub async fn as_text(&self) -> String {
        self.snapshot()
            .await
            .into_iter()
            .map(|entry| {
                format!(
                    "{} [{}] {}",
                    entry.timestamp_unix,
                    entry.level.to_uppercase(),
                    entry.message
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

#[cfg(all(test, feature = "openwrt"))]
mod tests {
    use super::*;

    #[tokio::test]
    async fn bounds_router_logs_without_breaking_utf8() {
        let logs = RuntimeLog::default();
        for index in 0..70 {
            logs.push("info", format!("{index}{}", "网络".repeat(800)))
                .await;
        }
        let entries = logs.snapshot().await;
        assert_eq!(entries.len(), 64);
        assert!(entries[0].message.starts_with('6'));
        assert!(entries.iter().all(|entry| entry.message.len() <= 1024));
        assert!(
            logs.entries
                .read()
                .await
                .iter()
                .all(|entry| entry.message.capacity() <= 1024)
        );
        assert!(logs.as_text().await.contains("网络"));
        logs.clear().await;
        assert!(logs.snapshot().await.is_empty());
    }
}
