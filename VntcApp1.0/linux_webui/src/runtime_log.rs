use std::collections::VecDeque;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokio::sync::RwLock;

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
            entries: RwLock::new(VecDeque::with_capacity(500)),
        }
    }
}

impl RuntimeLog {
    pub async fn push(&self, level: &str, message: impl Into<String>) {
        let mut entries = self.entries.write().await;
        if entries.len() >= 500 {
            entries.pop_front();
        }
        entries.push_back(LogEntry {
            timestamp_unix: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            level: level.to_string(),
            message: message.into(),
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
