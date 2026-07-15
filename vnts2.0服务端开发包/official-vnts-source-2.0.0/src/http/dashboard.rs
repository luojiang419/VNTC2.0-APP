use parking_lot::Mutex;
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use sysinfo::{Disks, Pid, System};

const STORAGE_REFRESH_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize)]
pub(crate) struct HostResourceSnapshot {
    pub(crate) cpu_percent: Option<f32>,
    pub(crate) memory_used_bytes: u64,
    pub(crate) memory_total_bytes: u64,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProcessResourceSnapshot {
    pub(crate) cpu_percent: Option<f32>,
    pub(crate) memory_bytes: u64,
    pub(crate) threads: Option<u64>,
    pub(crate) handles: Option<u64>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub(crate) struct StorageSnapshot {
    pub(crate) volume_used_bytes: Option<u64>,
    pub(crate) volume_total_bytes: Option<u64>,
    pub(crate) data_bytes: Option<u64>,
    pub(crate) database_bytes: Option<u64>,
    pub(crate) logs_bytes: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ResourceSnapshot {
    pub(crate) host: HostResourceSnapshot,
    pub(crate) process: ProcessResourceSnapshot,
    pub(crate) storage: StorageSnapshot,
}

struct SystemSampler {
    system: System,
    has_cpu_baseline: bool,
}

struct StorageCache {
    sampled_at: Option<Instant>,
    snapshot: StorageSnapshot,
}

pub(crate) struct DashboardSampler {
    data_root: PathBuf,
    system: Mutex<SystemSampler>,
    storage: Mutex<StorageCache>,
}

impl DashboardSampler {
    pub(crate) fn new(data_root: PathBuf) -> Self {
        Self {
            data_root,
            system: Mutex::new(SystemSampler {
                system: System::new(),
                has_cpu_baseline: false,
            }),
            storage: Mutex::new(StorageCache {
                sampled_at: None,
                snapshot: StorageSnapshot::default(),
            }),
        }
    }

    pub(crate) fn sample(&self) -> ResourceSnapshot {
        let (host, process) = self.sample_system();
        ResourceSnapshot {
            host,
            process,
            storage: self.sample_storage(),
        }
    }

    fn sample_system(&self) -> (HostResourceSnapshot, ProcessResourceSnapshot) {
        let mut sampler = self.system.lock();
        sampler.system.refresh_memory();
        sampler.system.refresh_cpu();
        let pid = Pid::from_u32(std::process::id());
        sampler.system.refresh_process(pid);

        let cpu_percent = sampler
            .has_cpu_baseline
            .then(|| sampler.system.global_cpu_info().cpu_usage());
        let process = sampler
            .system
            .process(pid)
            .map(|value| (value.cpu_usage(), value.memory()));
        let process_cpu_percent = sampler
            .has_cpu_baseline
            .then(|| process.map(|value| value.0))
            .flatten();
        let process_memory_bytes = process.map(|value| value.1).unwrap_or_default();
        sampler.has_cpu_baseline = true;

        (
            HostResourceSnapshot {
                cpu_percent,
                memory_used_bytes: sampler.system.used_memory(),
                memory_total_bytes: sampler.system.total_memory(),
            },
            ProcessResourceSnapshot {
                cpu_percent: process_cpu_percent,
                memory_bytes: process_memory_bytes,
                threads: None,
                handles: None,
            },
        )
    }

    fn sample_storage(&self) -> StorageSnapshot {
        let mut cache = self.storage.lock();
        let is_fresh = cache
            .sampled_at
            .is_some_and(|sampled_at| sampled_at.elapsed() < STORAGE_REFRESH_INTERVAL);
        if is_fresh {
            return cache.snapshot.clone();
        }

        cache.snapshot = collect_storage_snapshot(&self.data_root);
        cache.sampled_at = Some(Instant::now());
        cache.snapshot.clone()
    }
}

fn collect_storage_snapshot(data_root: &Path) -> StorageSnapshot {
    let canonical_root = data_root
        .canonicalize()
        .unwrap_or_else(|_| data_root.to_path_buf());
    let disks = Disks::new_with_refreshed_list();
    let volume = disks
        .iter()
        .filter(|disk| canonical_root.starts_with(disk.mount_point()))
        .max_by_key(|disk| disk.mount_point().as_os_str().len());

    StorageSnapshot {
        volume_used_bytes: volume
            .map(|disk| disk.total_space().saturating_sub(disk.available_space())),
        volume_total_bytes: volume.map(|disk| disk.total_space()),
        data_bytes: path_size(&canonical_root),
        database_bytes: path_size(&canonical_root.join("network_control.db")),
        logs_bytes: path_size(&canonical_root.join("logs")),
    }
}

fn path_size(path: &Path) -> Option<u64> {
    if !path.exists() {
        return Some(0);
    }
    let metadata = fs::symlink_metadata(path).ok()?;
    if metadata.file_type().is_symlink() {
        return Some(0);
    }
    if metadata.is_file() {
        return Some(metadata.len());
    }

    let mut total = 0_u64;
    for entry in fs::read_dir(path).ok()? {
        let entry = entry.ok()?;
        total = total.saturating_add(path_size(&entry.path())?);
    }
    Some(total)
}

#[cfg(test)]
mod tests {
    use super::DashboardSampler;
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn first_cpu_sample_is_explicitly_unavailable_and_storage_is_real() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("vnts2-dashboard-{unique}"));
        fs::create_dir_all(root.join("logs")).unwrap();
        fs::write(root.join("network_control.db"), [0_u8; 7]).unwrap();
        fs::write(root.join("logs").join("vnts2.log"), [0_u8; 11]).unwrap();

        let sampler = DashboardSampler::new(root.clone());
        let first = sampler.sample();
        assert_eq!(first.host.cpu_percent, None);
        assert_eq!(first.process.cpu_percent, None);
        assert_eq!(first.storage.database_bytes, Some(7));
        assert_eq!(first.storage.logs_bytes, Some(11));
        assert!(first.storage.data_bytes.is_some_and(|bytes| bytes >= 18));

        fs::remove_dir_all(root).unwrap();
    }
}
