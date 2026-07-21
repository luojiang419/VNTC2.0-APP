use anyhow::Context;
use sqlx_core::query::query;
use sqlx_sqlite::SqlitePool;

pub(super) const SCHEMA_VERSION: i64 = 5;

pub(super) async fn apply(pool: &SqlitePool) -> anyhow::Result<()> {
    let mut transaction = pool
        .begin()
        .await
        .context("Failed to start database migration transaction")?;

    query(
        "CREATE TABLE IF NOT EXISTS ip_allocations (
            network_code TEXT NOT NULL,
            ip TEXT NOT NULL,
            owner_type TEXT NOT NULL CHECK(owner_type IN ('vnt_device', 'wireguard_peer')),
            owner_id TEXT NOT NULL CHECK(length(owner_id) > 0),
            PRIMARY KEY(network_code, owner_type, owner_id),
            UNIQUE(network_code, ip)
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create ip_allocations table")?;

    query(
        "CREATE TABLE IF NOT EXISTS wireguard_server_identity (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            format_version INTEGER NOT NULL CHECK(format_version = 1),
            encryption_key_version INTEGER NOT NULL CHECK(encryption_key_version > 0),
            nonce BLOB NOT NULL CHECK(length(nonce) = 24),
            ciphertext BLOB NOT NULL CHECK(length(ciphertext) = 48),
            public_key BLOB NOT NULL CHECK(length(public_key) = 32),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create WireGuard server identity table")?;

    query(
        "CREATE TABLE IF NOT EXISTS wireguard_peers (
            network_code TEXT NOT NULL,
            peer_id TEXT NOT NULL CHECK(length(peer_id) > 0),
            public_key BLOB NOT NULL CHECK(length(public_key) = 32),
            enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(network_code, peer_id),
            UNIQUE(public_key)
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create WireGuard peer table")?;

    query(
        "CREATE TABLE IF NOT EXISTS cluster_leases (
            network_code TEXT NOT NULL,
            owner_type TEXT NOT NULL CHECK(owner_type IN ('vnt_device', 'wireguard_peer')),
            owner_id TEXT NOT NULL CHECK(length(owner_id) > 0),
            ip TEXT NOT NULL,
            authority_id TEXT NOT NULL,
            origin_server_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            expires_at INTEGER NOT NULL,
            static_reservation INTEGER NOT NULL CHECK(static_reservation IN (0, 1)),
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(network_code, owner_type, owner_id),
            UNIQUE(network_code, ip)
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create cluster lease table")?;

    query(
        "CREATE TABLE IF NOT EXISTS cluster_state (
            id INTEGER PRIMARY KEY CHECK(id = 1),
            authority_id TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK(revision >= 0),
            updated_at INTEGER NOT NULL
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create cluster state table")?;
    query(
        "INSERT OR IGNORE INTO cluster_state (id, authority_id, revision, updated_at)
         VALUES (1, '', 0, 0)",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to initialize cluster state")?;

    query(
        "CREATE TABLE IF NOT EXISTS wireguard_peer_profiles (
            network_code TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            dns_servers TEXT,
            persistent_keepalive INTEGER NOT NULL DEFAULT 25
                CHECK(persistent_keepalive BETWEEN 0 AND 65535),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(network_code, peer_id),
            FOREIGN KEY(network_code, peer_id)
                REFERENCES wireguard_peers(network_code, peer_id) ON DELETE CASCADE
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create WireGuard peer profile table")?;

    query(
        "CREATE TABLE IF NOT EXISTS wireguard_peer_routes (
            network_code TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            lan_network TEXT NOT NULL,
            vnt_cli_ip TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            PRIMARY KEY(network_code, peer_id, lan_network),
            FOREIGN KEY(network_code, peer_id)
                REFERENCES wireguard_peers(network_code, peer_id) ON DELETE CASCADE
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create WireGuard peer route table")?;

    query(
        "CREATE TABLE IF NOT EXISTS wireguard_peer_secrets (
            network_code TEXT NOT NULL,
            peer_id TEXT NOT NULL,
            format_version INTEGER NOT NULL CHECK(format_version = 1),
            encryption_key_version INTEGER NOT NULL CHECK(encryption_key_version > 0),
            nonce BLOB NOT NULL CHECK(length(nonce) = 24),
            ciphertext BLOB NOT NULL CHECK(length(ciphertext) = 48),
            public_key BLOB NOT NULL CHECK(length(public_key) = 32),
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            PRIMARY KEY(network_code, peer_id),
            FOREIGN KEY(network_code, peer_id)
                REFERENCES wireguard_peers(network_code, peer_id) ON DELETE CASCADE
        )",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create encrypted WireGuard peer secret table")?;

    // devices.ip remains the compatibility field for existing installations. Rebuilding
    // only VNT owners makes this migration idempotent while preserving WireGuard owners.
    query("DELETE FROM ip_allocations WHERE owner_type = 'vnt_device'")
        .execute(&mut *transaction)
        .await
        .context("Failed to prepare legacy device IP migration")?;
    query(
        "INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
         SELECT network_code, ip, 'vnt_device', device_id
         FROM devices
         WHERE ip IS NOT NULL",
    )
    .execute(&mut *transaction)
    .await
    .context("Legacy devices contain duplicate or conflicting IP allocations")?;

    query("DROP TRIGGER IF EXISTS devices_ip_allocation_insert")
        .execute(&mut *transaction)
        .await
        .context("Failed to replace device IP insert trigger")?;
    query(
        "CREATE TRIGGER devices_ip_allocation_insert
         AFTER INSERT ON devices
         WHEN NEW.ip IS NOT NULL
         BEGIN
             INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
             VALUES (NEW.network_code, NEW.ip, 'vnt_device', NEW.device_id);
         END",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create device IP insert trigger")?;

    query("DROP TRIGGER IF EXISTS devices_ip_allocation_update")
        .execute(&mut *transaction)
        .await
        .context("Failed to replace device IP update trigger")?;
    query(
        "CREATE TRIGGER devices_ip_allocation_update
         AFTER UPDATE OF device_id, network_code, ip ON devices
         BEGIN
             DELETE FROM ip_allocations
             WHERE network_code = OLD.network_code
               AND owner_type = 'vnt_device'
               AND owner_id = OLD.device_id;
             INSERT INTO ip_allocations (network_code, ip, owner_type, owner_id)
             SELECT NEW.network_code, NEW.ip, 'vnt_device', NEW.device_id
             WHERE NEW.ip IS NOT NULL;
         END",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create device IP update trigger")?;

    query("DROP TRIGGER IF EXISTS devices_ip_allocation_delete")
        .execute(&mut *transaction)
        .await
        .context("Failed to replace device IP delete trigger")?;
    query(
        "CREATE TRIGGER devices_ip_allocation_delete
         AFTER DELETE ON devices
         BEGIN
             DELETE FROM ip_allocations
             WHERE network_code = OLD.network_code
               AND owner_type = 'vnt_device'
               AND owner_id = OLD.device_id;
         END",
    )
    .execute(&mut *transaction)
    .await
    .context("Failed to create device IP delete trigger")?;

    query(&format!("PRAGMA user_version = {SCHEMA_VERSION}"))
        .execute(&mut *transaction)
        .await
        .context("Failed to update database schema version")?;

    transaction
        .commit()
        .await
        .context("Failed to commit database migrations")?;
    Ok(())
}
