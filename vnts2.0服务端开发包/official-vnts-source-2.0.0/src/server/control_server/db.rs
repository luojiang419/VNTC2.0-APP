use anyhow::{Context, ensure};
use fs2::FileExt;
use futures::TryStreamExt;
use ipnet::Ipv4Net;
use once_cell::sync::OnceCell;
use serde::{Deserialize, Serialize};
use sqlx_core::{query::query, row::Row};
use sqlx_sqlite::{SqlitePool, SqlitePoolOptions, SqliteRow};
use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;

mod migrations;

static DB_POOL: OnceCell<SqlitePool> = OnceCell::new();
static DB_PROCESS_LOCK: OnceCell<File> = OnceCell::new();
const DB_FILE: &str = "network_control.db";
const DB_LOCK_FILE: &str = "network_control.db.lock";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum NetworkSource {
    Config = 0,
    Manual = 1,
    DeviceRegister = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PeerServerSource {
    Config = 0,
    Manual = 1,
}

impl PeerServerSource {
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => PeerServerSource::Config,
            1 => PeerServerSource::Manual,
            _ => PeerServerSource::Config,
        }
    }

    #[allow(dead_code)]
    pub fn as_str(&self) -> &'static str {
        match self {
            PeerServerSource::Config => "config",
            PeerServerSource::Manual => "manual",
        }
    }
}

impl NetworkSource {
    pub fn from_i32(value: i32) -> Self {
        match value {
            0 => NetworkSource::Config,
            1 => NetworkSource::Manual,
            2 => NetworkSource::DeviceRegister,
            _ => NetworkSource::Config,
        }
    }

    #[allow(dead_code)]
    pub fn as_str(&self) -> &'static str {
        match self {
            NetworkSource::Config => "config",
            NetworkSource::Manual => "manual",
            NetworkSource::DeviceRegister => "device_register",
        }
    }
}

#[derive(Debug, Clone)]
pub struct NetworkRecord {
    pub network_code: String,
    pub gateway: String,
    pub netmask: u8,
    pub lease_duration: i64,
    pub source: NetworkSource,
    pub created_at: i64,
}

impl NetworkRecord {
    pub fn to_ipv4_net(&self) -> Option<Ipv4Net> {
        let gateway: Ipv4Addr = self.gateway.parse().ok()?;
        let network_ip = Ipv4Addr::from(u32::from(gateway) - 1);
        Ipv4Net::new(network_ip, self.netmask).ok()
    }
}

#[derive(Debug, Clone)]
pub struct DeviceRecord {
    pub device_id: String,
    pub network_code: String,
    pub ip: Option<String>,
    pub device_name: String,
    pub device_version: String,
    pub last_connect_time: i64,
    pub tx_bytes: i64,
    pub rx_bytes: i64,
}

#[derive(Debug, Clone)]
pub struct PeerServerRecord {
    pub server_addr: String,
    pub source: PeerServerSource,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClusterLeaseRequest {
    pub network_code: String,
    pub owner_type: String,
    pub owner_id: String,
    pub requested_ip: Option<Ipv4Addr>,
    pub network: Ipv4Net,
    pub gateway: Ipv4Addr,
    pub lease_duration_secs: u64,
    pub static_reservation: bool,
    pub authority_id: String,
    pub origin_server_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClusterLeaseGrant {
    pub ip: Ipv4Addr,
    pub revision: u64,
    pub expires_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalIpAllocation {
    pub network_code: String,
    pub owner_type: String,
    pub owner_id: String,
    pub ip: Ipv4Addr,
    pub network: Ipv4Net,
    pub gateway: Ipv4Addr,
    pub lease_duration_secs: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireGuardPeerIpAllocation {
    pub peer_id: String,
    pub ip: Ipv4Addr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireGuardPeerRecord {
    pub network_code: String,
    pub peer_id: String,
    pub public_key: [u8; 32],
    pub enabled: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WireGuardPeerRouteRecord {
    pub lan_network: Ipv4Net,
    pub vnt_cli_ip: Ipv4Addr,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireGuardPeerProfileRecord {
    pub network_code: String,
    pub peer_id: String,
    pub dns_servers: Option<Vec<IpAddr>>,
    pub persistent_keepalive: u16,
    pub routes: Vec<WireGuardPeerRouteRecord>,
    pub config_available: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct EncryptedWireGuardPeerSecret {
    pub network_code: String,
    pub peer_id: String,
    pub format_version: i64,
    pub encryption_key_version: i64,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub public_key: Vec<u8>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireGuardRuntimePeer {
    pub network_code: String,
    pub peer_id: String,
    pub public_key: [u8; 32],
    pub ip: Ipv4Addr,
    pub routes: Vec<WireGuardPeerRouteRecord>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WireGuardPeerDeleteResult {
    pub peer_removed: bool,
    pub ip_released: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct EncryptedWireGuardIdentity {
    pub format_version: i64,
    pub encryption_key_version: i64,
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub public_key: Vec<u8>,
    pub created_at: i64,
    pub updated_at: i64,
}

pub async fn init_db_pool() -> anyhow::Result<()> {
    if DB_POOL.get().is_some() {
        return Ok(());
    }
    let database_lock = acquire_database_process_lock(Path::new(DB_LOCK_FILE))?;
    if !Path::new(DB_FILE).exists() {
        log::info!("Create database");
        std::fs::File::create(DB_FILE)?;
    }
    let database_url = format!("sqlite://{}", DB_FILE);
    log::info!("Initializing database pool {database_url}");
    let pool = SqlitePoolOptions::new()
        .max_connections(5)
        .connect(&database_url)
        .await
        .context("Failed to connect to SQLite database")?;

    query(
        "CREATE TABLE IF NOT EXISTS networks (
            network_code TEXT PRIMARY KEY,
            gateway TEXT NOT NULL,
            netmask INTEGER NOT NULL,
            lease_duration INTEGER NOT NULL,
            source INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        )",
    )
    .execute(&pool)
    .await
    .context("Failed to create networks table")?;

    // migration: 旧表可能缺少 source 字段
    let _ = query("ALTER TABLE networks ADD COLUMN source INTEGER NOT NULL DEFAULT 0")
        .execute(&pool)
        .await;

    query(
        "CREATE TABLE IF NOT EXISTS devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            network_code TEXT NOT NULL,
            ip TEXT,
            device_name TEXT NOT NULL,
            device_version TEXT NOT NULL,
            last_connect_time INTEGER NOT NULL,
            tx_bytes INTEGER NOT NULL DEFAULT 0,
            rx_bytes INTEGER NOT NULL DEFAULT 0,
            UNIQUE(device_id, network_code)
        )",
    )
    .execute(&pool)
    .await
    .context("Failed to create devices table")?;

    query(
        "CREATE TABLE IF NOT EXISTS peer_servers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server_addr TEXT NOT NULL UNIQUE,
            source INTEGER NOT NULL DEFAULT 0,
            created_at INTEGER NOT NULL
        )",
    )
    .execute(&pool)
    .await
    .context("Failed to create peer_servers table")?;

    migrations::apply(&pool).await?;

    DB_PROCESS_LOCK
        .set(database_lock)
        .map_err(|_| anyhow::anyhow!("Database process lock was initialized concurrently"))?;
    DB_POOL
        .set(pool)
        .map_err(|_| anyhow::anyhow!("SQLite database pool was initialized concurrently"))?;
    Ok(())
}

pub(crate) fn database_exists() -> bool {
    Path::new(DB_FILE).is_file()
}

fn acquire_database_process_lock(path: &Path) -> anyhow::Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(path)
        .with_context(|| format!("Failed to open database process lock: {}", path.display()))?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(file),
        Err(error) if database_process_lock_is_contended(&error) => anyhow::bail!(
            "Database is already in use by another VNTS process; stop the service before rotation"
        ),
        Err(error) => Err(error)
            .with_context(|| format!("Failed to lock database process file: {}", path.display())),
    }
}

fn database_process_lock_is_contended(error: &std::io::Error) -> bool {
    if error.kind() == ErrorKind::WouldBlock {
        return true;
    }

    #[cfg(windows)]
    {
        // Windows reports a competing LockFileEx region as ERROR_LOCK_VIOLATION
        // instead of ErrorKind::WouldBlock. ERROR_SHARING_VIOLATION is accepted
        // as the equivalent whole-file contention signal.
        return matches!(error.raw_os_error(), Some(32 | 33));
    }

    #[cfg(not(windows))]
    false
}

pub(super) fn db_pool() -> anyhow::Result<&'static SqlitePool> {
    DB_POOL
        .get()
        .context("SQLite database pool is not initialized")
}

pub(super) async fn load_wireguard_server_identity_with_pool(
    pool: &SqlitePool,
) -> anyhow::Result<Option<EncryptedWireGuardIdentity>> {
    let row = query(
        "SELECT format_version, encryption_key_version, nonce, ciphertext, public_key,
                created_at, updated_at
         FROM wireguard_server_identity WHERE id = 1",
    )
    .fetch_optional(pool)
    .await
    .context("Failed to load encrypted WireGuard server identity")?;

    row.map(|row| -> anyhow::Result<_> {
        Ok(EncryptedWireGuardIdentity {
            format_version: row.try_get("format_version")?,
            encryption_key_version: row.try_get("encryption_key_version")?,
            nonce: row.try_get("nonce")?,
            ciphertext: row.try_get("ciphertext")?,
            public_key: row.try_get("public_key")?,
            created_at: row.try_get("created_at")?,
            updated_at: row.try_get("updated_at")?,
        })
    })
    .transpose()
    .context("Invalid encrypted WireGuard server identity record")
}

pub(super) async fn insert_wireguard_server_identity_if_absent_with_pool(
    pool: &SqlitePool,
    record: &EncryptedWireGuardIdentity,
) -> anyhow::Result<bool> {
    let result = query(
        "INSERT OR IGNORE INTO wireguard_server_identity (
            id, format_version, encryption_key_version, nonce, ciphertext, public_key,
            created_at, updated_at
         ) VALUES (1, ?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(record.format_version)
    .bind(record.encryption_key_version)
    .bind(&record.nonce)
    .bind(&record.ciphertext)
    .bind(&record.public_key)
    .bind(record.created_at)
    .bind(record.updated_at)
    .execute(pool)
    .await
    .context("Failed to persist encrypted WireGuard server identity")?;
    Ok(result.rows_affected() == 1)
}

pub(super) async fn replace_wireguard_server_identity_with_pool(
    pool: &SqlitePool,
    current: &EncryptedWireGuardIdentity,
    replacement: &EncryptedWireGuardIdentity,
) -> anyhow::Result<()> {
    let result = query(
        "UPDATE wireguard_server_identity
         SET format_version = ?, encryption_key_version = ?, nonce = ?, ciphertext = ?,
             public_key = ?, created_at = ?, updated_at = ?
         WHERE id = 1
           AND format_version = ?
           AND encryption_key_version = ?
           AND nonce = ?
           AND ciphertext = ?
           AND public_key = ?
           AND created_at = ?
           AND updated_at = ?",
    )
    .bind(replacement.format_version)
    .bind(replacement.encryption_key_version)
    .bind(&replacement.nonce)
    .bind(&replacement.ciphertext)
    .bind(&replacement.public_key)
    .bind(replacement.created_at)
    .bind(replacement.updated_at)
    .bind(current.format_version)
    .bind(current.encryption_key_version)
    .bind(&current.nonce)
    .bind(&current.ciphertext)
    .bind(&current.public_key)
    .bind(current.created_at)
    .bind(current.updated_at)
    .execute(pool)
    .await
    .context("Failed to atomically replace WireGuard server identity")?;
    anyhow::ensure!(
        result.rows_affected() == 1,
        "WireGuard server identity changed concurrently; rotation was not applied"
    );
    Ok(())
}

pub(super) async fn replace_wireguard_identity_and_peer_secrets_with_pool(
    pool: &SqlitePool,
    current: &EncryptedWireGuardIdentity,
    replacement: &EncryptedWireGuardIdentity,
    peer_secrets: &[EncryptedWireGuardPeerSecret],
) -> anyhow::Result<()> {
    let mut transaction = pool.begin().await?;
    let result = query(
        "UPDATE wireguard_server_identity
         SET format_version = ?, encryption_key_version = ?, nonce = ?, ciphertext = ?,
             public_key = ?, created_at = ?, updated_at = ?
         WHERE id = 1
           AND format_version = ? AND encryption_key_version = ?
           AND nonce = ? AND ciphertext = ? AND public_key = ?
           AND created_at = ? AND updated_at = ?",
    )
    .bind(replacement.format_version)
    .bind(replacement.encryption_key_version)
    .bind(&replacement.nonce)
    .bind(&replacement.ciphertext)
    .bind(&replacement.public_key)
    .bind(replacement.created_at)
    .bind(replacement.updated_at)
    .bind(current.format_version)
    .bind(current.encryption_key_version)
    .bind(&current.nonce)
    .bind(&current.ciphertext)
    .bind(&current.public_key)
    .bind(current.created_at)
    .bind(current.updated_at)
    .execute(&mut *transaction)
    .await?;
    ensure!(
        result.rows_affected() == 1,
        "WireGuard server identity changed concurrently; rotation was not applied"
    );
    for secret in peer_secrets {
        let result = query(
            "UPDATE wireguard_peer_secrets SET
                 format_version = ?, encryption_key_version = ?, nonce = ?, ciphertext = ?,
                 public_key = ?, updated_at = ?
             WHERE network_code = ? AND peer_id = ?",
        )
        .bind(secret.format_version)
        .bind(secret.encryption_key_version)
        .bind(&secret.nonce)
        .bind(&secret.ciphertext)
        .bind(&secret.public_key)
        .bind(secret.updated_at)
        .bind(&secret.network_code)
        .bind(&secret.peer_id)
        .execute(&mut *transaction)
        .await?;
        ensure!(
            result.rows_affected() == 1,
            "WireGuard peer secret disappeared during master-key rotation"
        );
    }
    transaction.commit().await?;
    Ok(())
}

#[cfg(test)]
pub(super) async fn wireguard_identity_test_pool() -> SqlitePool {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    query(
        "CREATE TABLE devices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            device_id TEXT NOT NULL,
            network_code TEXT NOT NULL,
            ip TEXT,
            device_name TEXT NOT NULL,
            device_version TEXT NOT NULL,
            last_connect_time INTEGER NOT NULL,
            tx_bytes INTEGER NOT NULL DEFAULT 0,
            rx_bytes INTEGER NOT NULL DEFAULT 0,
            UNIQUE(device_id, network_code)
        )",
    )
    .execute(&pool)
    .await
    .unwrap();
    migrations::apply(&pool).await.unwrap();
    pool
}

pub async fn save_network(record: &NetworkRecord) -> anyhow::Result<()> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(());
    };

    query(
        r#"INSERT OR REPLACE INTO networks (network_code, gateway, netmask, lease_duration, source, created_at)
           VALUES (?, ?, ?, ?, ?, ?)"#,
    )
    .bind(&record.network_code)
    .bind(&record.gateway)
    .bind(record.netmask as i32)
    .bind(record.lease_duration)
    .bind(record.source as i32)
    .bind(record.created_at)
    .execute(pool)
    .await
    .context("Failed to save network")?;

    Ok(())
}

pub async fn save_network_if_not_exists(record: &NetworkRecord) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(
        r#"INSERT OR IGNORE INTO networks (network_code, gateway, netmask, lease_duration, source, created_at)
           VALUES (?, ?, ?, ?, ?, ?)"#,
    )
    .bind(&record.network_code)
    .bind(&record.gateway)
    .bind(record.netmask as i32)
    .bind(record.lease_duration)
    .bind(record.source as i32)
    .bind(record.created_at)
    .execute(pool)
    .await
    .context("Failed to save network")?;

    Ok(result.rows_affected() > 0)
}

pub async fn update_network(
    network_code: &str,
    gateway: &str,
    netmask: u8,
    lease_duration: i64,
) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(
        r#"UPDATE networks SET gateway = ?, netmask = ?, lease_duration = ? WHERE network_code = ?"#,
    )
    .bind(gateway)
    .bind(netmask as i32)
    .bind(lease_duration)
    .bind(network_code)
    .execute(pool)
    .await
    .context("Failed to update network")?;

    Ok(result.rows_affected() > 0)
}

pub async fn delete_network(network_code: &str) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(r#"DELETE FROM networks WHERE network_code = ?"#)
        .bind(network_code)
        .execute(pool)
        .await
        .context("Failed to delete network")?;

    Ok(result.rows_affected() > 0)
}

#[allow(dead_code)]
pub async fn get_network(network_code: &str) -> anyhow::Result<Option<NetworkRecord>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(None);
    };

    let row_option = query(
        r#"SELECT network_code, gateway, netmask, lease_duration, source, created_at FROM networks WHERE network_code = ?"#,
    )
    .bind(network_code)
    .fetch_optional(pool)
    .await
    .context("Failed to fetch network")?;

    match row_option {
        Some(row) => {
            let netmask: i32 = row.get("netmask");
            let source: i32 = row.get("source");
            Ok(Some(NetworkRecord {
                network_code: row.get("network_code"),
                gateway: row.get("gateway"),
                netmask: netmask as u8,
                lease_duration: row.get("lease_duration"),
                source: NetworkSource::from_i32(source),
                created_at: row.get("created_at"),
            }))
        }
        None => Ok(None),
    }
}

pub async fn load_all_networks() -> anyhow::Result<Vec<NetworkRecord>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(Vec::new());
    };

    let records: Vec<NetworkRecord> = query(
        r#"SELECT network_code, gateway, netmask, lease_duration, source, created_at FROM networks ORDER BY created_at"#,
    )
    .fetch(pool)
    .try_filter_map(|row| async move {
        let netmask: i32 = row.try_get("netmask")?;
        let source: i32 = row.try_get("source")?;
        Ok(Some(NetworkRecord {
            network_code: row.try_get("network_code")?,
            gateway: row.try_get("gateway")?,
            netmask: netmask as u8,
            lease_duration: row.try_get("lease_duration")?,
            source: NetworkSource::from_i32(source),
            created_at: row.try_get("created_at")?,
        }))
    })
    .try_collect()
    .await
    .context("Failed to load all networks")?;

    Ok(records)
}

async fn network_has_resource_owners_with_pool(
    pool: &SqlitePool,
    network_code: &str,
) -> anyhow::Result<bool> {
    let row = query(
        r#"SELECT (
               EXISTS(SELECT 1 FROM devices WHERE network_code = ?)
               OR EXISTS(SELECT 1 FROM ip_allocations WHERE network_code = ?)
               OR EXISTS(SELECT 1 FROM wireguard_peers WHERE network_code = ?)
           ) AS occupied"#,
    )
    .bind(network_code)
    .bind(network_code)
    .bind(network_code)
    .fetch_one(pool)
    .await
    .context("Failed to check network resource owners")?;

    let occupied: bool = row.get("occupied");
    Ok(occupied)
}

pub async fn network_has_resource_owners(network_code: &str) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };
    network_has_resource_owners_with_pool(pool, network_code).await
}

fn wireguard_peer_from_row(row: SqliteRow) -> anyhow::Result<WireGuardPeerRecord> {
    let public_key: Vec<u8> = row.try_get("public_key")?;
    let public_key: [u8; 32] = public_key
        .try_into()
        .map_err(|_| anyhow::anyhow!("Invalid WireGuard peer public key length"))?;
    let enabled: i64 = row.try_get("enabled")?;
    ensure!(
        matches!(enabled, 0 | 1),
        "Invalid WireGuard peer enabled value: {enabled}"
    );
    Ok(WireGuardPeerRecord {
        network_code: row.try_get("network_code")?,
        peer_id: row.try_get("peer_id")?,
        public_key,
        enabled: enabled == 1,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

async fn insert_wireguard_peer_with_pool(
    pool: &SqlitePool,
    record: &WireGuardPeerRecord,
) -> anyhow::Result<()> {
    ensure!(
        !record.peer_id.trim().is_empty(),
        "WireGuard peer ID 不能为空"
    );
    let result = query(
        "INSERT INTO wireguard_peers (
            network_code, peer_id, public_key, enabled, created_at, updated_at
         )
         SELECT ?, ?, ?, ?, ?, ?
         WHERE EXISTS(SELECT 1 FROM networks WHERE network_code = ?)",
    )
    .bind(&record.network_code)
    .bind(&record.peer_id)
    .bind(record.public_key.as_slice())
    .bind(i64::from(record.enabled))
    .bind(record.created_at)
    .bind(record.updated_at)
    .bind(&record.network_code)
    .execute(pool)
    .await
    .with_context(|| {
        format!(
            "Failed to create WireGuard peer '{}' in network '{}'",
            record.peer_id, record.network_code
        )
    })?;
    ensure!(
        result.rows_affected() == 1,
        "Network '{}' does not exist",
        record.network_code
    );
    Ok(())
}

pub async fn insert_wireguard_peer(record: &WireGuardPeerRecord) -> anyhow::Result<()> {
    insert_wireguard_peer_with_pool(db_pool()?, record).await
}

pub async fn insert_wireguard_peer_with_ip(
    record: &WireGuardPeerRecord,
    ip: Ipv4Addr,
) -> anyhow::Result<()> {
    ensure!(
        !record.peer_id.trim().is_empty(),
        "WireGuard peer ID 不能为空"
    );
    let mut transaction = db_pool()?
        .begin()
        .await
        .context("Failed to start generated WireGuard peer transaction")?;
    let peer_result = query(
        "INSERT INTO wireguard_peers (
            network_code, peer_id, public_key, enabled, created_at, updated_at
         )
         SELECT ?, ?, ?, ?, ?, ?
         WHERE EXISTS(SELECT 1 FROM networks WHERE network_code = ?)",
    )
    .bind(&record.network_code)
    .bind(&record.peer_id)
    .bind(record.public_key.as_slice())
    .bind(i64::from(record.enabled))
    .bind(record.created_at)
    .bind(record.updated_at)
    .bind(&record.network_code)
    .execute(&mut *transaction)
    .await
    .with_context(|| {
        format!(
            "Failed to create generated WireGuard peer '{}' in network '{}'",
            record.peer_id, record.network_code
        )
    })?;
    ensure!(
        peer_result.rows_affected() == 1,
        "Network '{}' does not exist",
        record.network_code
    );
    query(
        "INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
         VALUES (?, ?, 'wireguard_peer', ?)",
    )
    .bind(&record.network_code)
    .bind(ip.to_string())
    .bind(&record.peer_id)
    .execute(&mut *transaction)
    .await
    .with_context(|| {
        format!(
            "Failed to reserve IP {ip} for generated WireGuard peer '{}' in network '{}'",
            record.peer_id, record.network_code
        )
    })?;
    transaction
        .commit()
        .await
        .context("Failed to commit generated WireGuard peer transaction")?;
    Ok(())
}

async fn load_wireguard_peers_with_pool(
    pool: &SqlitePool,
    network_code: &str,
) -> anyhow::Result<Vec<WireGuardPeerRecord>> {
    let rows = query(
        "SELECT network_code, peer_id, public_key, enabled, created_at, updated_at
         FROM wireguard_peers
         WHERE network_code = ?
         ORDER BY peer_id",
    )
    .bind(network_code)
    .fetch_all(pool)
    .await
    .context("Failed to load WireGuard peers")?;
    rows.into_iter().map(wireguard_peer_from_row).collect()
}

pub async fn load_wireguard_peers(network_code: &str) -> anyhow::Result<Vec<WireGuardPeerRecord>> {
    load_wireguard_peers_with_pool(db_pool()?, network_code).await
}

async fn load_wireguard_peer_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<Option<WireGuardPeerRecord>> {
    query(
        "SELECT network_code, peer_id, public_key, enabled, created_at, updated_at
         FROM wireguard_peers
         WHERE network_code = ? AND peer_id = ?",
    )
    .bind(network_code)
    .bind(peer_id)
    .fetch_optional(pool)
    .await
    .context("Failed to load WireGuard peer")?
    .map(wireguard_peer_from_row)
    .transpose()
}

pub async fn load_wireguard_peer(
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<Option<WireGuardPeerRecord>> {
    load_wireguard_peer_with_pool(db_pool()?, network_code, peer_id).await
}

async fn load_wireguard_peer_by_public_key_with_pool(
    pool: &SqlitePool,
    public_key: &[u8; 32],
) -> anyhow::Result<Option<WireGuardPeerRecord>> {
    query(
        "SELECT network_code, peer_id, public_key, enabled, created_at, updated_at
         FROM wireguard_peers
         WHERE public_key = ?",
    )
    .bind(public_key.as_slice())
    .fetch_optional(pool)
    .await
    .context("Failed to load WireGuard peer by public key")?
    .map(wireguard_peer_from_row)
    .transpose()
}

#[allow(dead_code)]
pub async fn load_wireguard_peer_by_public_key(
    public_key: &[u8; 32],
) -> anyhow::Result<Option<WireGuardPeerRecord>> {
    load_wireguard_peer_by_public_key_with_pool(db_pool()?, public_key).await
}

pub async fn load_wireguard_runtime_peer_by_public_key(
    public_key: &[u8; 32],
) -> anyhow::Result<Option<WireGuardRuntimePeer>> {
    let row = query(
        "SELECT p.network_code, p.peer_id, p.public_key, a.ip
         FROM wireguard_peers p
         INNER JOIN ip_allocations a
           ON a.network_code = p.network_code
          AND a.owner_type = 'wireguard_peer'
          AND a.owner_id = p.peer_id
         WHERE p.public_key = ? AND p.enabled = 1",
    )
    .bind(public_key.as_slice())
    .fetch_optional(db_pool()?)
    .await
    .context("Failed to load WireGuard runtime peer")?;

    let Some(row) = row else {
        return Ok(None);
    };
    let stored_public_key: Vec<u8> = row.try_get("public_key")?;
    let stored_public_key = stored_public_key
        .try_into()
        .map_err(|_| anyhow::anyhow!("Invalid WireGuard peer public key length"))?;
    let ip_text: String = row.try_get("ip")?;
    let network_code: String = row.try_get("network_code")?;
    let peer_id: String = row.try_get("peer_id")?;
    let mut routes = query(
        "SELECT lan_network, vnt_cli_ip FROM wireguard_peer_routes
         WHERE network_code = ? AND peer_id = ? ORDER BY sort_order, lan_network",
    )
    .bind(&network_code)
    .bind(&peer_id)
    .fetch_all(db_pool()?)
    .await
    .context("Failed to load WireGuard runtime peer routes")?
    .into_iter()
    .map(|row| {
        Ok(WireGuardPeerRouteRecord {
            lan_network: row.get::<String, _>("lan_network").parse()?,
            vnt_cli_ip: row.get::<String, _>("vnt_cli_ip").parse()?,
        })
    })
    .collect::<anyhow::Result<Vec<_>>>()?;
    routes.sort_by_key(|route| std::cmp::Reverse(route.lan_network.prefix_len()));
    Ok(Some(WireGuardRuntimePeer {
        network_code,
        peer_id,
        public_key: stored_public_key,
        ip: ip_text
            .parse()
            .with_context(|| format!("Invalid WireGuard runtime peer IPv4 address: {ip_text}"))?,
        routes,
    }))
}

async fn set_wireguard_peer_enabled_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    peer_id: &str,
    enabled: bool,
    updated_at: i64,
) -> anyhow::Result<bool> {
    let result = query(
        "UPDATE wireguard_peers
         SET enabled = ?, updated_at = ?
         WHERE network_code = ? AND peer_id = ?",
    )
    .bind(i64::from(enabled))
    .bind(updated_at)
    .bind(network_code)
    .bind(peer_id)
    .execute(pool)
    .await
    .context("Failed to update WireGuard peer enabled state")?;
    Ok(result.rows_affected() == 1)
}

pub async fn set_wireguard_peer_enabled(
    network_code: &str,
    peer_id: &str,
    enabled: bool,
    updated_at: i64,
) -> anyhow::Result<bool> {
    set_wireguard_peer_enabled_with_pool(db_pool()?, network_code, peer_id, enabled, updated_at)
        .await
}

async fn delete_wireguard_peer_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<WireGuardPeerDeleteResult> {
    let mut transaction = pool
        .begin()
        .await
        .context("Failed to start WireGuard peer deletion transaction")?;
    query("DELETE FROM wireguard_peer_routes WHERE network_code = ? AND peer_id = ?")
        .bind(network_code)
        .bind(peer_id)
        .execute(&mut *transaction)
        .await?;
    query("DELETE FROM wireguard_peer_secrets WHERE network_code = ? AND peer_id = ?")
        .bind(network_code)
        .bind(peer_id)
        .execute(&mut *transaction)
        .await?;
    query("DELETE FROM wireguard_peer_profiles WHERE network_code = ? AND peer_id = ?")
        .bind(network_code)
        .bind(peer_id)
        .execute(&mut *transaction)
        .await?;
    let peer_result = query(
        "DELETE FROM wireguard_peers
         WHERE network_code = ? AND peer_id = ?",
    )
    .bind(network_code)
    .bind(peer_id)
    .execute(&mut *transaction)
    .await
    .context("Failed to delete WireGuard peer")?;
    let ip_result = query(
        "DELETE FROM ip_allocations
         WHERE network_code = ? AND owner_type = 'wireguard_peer' AND owner_id = ?",
    )
    .bind(network_code)
    .bind(peer_id)
    .execute(&mut *transaction)
    .await
    .context("Failed to release deleted WireGuard peer IP")?;
    transaction
        .commit()
        .await
        .context("Failed to commit WireGuard peer deletion")?;
    Ok(WireGuardPeerDeleteResult {
        peer_removed: peer_result.rows_affected() == 1,
        ip_released: ip_result.rows_affected() > 0,
    })
}

pub async fn delete_wireguard_peer(
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<WireGuardPeerDeleteResult> {
    delete_wireguard_peer_with_pool(db_pool()?, network_code, peer_id).await
}

async fn reserve_wireguard_peer_ip_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    peer_id: &str,
    ip: Ipv4Addr,
) -> anyhow::Result<()> {
    query(
        r#"INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
           VALUES (?, ?, 'wireguard_peer', ?)
           ON CONFLICT(network_code, owner_type, owner_id) DO UPDATE SET
               ip = excluded.ip"#,
    )
    .bind(network_code)
    .bind(ip.to_string())
    .bind(peer_id)
    .execute(pool)
    .await
    .with_context(|| {
        format!(
            "Failed to reserve IP {ip} for WireGuard peer '{peer_id}' in network '{network_code}'"
        )
    })?;
    Ok(())
}

pub async fn reserve_wireguard_peer_ip(
    network_code: &str,
    peer_id: &str,
    ip: Ipv4Addr,
) -> anyhow::Result<()> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(());
    };
    reserve_wireguard_peer_ip_with_pool(pool, network_code, peer_id, ip).await
}

async fn release_wireguard_peer_ip_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<bool> {
    let result = query(
        r#"DELETE FROM ip_allocations
           WHERE network_code = ? AND owner_type = 'wireguard_peer' AND owner_id = ?"#,
    )
    .bind(network_code)
    .bind(peer_id)
    .execute(pool)
    .await
    .context("Failed to release WireGuard peer IP")?;
    Ok(result.rows_affected() > 0)
}

pub async fn release_wireguard_peer_ip(network_code: &str, peer_id: &str) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };
    release_wireguard_peer_ip_with_pool(pool, network_code, peer_id).await
}

async fn load_wireguard_peer_ip_allocations_with_pool(
    pool: &SqlitePool,
    network_code: &str,
) -> anyhow::Result<Vec<WireGuardPeerIpAllocation>> {
    let rows = query(
        r#"SELECT owner_id, ip FROM ip_allocations
           WHERE network_code = ? AND owner_type = 'wireguard_peer'
           ORDER BY owner_id"#,
    )
    .bind(network_code)
    .fetch_all(pool)
    .await
    .context("Failed to load WireGuard peer IP allocations")?;

    rows.into_iter()
        .map(|row| {
            let peer_id: String = row.try_get("owner_id")?;
            let ip_text: String = row.try_get("ip")?;
            let ip = ip_text.parse().with_context(|| {
                format!("Invalid WireGuard peer IP '{ip_text}' for peer '{peer_id}'")
            })?;
            Ok(WireGuardPeerIpAllocation { peer_id, ip })
        })
        .collect()
}

pub async fn load_wireguard_peer_ip_allocations(
    network_code: &str,
) -> anyhow::Result<Vec<WireGuardPeerIpAllocation>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(Vec::new());
    };
    load_wireguard_peer_ip_allocations_with_pool(pool, network_code).await
}

pub(super) async fn save_wireguard_peer_profile(
    profile: &WireGuardPeerProfileRecord,
    secret: Option<&EncryptedWireGuardPeerSecret>,
) -> anyhow::Result<()> {
    let mut transaction = db_pool()?.begin().await?;
    let dns_servers = profile
        .dns_servers
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .context("Failed to serialize WireGuard DNS servers")?;
    query(
        "INSERT INTO wireguard_peer_profiles (
             network_code, peer_id, dns_servers, persistent_keepalive, created_at, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(network_code, peer_id) DO UPDATE SET
             dns_servers = excluded.dns_servers,
             persistent_keepalive = excluded.persistent_keepalive,
             updated_at = excluded.updated_at",
    )
    .bind(&profile.network_code)
    .bind(&profile.peer_id)
    .bind(dns_servers)
    .bind(i64::from(profile.persistent_keepalive))
    .bind(profile.created_at)
    .bind(profile.updated_at)
    .execute(&mut *transaction)
    .await
    .context("Failed to save WireGuard peer profile")?;
    query("DELETE FROM wireguard_peer_routes WHERE network_code = ? AND peer_id = ?")
        .bind(&profile.network_code)
        .bind(&profile.peer_id)
        .execute(&mut *transaction)
        .await?;
    for (sort_order, route) in profile.routes.iter().enumerate() {
        query(
            "INSERT INTO wireguard_peer_routes (
                 network_code, peer_id, lan_network, vnt_cli_ip, sort_order
             ) VALUES (?, ?, ?, ?, ?)",
        )
        .bind(&profile.network_code)
        .bind(&profile.peer_id)
        .bind(route.lan_network.to_string())
        .bind(route.vnt_cli_ip.to_string())
        .bind(sort_order as i64)
        .execute(&mut *transaction)
        .await
        .context("Failed to save WireGuard peer route")?;
    }
    if let Some(secret) = secret {
        query(
            "INSERT INTO wireguard_peer_secrets (
                 network_code, peer_id, format_version, encryption_key_version,
                 nonce, ciphertext, public_key, created_at, updated_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(network_code, peer_id) DO UPDATE SET
                 format_version = excluded.format_version,
                 encryption_key_version = excluded.encryption_key_version,
                 nonce = excluded.nonce,
                 ciphertext = excluded.ciphertext,
                 public_key = excluded.public_key,
                 updated_at = excluded.updated_at",
        )
        .bind(&secret.network_code)
        .bind(&secret.peer_id)
        .bind(secret.format_version)
        .bind(secret.encryption_key_version)
        .bind(&secret.nonce)
        .bind(&secret.ciphertext)
        .bind(&secret.public_key)
        .bind(secret.created_at)
        .bind(secret.updated_at)
        .execute(&mut *transaction)
        .await
        .context("Failed to save encrypted WireGuard peer secret")?;
    }
    transaction.commit().await?;
    Ok(())
}

pub async fn load_wireguard_peer_profile(
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<Option<WireGuardPeerProfileRecord>> {
    let row = query(
        "SELECT p.created_at AS peer_created_at, p.updated_at AS peer_updated_at,
                pr.dns_servers, pr.persistent_keepalive,
                pr.created_at AS profile_created_at, pr.updated_at AS profile_updated_at,
                EXISTS(
                    SELECT 1 FROM wireguard_peer_secrets s
                    WHERE s.network_code = p.network_code AND s.peer_id = p.peer_id
                ) AS config_available
         FROM wireguard_peers p
         LEFT JOIN wireguard_peer_profiles pr
           ON pr.network_code = p.network_code AND pr.peer_id = p.peer_id
         WHERE p.network_code = ? AND p.peer_id = ?",
    )
    .bind(network_code)
    .bind(peer_id)
    .fetch_optional(db_pool()?)
    .await
    .context("Failed to load WireGuard peer profile")?;
    let Some(row) = row else {
        return Ok(None);
    };
    let dns_text: Option<String> = row.try_get("dns_servers")?;
    let dns_servers = dns_text
        .map(|value| serde_json::from_str::<Vec<IpAddr>>(&value))
        .transpose()
        .context("WireGuard peer profile contains invalid DNS data")?;
    let routes = query(
        "SELECT lan_network, vnt_cli_ip FROM wireguard_peer_routes
         WHERE network_code = ? AND peer_id = ? ORDER BY sort_order, lan_network",
    )
    .bind(network_code)
    .bind(peer_id)
    .fetch_all(db_pool()?)
    .await?
    .into_iter()
    .map(|row| {
        Ok(WireGuardPeerRouteRecord {
            lan_network: row.get::<String, _>("lan_network").parse()?,
            vnt_cli_ip: row.get::<String, _>("vnt_cli_ip").parse()?,
        })
    })
    .collect::<anyhow::Result<Vec<_>>>()?;
    let profile_created_at: Option<i64> = row.try_get("profile_created_at")?;
    let profile_updated_at: Option<i64> = row.try_get("profile_updated_at")?;
    Ok(Some(WireGuardPeerProfileRecord {
        network_code: network_code.to_string(),
        peer_id: peer_id.to_string(),
        dns_servers,
        persistent_keepalive: row
            .try_get::<Option<i64>, _>("persistent_keepalive")?
            .unwrap_or(25) as u16,
        routes,
        config_available: row.get::<i64, _>("config_available") != 0,
        created_at: profile_created_at.unwrap_or(row.get("peer_created_at")),
        updated_at: profile_updated_at.unwrap_or(row.get("peer_updated_at")),
    }))
}

pub(super) async fn load_wireguard_peer_secret(
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<Option<EncryptedWireGuardPeerSecret>> {
    let row = query(
        "SELECT network_code, peer_id, format_version, encryption_key_version,
                nonce, ciphertext, public_key, created_at, updated_at
         FROM wireguard_peer_secrets WHERE network_code = ? AND peer_id = ?",
    )
    .bind(network_code)
    .bind(peer_id)
    .fetch_optional(db_pool()?)
    .await?;
    row.map(encrypted_peer_secret_from_row).transpose()
}

pub(super) async fn load_all_wireguard_peer_secrets_with_pool(
    pool: &SqlitePool,
) -> anyhow::Result<Vec<EncryptedWireGuardPeerSecret>> {
    query(
        "SELECT network_code, peer_id, format_version, encryption_key_version,
                nonce, ciphertext, public_key, created_at, updated_at
         FROM wireguard_peer_secrets ORDER BY network_code, peer_id",
    )
    .fetch_all(pool)
    .await?
    .into_iter()
    .map(encrypted_peer_secret_from_row)
    .collect()
}

fn encrypted_peer_secret_from_row(row: SqliteRow) -> anyhow::Result<EncryptedWireGuardPeerSecret> {
    Ok(EncryptedWireGuardPeerSecret {
        network_code: row.try_get("network_code")?,
        peer_id: row.try_get("peer_id")?,
        format_version: row.try_get("format_version")?,
        encryption_key_version: row.try_get("encryption_key_version")?,
        nonce: row.try_get("nonce")?,
        ciphertext: row.try_get("ciphertext")?,
        public_key: row.try_get("public_key")?,
        created_at: row.try_get("created_at")?,
        updated_at: row.try_get("updated_at")?,
    })
}

pub async fn save_or_update_device(device: &DeviceRecord) -> anyhow::Result<()> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(());
    };

    query(
        r#"INSERT INTO devices (device_id, network_code, ip, device_name, device_version, last_connect_time, tx_bytes, rx_bytes)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT(device_id, network_code) DO UPDATE SET
               ip = excluded.ip,
               device_name = excluded.device_name,
               device_version = excluded.device_version,
               last_connect_time = excluded.last_connect_time,
               tx_bytes = excluded.tx_bytes,
               rx_bytes = excluded.rx_bytes"#,
    )
    .bind(&device.device_id)
    .bind(&device.network_code)
    .bind(&device.ip)
    .bind(&device.device_name)
    .bind(&device.device_version)
    .bind(device.last_connect_time)
    .bind(device.tx_bytes)
    .bind(device.rx_bytes)
    .execute(pool)
    .await
    .context("Failed to save or update device")?;

    Ok(())
}

/// 回收 IP：清空字段但保留记录
pub async fn release_device_ip(network_code: &str, device_id: &str) -> anyhow::Result<()> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(());
    };

    query(r#"UPDATE devices SET ip = NULL WHERE network_code = ? AND device_id = ?"#)
        .bind(network_code)
        .bind(device_id)
        .execute(pool)
        .await
        .context("Failed to release device IP")?;

    Ok(())
}

#[allow(dead_code)]
pub async fn get_device(
    network_code: &str,
    device_id: &str,
) -> anyhow::Result<Option<DeviceRecord>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(None);
    };

    let row_option = query(
        r#"SELECT device_id, network_code, ip, device_name, device_version, last_connect_time,
           COALESCE(tx_bytes, 0) as tx_bytes, COALESCE(rx_bytes, 0) as rx_bytes
           FROM devices WHERE network_code = ? AND device_id = ?"#,
    )
    .bind(network_code)
    .bind(device_id)
    .fetch_optional(pool)
    .await
    .context("Failed to fetch device")?;

    match row_option {
        Some(row) => Ok(Some(DeviceRecord {
            device_id: row.get("device_id"),
            network_code: row.get("network_code"),
            ip: row.get("ip"),
            device_name: row.get("device_name"),
            device_version: row.get("device_version"),
            last_connect_time: row.get("last_connect_time"),
            tx_bytes: row.get("tx_bytes"),
            rx_bytes: row.get("rx_bytes"),
        })),
        None => Ok(None),
    }
}

pub async fn load_all_devices(network_code: &str) -> anyhow::Result<Vec<DeviceRecord>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(Vec::new());
    };

    let records: Vec<DeviceRecord> = query(
        r#"SELECT device_id, network_code, ip, device_name, device_version, last_connect_time,
           COALESCE(tx_bytes, 0) as tx_bytes, COALESCE(rx_bytes, 0) as rx_bytes
           FROM devices WHERE network_code = ?"#,
    )
    .bind(network_code)
    .fetch(pool)
    .try_filter_map(|row| async move {
        Ok(Some(DeviceRecord {
            device_id: row.try_get("device_id")?,
            network_code: row.try_get("network_code")?,
            ip: row.try_get("ip")?,
            device_name: row.try_get("device_name")?,
            device_version: row.try_get("device_version")?,
            last_connect_time: row.try_get("last_connect_time")?,
            tx_bytes: row.try_get("tx_bytes")?,
            rx_bytes: row.try_get("rx_bytes")?,
        }))
    })
    .try_collect()
    .await
    .context("Failed to load all devices")?;

    Ok(records)
}

pub async fn delete_device(network_code: &str, device_id: &str) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(r#"DELETE FROM devices WHERE network_code = ? AND device_id = ?"#)
        .bind(network_code)
        .bind(device_id)
        .execute(pool)
        .await
        .context("Failed to delete device")?;

    Ok(result.rows_affected() > 0)
}

#[allow(dead_code)]
pub async fn delete_devices_by_network(network_code: &str) -> anyhow::Result<u64> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(0);
    };

    let result = query(r#"DELETE FROM devices WHERE network_code = ?"#)
        .bind(network_code)
        .execute(pool)
        .await
        .context("Failed to delete devices by network")?;

    Ok(result.rows_affected())
}

pub async fn save_peer_server_if_not_exists(record: &PeerServerRecord) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(
        r#"INSERT OR IGNORE INTO peer_servers (server_addr, source, created_at)
           VALUES (?, ?, ?)"#,
    )
    .bind(&record.server_addr)
    .bind(record.source as i32)
    .bind(record.created_at)
    .execute(pool)
    .await
    .context("Failed to save peer server")?;

    Ok(result.rows_affected() > 0)
}

pub async fn save_peer_server(record: &PeerServerRecord) -> anyhow::Result<()> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(());
    };

    query(
        r#"INSERT OR REPLACE INTO peer_servers (server_addr, source, created_at)
           VALUES (?, ?, ?)"#,
    )
    .bind(&record.server_addr)
    .bind(record.source as i32)
    .bind(record.created_at)
    .execute(pool)
    .await
    .context("Failed to save peer server")?;

    Ok(())
}

pub async fn load_all_peer_servers() -> anyhow::Result<Vec<PeerServerRecord>> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(Vec::new());
    };

    let records: Vec<PeerServerRecord> =
        query(r#"SELECT server_addr, source, created_at FROM peer_servers ORDER BY created_at"#)
            .fetch(pool)
            .try_filter_map(|row| async move {
                let source: i32 = row.try_get("source")?;
                Ok(Some(PeerServerRecord {
                    server_addr: row.try_get("server_addr")?,
                    source: PeerServerSource::from_i32(source),
                    created_at: row.try_get("created_at")?,
                }))
            })
            .try_collect()
            .await
            .context("Failed to load all peer servers")?;

    Ok(records)
}

pub async fn delete_peer_server(server_addr: &str) -> anyhow::Result<bool> {
    let Some(pool) = DB_POOL.get() else {
        return Ok(false);
    };

    let result = query(r#"DELETE FROM peer_servers WHERE server_addr = ?"#)
        .bind(server_addr)
        .execute(pool)
        .await
        .context("Failed to delete peer server")?;

    Ok(result.rows_affected() > 0)
}

pub async fn acquire_cluster_lease(
    request: &ClusterLeaseRequest,
) -> anyhow::Result<ClusterLeaseGrant> {
    acquire_cluster_lease_with_pool(db_pool()?, request).await
}

async fn acquire_cluster_lease_with_pool(
    pool: &SqlitePool,
    request: &ClusterLeaseRequest,
) -> anyhow::Result<ClusterLeaseGrant> {
    ensure!(
        matches!(request.owner_type.as_str(), "vnt_device" | "wireguard_peer"),
        "不支持的集群租约所有者类型"
    );
    ensure!(
        !request.owner_id.trim().is_empty(),
        "集群租约所有者不能为空"
    );
    ensure!(
        request.network.contains(&request.gateway)
            && request.gateway != request.network.network()
            && request.gateway != request.network.broadcast(),
        "集群租约网关不在有效网段内"
    );

    let mut transaction = pool
        .begin()
        .await
        .context("Failed to start cluster lease transaction")?;
    let now = unix_time_i64();
    query(
        "DELETE FROM cluster_leases
         WHERE static_reservation = 0 AND expires_at > 0 AND expires_at <= ?",
    )
    .bind(now)
    .execute(&mut *transaction)
    .await
    .context("Failed to expire cluster leases")?;

    let existing = query(
        "SELECT ip FROM cluster_leases
         WHERE network_code = ? AND owner_type = ? AND owner_id = ?",
    )
    .bind(&request.network_code)
    .bind(&request.owner_type)
    .bind(&request.owner_id)
    .fetch_optional(&mut *transaction)
    .await
    .context("Failed to load existing cluster lease")?;
    let existing_ip = existing
        .map(|row| row.get::<String, _>("ip"))
        .map(|value| value.parse::<Ipv4Addr>())
        .transpose()
        .context("Cluster lease contains invalid IPv4 address")?;

    let local_owner_ip = if existing_ip.is_none() {
        query(
            "SELECT ip FROM ip_allocations
             WHERE network_code = ? AND owner_type = ? AND owner_id = ?",
        )
        .bind(&request.network_code)
        .bind(&request.owner_type)
        .bind(&request.owner_id)
        .fetch_optional(&mut *transaction)
        .await
        .context("Failed to load local owner allocation")?
        .map(|row| row.get::<String, _>("ip"))
        .map(|value| value.parse::<Ipv4Addr>())
        .transpose()
        .context("Local allocation contains invalid IPv4 address")?
    } else {
        None
    };

    let preferred = request.requested_ip.or(existing_ip).or(local_owner_ip);
    let candidate = if let Some(ip) = preferred {
        validate_cluster_candidate(request.network, request.gateway, ip)?;
        ensure_cluster_ip_available(&mut transaction, request, ip).await?;
        ip
    } else {
        let mut selected = None;
        let start = u32::from(request.network.network()) + 1;
        let end = u32::from(request.network.broadcast());
        for raw in start..end {
            let ip = Ipv4Addr::from(raw);
            if ip == request.gateway {
                continue;
            }
            if ensure_cluster_ip_available(&mut transaction, request, ip)
                .await
                .is_ok()
            {
                selected = Some(ip);
                break;
            }
        }
        selected.ok_or_else(|| anyhow::anyhow!("集群虚拟网段地址已耗尽"))?
    };

    let revision_row = query(
        "UPDATE cluster_state
         SET authority_id = ?, revision = revision + 1, updated_at = ?
         WHERE id = 1
         RETURNING revision",
    )
    .bind(&request.authority_id)
    .bind(now)
    .fetch_one(&mut *transaction)
    .await
    .context("Failed to advance cluster lease revision")?;
    let revision = revision_row.get::<i64, _>("revision") as u64;
    let expires_at = if request.static_reservation {
        0
    } else {
        now.saturating_add(request.lease_duration_secs.max(10).min(i64::MAX as u64) as i64)
    };
    query(
        "INSERT INTO cluster_leases (
             network_code, owner_type, owner_id, ip, authority_id, origin_server_id,
             revision, expires_at, static_reservation, updated_at
         ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(network_code, owner_type, owner_id) DO UPDATE SET
             ip = excluded.ip,
             authority_id = excluded.authority_id,
             origin_server_id = excluded.origin_server_id,
             revision = excluded.revision,
             expires_at = excluded.expires_at,
             static_reservation = excluded.static_reservation,
             updated_at = excluded.updated_at",
    )
    .bind(&request.network_code)
    .bind(&request.owner_type)
    .bind(&request.owner_id)
    .bind(candidate.to_string())
    .bind(&request.authority_id)
    .bind(&request.origin_server_id)
    .bind(revision as i64)
    .bind(expires_at)
    .bind(i64::from(request.static_reservation))
    .bind(now)
    .execute(&mut *transaction)
    .await
    .context("Failed to persist cluster lease")?;
    transaction
        .commit()
        .await
        .context("Failed to commit cluster lease")?;
    Ok(ClusterLeaseGrant {
        ip: candidate,
        revision,
        expires_at,
    })
}

async fn ensure_cluster_ip_available(
    transaction: &mut sqlx_core::transaction::Transaction<'_, sqlx_sqlite::Sqlite>,
    request: &ClusterLeaseRequest,
    ip: Ipv4Addr,
) -> anyhow::Result<()> {
    let occupied = query(
        "SELECT (
             EXISTS(
                 SELECT 1 FROM cluster_leases
                 WHERE network_code = ? AND ip = ?
                   AND NOT(owner_type = ? AND owner_id = ?)
             )
             OR EXISTS(
                 SELECT 1 FROM ip_allocations
                 WHERE network_code = ? AND ip = ?
                   AND NOT(owner_type = ? AND owner_id = ?)
             )
         ) AS occupied",
    )
    .bind(&request.network_code)
    .bind(ip.to_string())
    .bind(&request.owner_type)
    .bind(&request.owner_id)
    .bind(&request.network_code)
    .bind(ip.to_string())
    .bind(&request.owner_type)
    .bind(&request.owner_id)
    .fetch_one(&mut **transaction)
    .await
    .context("Failed to check cluster lease collision")?
    .get::<i64, _>("occupied")
        != 0;
    ensure!(!occupied, "IP {ip} 已被其他集群租约占用");
    Ok(())
}

fn validate_cluster_candidate(
    network: Ipv4Net,
    gateway: Ipv4Addr,
    ip: Ipv4Addr,
) -> anyhow::Result<()> {
    ensure!(network.contains(&ip), "请求 IP 不在虚拟网段内");
    ensure!(
        ip != network.network() && ip != network.broadcast() && ip != gateway,
        "请求 IP 是保留地址"
    );
    Ok(())
}

pub async fn release_cluster_lease(
    network_code: &str,
    owner_type: &str,
    owner_id: &str,
    authority_id: &str,
) -> anyhow::Result<u64> {
    release_cluster_lease_with_pool(db_pool()?, network_code, owner_type, owner_id, authority_id)
        .await
}

async fn release_cluster_lease_with_pool(
    pool: &SqlitePool,
    network_code: &str,
    owner_type: &str,
    owner_id: &str,
    authority_id: &str,
) -> anyhow::Result<u64> {
    let mut transaction = pool.begin().await?;
    let result = query(
        "DELETE FROM cluster_leases
         WHERE network_code = ? AND owner_type = ? AND owner_id = ?",
    )
    .bind(network_code)
    .bind(owner_type)
    .bind(owner_id)
    .execute(&mut *transaction)
    .await
    .context("Failed to release cluster lease")?;
    let now = unix_time_i64();
    let revision = if result.rows_affected() == 0 {
        query("SELECT revision FROM cluster_state WHERE id = 1")
            .fetch_one(&mut *transaction)
            .await?
            .get::<i64, _>("revision") as u64
    } else {
        query(
            "UPDATE cluster_state
             SET authority_id = ?, revision = revision + 1, updated_at = ?
             WHERE id = 1 RETURNING revision",
        )
        .bind(authority_id)
        .bind(now)
        .fetch_one(&mut *transaction)
        .await?
        .get::<i64, _>("revision") as u64
    };
    transaction.commit().await?;
    Ok(revision)
}

pub async fn load_local_ip_allocations() -> anyhow::Result<Vec<LocalIpAllocation>> {
    let rows = query(
        "SELECT a.network_code, a.owner_type, a.owner_id, a.ip,
                n.gateway, n.netmask, n.lease_duration
         FROM ip_allocations a
         INNER JOIN networks n ON n.network_code = a.network_code
         ORDER BY a.network_code, a.owner_type, a.owner_id",
    )
    .fetch_all(db_pool()?)
    .await
    .context("Failed to load local IP allocations for cluster reconciliation")?;
    rows.into_iter()
        .map(|row| {
            let gateway: Ipv4Addr = row.get::<String, _>("gateway").parse()?;
            let prefix = row.get::<i64, _>("netmask") as u8;
            let network = Ipv4Net::new(Ipv4Addr::from(u32::from(gateway) - 1), prefix)?;
            Ok(LocalIpAllocation {
                network_code: row.get("network_code"),
                owner_type: row.get("owner_type"),
                owner_id: row.get("owner_id"),
                ip: row.get::<String, _>("ip").parse()?,
                network,
                gateway,
                lease_duration_secs: row.get::<i64, _>("lease_duration").max(10) as u64,
            })
        })
        .collect()
}

fn unix_time_i64() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .min(i64::MAX as u64) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn legacy_pool() -> SqlitePool {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        query(
            "CREATE TABLE devices (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                device_id TEXT NOT NULL,
                network_code TEXT NOT NULL,
                ip TEXT,
                device_name TEXT NOT NULL,
                device_version TEXT NOT NULL,
                last_connect_time INTEGER NOT NULL,
                tx_bytes INTEGER NOT NULL DEFAULT 0,
                rx_bytes INTEGER NOT NULL DEFAULT 0,
                UNIQUE(device_id, network_code)
            )",
        )
        .execute(&pool)
        .await
        .unwrap();
        query(
            "CREATE TABLE networks (
                network_code TEXT PRIMARY KEY,
                gateway TEXT NOT NULL,
                netmask INTEGER NOT NULL,
                lease_duration INTEGER NOT NULL,
                source INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL
            )",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool
    }

    async fn insert_test_network(pool: &SqlitePool, network_code: &str) {
        query(
            "INSERT INTO networks (
                network_code, gateway, netmask, lease_duration, source, created_at
             ) VALUES (?, '10.26.0.1', 24, 60, 1, 1)",
        )
        .bind(network_code)
        .execute(pool)
        .await
        .unwrap();
    }

    fn wireguard_peer_record(
        network_code: &str,
        peer_id: &str,
        public_key: [u8; 32],
    ) -> WireGuardPeerRecord {
        WireGuardPeerRecord {
            network_code: network_code.to_string(),
            peer_id: peer_id.to_string(),
            public_key,
            enabled: true,
            created_at: 10,
            updated_at: 10,
        }
    }

    async fn insert_device(
        pool: &SqlitePool,
        network_code: &str,
        device_id: &str,
        ip: Option<&str>,
    ) -> anyhow::Result<()> {
        query(
            "INSERT INTO devices (
                device_id, network_code, ip, device_name, device_version,
                last_connect_time, tx_bytes, rx_bytes
             ) VALUES (?, ?, ?, ?, 'test', 0, 0, 0)",
        )
        .bind(device_id)
        .bind(network_code)
        .bind(ip)
        .bind(device_id)
        .execute(pool)
        .await?;
        Ok(())
    }

    async fn allocation_count(pool: &SqlitePool, network_code: &str) -> i64 {
        query("SELECT COUNT(*) AS count FROM ip_allocations WHERE network_code = ?")
            .bind(network_code)
            .fetch_one(pool)
            .await
            .unwrap()
            .get("count")
    }

    #[tokio::test]
    async fn migration_backfills_legacy_devices_and_is_idempotent() {
        let pool = legacy_pool().await;
        insert_device(&pool, "legacy-net", "device-a", Some("10.26.0.2"))
            .await
            .unwrap();
        insert_device(&pool, "legacy-net", "device-without-ip", None)
            .await
            .unwrap();

        migrations::apply(&pool).await.unwrap();
        migrations::apply(&pool).await.unwrap();

        let row =
            query("SELECT ip, owner_type, owner_id FROM ip_allocations WHERE network_code = ?")
                .bind("legacy-net")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(row.get::<String, _>("ip"), "10.26.0.2");
        assert_eq!(row.get::<String, _>("owner_type"), "vnt_device");
        assert_eq!(row.get::<String, _>("owner_id"), "device-a");

        let version: i64 = query("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get(0);
        assert_eq!(version, migrations::SCHEMA_VERSION);
    }

    #[tokio::test]
    async fn migration_rejects_ambiguous_legacy_duplicate_ips() {
        let pool = legacy_pool().await;
        insert_device(&pool, "legacy-net", "device-a", Some("10.26.0.2"))
            .await
            .unwrap();
        insert_device(&pool, "legacy-net", "device-b", Some("10.26.0.2"))
            .await
            .unwrap();

        let error = migrations::apply(&pool).await.unwrap_err();
        assert!(
            error
                .to_string()
                .contains("Legacy devices contain duplicate or conflicting IP allocations")
        );

        let version: i64 = query("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get(0);
        assert_eq!(version, 0);
    }

    #[tokio::test]
    async fn migration_v3_preserves_existing_wireguard_ip_allocations() {
        let pool = legacy_pool().await;
        query(
            "CREATE TABLE ip_allocations (
                network_code TEXT NOT NULL,
                ip TEXT NOT NULL,
                owner_type TEXT NOT NULL CHECK(owner_type IN ('vnt_device', 'wireguard_peer')),
                owner_id TEXT NOT NULL CHECK(length(owner_id) > 0),
                PRIMARY KEY(network_code, owner_type, owner_id),
                UNIQUE(network_code, ip)
            )",
        )
        .execute(&pool)
        .await
        .unwrap();
        query(
            "INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
             VALUES ('network-a', '10.26.0.2', 'wireguard_peer', 'legacy-peer')",
        )
        .execute(&pool)
        .await
        .unwrap();
        query("PRAGMA user_version = 2")
            .execute(&pool)
            .await
            .unwrap();

        migrations::apply(&pool).await.unwrap();
        migrations::apply(&pool).await.unwrap();

        let owner_id: String = query(
            "SELECT owner_id FROM ip_allocations
             WHERE network_code = 'network-a' AND owner_type = 'wireguard_peer'",
        )
        .fetch_one(&pool)
        .await
        .unwrap()
        .get("owner_id");
        assert_eq!(owner_id, "legacy-peer");
        let peer_count: i64 = query("SELECT COUNT(*) AS count FROM wireguard_peers")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get("count");
        assert_eq!(peer_count, 0);
        let version: i64 = query("PRAGMA user_version")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get(0);
        assert_eq!(version, migrations::SCHEMA_VERSION);
    }

    #[tokio::test]
    async fn wireguard_peer_identity_is_network_scoped_with_a_globally_unique_public_key() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();
        insert_test_network(&pool, "network-a").await;
        insert_test_network(&pool, "network-b").await;

        let peer_a = wireguard_peer_record("network-a", "shared-name", [0x11; 32]);
        let peer_b = wireguard_peer_record("network-b", "shared-name", [0x22; 32]);
        insert_wireguard_peer_with_pool(&pool, &peer_a)
            .await
            .unwrap();
        insert_wireguard_peer_with_pool(&pool, &peer_b)
            .await
            .unwrap();
        insert_wireguard_peer_with_pool(
            &pool,
            &wireguard_peer_record("network-a", "peer-a", [0x33; 32]),
        )
        .await
        .unwrap();

        let duplicate_key = wireguard_peer_record("network-b", "different-peer", peer_a.public_key);
        assert!(
            insert_wireguard_peer_with_pool(&pool, &duplicate_key)
                .await
                .is_err()
        );
        let missing_network = wireguard_peer_record("missing-network", "peer-c", [0x44; 32]);
        assert!(
            insert_wireguard_peer_with_pool(&pool, &missing_network)
                .await
                .unwrap_err()
                .to_string()
                .contains("does not exist")
        );

        let peers = load_wireguard_peers_with_pool(&pool, "network-a")
            .await
            .unwrap();
        assert_eq!(
            peers
                .iter()
                .map(|peer| peer.peer_id.as_str())
                .collect::<Vec<_>>(),
            vec!["peer-a", "shared-name"]
        );
        assert_eq!(
            load_wireguard_peer_by_public_key_with_pool(&pool, &peer_b.public_key)
                .await
                .unwrap(),
            Some(peer_b)
        );

        assert!(
            query(
                "INSERT INTO wireguard_peers (
                    network_code, peer_id, public_key, enabled, created_at, updated_at
                 ) VALUES ('network-a', 'invalid-key', zeroblob(31), 1, 1, 1)",
            )
            .execute(&pool)
            .await
            .is_err()
        );
    }

    #[tokio::test]
    async fn disabling_preserves_ip_and_hard_delete_releases_it_atomically() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();
        insert_test_network(&pool, "network-a").await;
        let peer = wireguard_peer_record("network-a", "peer-a", [0x11; 32]);
        insert_wireguard_peer_with_pool(&pool, &peer).await.unwrap();
        assert!(
            network_has_resource_owners_with_pool(&pool, "network-a")
                .await
                .unwrap()
        );
        reserve_wireguard_peer_ip_with_pool(
            &pool,
            "network-a",
            "peer-a",
            "10.26.0.2".parse().unwrap(),
        )
        .await
        .unwrap();

        assert!(
            set_wireguard_peer_enabled_with_pool(&pool, "network-a", "peer-a", false, 20)
                .await
                .unwrap()
        );
        let disabled = load_wireguard_peer_by_public_key_with_pool(&pool, &peer.public_key)
            .await
            .unwrap()
            .unwrap();
        assert!(!disabled.enabled);
        assert_eq!(disabled.updated_at, 20);
        assert_eq!(allocation_count(&pool, "network-a").await, 1);
        assert!(
            network_has_resource_owners_with_pool(&pool, "network-a")
                .await
                .unwrap()
        );

        let deleted = delete_wireguard_peer_with_pool(&pool, "network-a", "peer-a")
            .await
            .unwrap();
        assert_eq!(
            deleted,
            WireGuardPeerDeleteResult {
                peer_removed: true,
                ip_released: true,
            }
        );
        assert!(
            load_wireguard_peers_with_pool(&pool, "network-a")
                .await
                .unwrap()
                .is_empty()
        );
        assert_eq!(allocation_count(&pool, "network-a").await, 0);
        assert!(
            !network_has_resource_owners_with_pool(&pool, "network-a")
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    async fn failed_hard_delete_rolls_back_peer_and_ip() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();
        insert_test_network(&pool, "network-a").await;
        let peer = wireguard_peer_record("network-a", "peer-a", [0x11; 32]);
        insert_wireguard_peer_with_pool(&pool, &peer).await.unwrap();
        reserve_wireguard_peer_ip_with_pool(
            &pool,
            "network-a",
            "peer-a",
            "10.26.0.2".parse().unwrap(),
        )
        .await
        .unwrap();
        query(
            "CREATE TRIGGER reject_wireguard_peer_ip_delete
             BEFORE DELETE ON ip_allocations
             WHEN OLD.owner_type = 'wireguard_peer' AND OLD.owner_id = 'peer-a'
             BEGIN
                 SELECT RAISE(ABORT, 'test rollback');
             END",
        )
        .execute(&pool)
        .await
        .unwrap();

        assert!(
            delete_wireguard_peer_with_pool(&pool, "network-a", "peer-a")
                .await
                .is_err()
        );
        assert_eq!(
            load_wireguard_peer_by_public_key_with_pool(&pool, &peer.public_key)
                .await
                .unwrap(),
            Some(peer)
        );
        assert_eq!(allocation_count(&pool, "network-a").await, 1);
    }

    #[tokio::test]
    async fn vnt_devices_and_wireguard_peers_share_one_ip_uniqueness_rule() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();

        reserve_wireguard_peer_ip_with_pool(
            &pool,
            "network-a",
            "peer-a",
            "10.26.0.2".parse().unwrap(),
        )
        .await
        .unwrap();
        assert!(
            insert_device(&pool, "network-a", "device-a", Some("10.26.0.2"))
                .await
                .is_err()
        );

        insert_device(&pool, "network-a", "device-b", Some("10.26.0.3"))
            .await
            .unwrap();
        assert!(
            reserve_wireguard_peer_ip_with_pool(
                &pool,
                "network-a",
                "peer-b",
                "10.26.0.3".parse().unwrap(),
            )
            .await
            .is_err()
        );

        assert!(
            query("UPDATE devices SET ip = '10.26.0.2' WHERE device_id = 'device-b'")
                .execute(&pool)
                .await
                .is_err()
        );
        let device_ip: String = query(
            "SELECT ip FROM devices WHERE network_code = 'network-a' AND device_id = 'device-b'",
        )
        .fetch_one(&pool)
        .await
        .unwrap()
        .get("ip");
        assert_eq!(device_ip, "10.26.0.3");

        insert_device(&pool, "network-b", "device-c", Some("10.26.0.2"))
            .await
            .unwrap();
        assert_eq!(allocation_count(&pool, "network-a").await, 2);
        assert_eq!(allocation_count(&pool, "network-b").await, 1);
    }

    #[tokio::test]
    async fn device_triggers_and_peer_release_keep_allocations_in_sync() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();
        insert_device(&pool, "network-a", "device-a", Some("10.26.0.2"))
            .await
            .unwrap();

        query("UPDATE devices SET ip = '10.26.0.3' WHERE device_id = 'device-a'")
            .execute(&pool)
            .await
            .unwrap();
        let ip: String = query(
            "SELECT ip FROM ip_allocations
             WHERE owner_type = 'vnt_device' AND owner_id = 'device-a'",
        )
        .fetch_one(&pool)
        .await
        .unwrap()
        .get("ip");
        assert_eq!(ip, "10.26.0.3");

        query("UPDATE devices SET ip = NULL WHERE device_id = 'device-a'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(allocation_count(&pool, "network-a").await, 0);

        reserve_wireguard_peer_ip_with_pool(
            &pool,
            "network-a",
            "peer-a",
            "10.26.0.4".parse().unwrap(),
        )
        .await
        .unwrap();
        let allocations = load_wireguard_peer_ip_allocations_with_pool(&pool, "network-a")
            .await
            .unwrap();
        assert_eq!(
            allocations,
            vec![WireGuardPeerIpAllocation {
                peer_id: "peer-a".to_string(),
                ip: "10.26.0.4".parse().unwrap(),
            }]
        );
        assert!(
            release_wireguard_peer_ip_with_pool(&pool, "network-a", "peer-a")
                .await
                .unwrap()
        );
        assert_eq!(allocation_count(&pool, "network-a").await, 0);
    }

    #[tokio::test]
    async fn cluster_authority_keeps_addresses_unique_and_renewals_stable() {
        let pool = legacy_pool().await;
        migrations::apply(&pool).await.unwrap();
        let network: Ipv4Net = "10.26.0.0/24".parse().unwrap();
        let request = |owner_id: &str, requested_ip: Option<Ipv4Addr>| ClusterLeaseRequest {
            network_code: "network-a".to_string(),
            owner_type: "vnt_device".to_string(),
            owner_id: owner_id.to_string(),
            requested_ip,
            network,
            gateway: "10.26.0.1".parse().unwrap(),
            lease_duration_secs: 60,
            static_reservation: false,
            authority_id: "server-a".to_string(),
            origin_server_id: "server-b".to_string(),
        };

        let first = acquire_cluster_lease_with_pool(&pool, &request("device-a", None))
            .await
            .unwrap();
        assert_eq!(first.ip, "10.26.0.2".parse::<Ipv4Addr>().unwrap());
        let renewed = acquire_cluster_lease_with_pool(&pool, &request("device-a", None))
            .await
            .unwrap();
        assert_eq!(renewed.ip, first.ip);
        assert!(renewed.revision > first.revision);

        let duplicate =
            acquire_cluster_lease_with_pool(&pool, &request("device-b", Some(first.ip))).await;
        assert!(duplicate.is_err());
        let second = acquire_cluster_lease_with_pool(&pool, &request("device-b", None))
            .await
            .unwrap();
        assert_ne!(second.ip, first.ip);

        let released = release_cluster_lease_with_pool(
            &pool,
            "network-a",
            "vnt_device",
            "device-a",
            "server-a",
        )
        .await
        .unwrap();
        assert!(released > second.revision);
    }

    #[test]
    fn database_process_lock_rejects_a_second_vnts_process() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "vnts2-database-process-lock-{}-{unique}.lock",
            std::process::id()
        ));

        let first = acquire_database_process_lock(&path).unwrap();
        let error = acquire_database_process_lock(&path).err().unwrap();
        assert!(error.to_string().contains("already in use"));
        drop(first);
        let second = acquire_database_process_lock(&path).unwrap();
        drop(second);
        std::fs::remove_file(path).unwrap();
    }
}
