use super::db::{
    self, EncryptedWireGuardIdentity, insert_wireguard_server_identity_if_absent_with_pool,
    load_wireguard_server_identity_with_pool, replace_wireguard_server_identity_with_pool,
};
use anyhow::{Context, ensure};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
};
use sqlx_sqlite::SqlitePool;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const FORMAT_VERSION: i64 = 1;
const INITIAL_ENCRYPTION_KEY_VERSION: i64 = 1;
const MASTER_KEY_LENGTH: usize = 32;
const PRIVATE_KEY_LENGTH: usize = 32;
const AAD_CONTEXT: &[u8] = b"vnts2/wireguard-server-identity";

pub(crate) struct WireGuardIdentity(StaticSecret);

pub(crate) struct MasterKeyRotation {
    pub(crate) public_key: [u8; 32],
    pub(crate) previous_version: i64,
    pub(crate) new_version: i64,
}

pub(crate) struct IdentityRotation {
    pub(crate) previous_public_key: [u8; 32],
    pub(crate) new_public_key: [u8; 32],
}

impl WireGuardIdentity {
    pub(crate) fn public_key(&self) -> [u8; 32] {
        PublicKey::from(&self.0).to_bytes()
    }

    pub(crate) fn static_secret(&self) -> StaticSecret {
        self.0.clone()
    }

    #[cfg(test)]
    pub(crate) fn for_test(private_key: [u8; 32]) -> Self {
        Self(StaticSecret::from(private_key))
    }
}

pub(crate) async fn load_or_create(master_key_file: &Path) -> anyhow::Result<WireGuardIdentity> {
    let master_key = load_master_key(master_key_file)?;
    load_or_create_with_pool(db::db_pool()?, &master_key).await
}

pub(crate) async fn rotate_master_key(
    current_master_key_file: &Path,
    new_master_key_file: &Path,
) -> anyhow::Result<MasterKeyRotation> {
    let current_master_key = load_master_key(current_master_key_file)?;
    let new_master_key = load_master_key(new_master_key_file)?;
    rotate_master_key_with_pool(db::db_pool()?, &current_master_key, &new_master_key).await
}

pub(crate) async fn rotate_identity(master_key_file: &Path) -> anyhow::Result<IdentityRotation> {
    let master_key = load_master_key(master_key_file)?;
    rotate_identity_with_pool(db::db_pool()?, &master_key).await
}

fn load_master_key(path: &Path) -> anyhow::Result<Zeroizing<[u8; MASTER_KEY_LENGTH]>> {
    let bytes = Zeroizing::new(std::fs::read(path).with_context(|| {
        format!(
            "Failed to read WireGuard master key file: {}",
            path.display()
        )
    })?);
    ensure!(
        bytes.len() == MASTER_KEY_LENGTH,
        "WireGuard master key file must contain exactly {MASTER_KEY_LENGTH} bytes"
    );
    let mut key = Zeroizing::new([0u8; MASTER_KEY_LENGTH]);
    key.copy_from_slice(&bytes);
    Ok(key)
}

async fn load_or_create_with_pool(
    pool: &SqlitePool,
    master_key: &[u8; MASTER_KEY_LENGTH],
) -> anyhow::Result<WireGuardIdentity> {
    if let Some(record) = load_wireguard_server_identity_with_pool(pool).await? {
        return decrypt_identity(master_key, &record);
    }

    let identity = WireGuardIdentity(StaticSecret::random_from_rng(OsRng));
    let now = unix_timestamp()?;
    let record = encrypt_identity(
        master_key,
        &identity,
        INITIAL_ENCRYPTION_KEY_VERSION,
        now,
        now,
    )?;
    if insert_wireguard_server_identity_if_absent_with_pool(pool, &record).await? {
        return Ok(identity);
    }

    let record = load_wireguard_server_identity_with_pool(pool)
        .await?
        .context("WireGuard server identity disappeared during initialization")?;
    decrypt_identity(master_key, &record)
}

fn encrypt_identity(
    master_key: &[u8; MASTER_KEY_LENGTH],
    identity: &WireGuardIdentity,
    encryption_key_version: i64,
    created_at: i64,
    updated_at: i64,
) -> anyhow::Result<EncryptedWireGuardIdentity> {
    let cipher = XChaCha20Poly1305::new_from_slice(master_key)
        .context("Invalid WireGuard master key length")?;
    let public_key = identity.public_key();
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let private_key = Zeroizing::new(identity.0.to_bytes());
    ensure!(
        encryption_key_version > 0,
        "WireGuard identity encryption key version must be positive"
    );
    let aad = associated_data(FORMAT_VERSION, encryption_key_version, &public_key);
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: private_key.as_ref(),
                aad: &aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("Failed to encrypt WireGuard server identity"))?;
    Ok(EncryptedWireGuardIdentity {
        format_version: FORMAT_VERSION,
        encryption_key_version,
        nonce: nonce.to_vec(),
        ciphertext,
        public_key: public_key.to_vec(),
        created_at,
        updated_at,
    })
}

fn decrypt_identity(
    master_key: &[u8; MASTER_KEY_LENGTH],
    record: &EncryptedWireGuardIdentity,
) -> anyhow::Result<WireGuardIdentity> {
    ensure!(
        record.format_version == FORMAT_VERSION,
        "Unsupported WireGuard identity format version: {}",
        record.format_version
    );
    ensure!(
        record.encryption_key_version > 0,
        "Invalid WireGuard identity encryption key version: {}",
        record.encryption_key_version,
    );
    let public_key: [u8; 32] = record
        .public_key
        .as_slice()
        .try_into()
        .context("Invalid WireGuard server public key length")?;
    let nonce_bytes: [u8; 24] = record
        .nonce
        .as_slice()
        .try_into()
        .context("Invalid WireGuard identity nonce length")?;
    let nonce = XNonce::from(nonce_bytes);
    let aad = associated_data(
        record.format_version,
        record.encryption_key_version,
        &public_key,
    );
    let cipher = XChaCha20Poly1305::new_from_slice(master_key)
        .context("Invalid WireGuard master key length")?;
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                &nonce,
                Payload {
                    msg: &record.ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow::anyhow!("Failed to authenticate WireGuard server identity"))?,
    );
    let private_key: [u8; PRIVATE_KEY_LENGTH] = plaintext
        .as_slice()
        .try_into()
        .context("Invalid decrypted WireGuard private key length")?;
    let identity = WireGuardIdentity(StaticSecret::from(private_key));
    ensure!(
        identity.public_key() == public_key,
        "WireGuard server identity public key does not match encrypted private key"
    );
    Ok(identity)
}

async fn rotate_master_key_with_pool(
    pool: &SqlitePool,
    current_master_key: &[u8; MASTER_KEY_LENGTH],
    new_master_key: &[u8; MASTER_KEY_LENGTH],
) -> anyhow::Result<MasterKeyRotation> {
    ensure!(
        current_master_key != new_master_key,
        "New WireGuard master key must differ from the current master key"
    );
    let current = load_wireguard_server_identity_with_pool(pool)
        .await?
        .context("WireGuard server identity does not exist")?;
    let identity = decrypt_identity(current_master_key, &current)?;
    let new_version = current
        .encryption_key_version
        .checked_add(1)
        .context("WireGuard master key version overflow")?;
    let replacement = encrypt_identity(
        new_master_key,
        &identity,
        new_version,
        current.created_at,
        unix_timestamp()?,
    )?;
    replace_wireguard_server_identity_with_pool(pool, &current, &replacement).await?;

    Ok(MasterKeyRotation {
        public_key: identity.public_key(),
        previous_version: current.encryption_key_version,
        new_version,
    })
}

async fn rotate_identity_with_pool(
    pool: &SqlitePool,
    master_key: &[u8; MASTER_KEY_LENGTH],
) -> anyhow::Result<IdentityRotation> {
    let current = load_wireguard_server_identity_with_pool(pool)
        .await?
        .context("WireGuard server identity does not exist")?;
    let current_identity = decrypt_identity(master_key, &current)?;
    let replacement_identity = WireGuardIdentity(StaticSecret::random_from_rng(OsRng));
    ensure!(
        replacement_identity.public_key() != current_identity.public_key(),
        "Generated WireGuard server identity matches the current identity"
    );
    let now = unix_timestamp()?;
    let replacement = encrypt_identity(
        master_key,
        &replacement_identity,
        current.encryption_key_version,
        now,
        now,
    )?;
    replace_wireguard_server_identity_with_pool(pool, &current, &replacement).await?;

    Ok(IdentityRotation {
        previous_public_key: current_identity.public_key(),
        new_public_key: replacement_identity.public_key(),
    })
}

fn associated_data(
    format_version: i64,
    encryption_key_version: i64,
    public_key: &[u8; 32],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(AAD_CONTEXT.len() + 16 + public_key.len());
    aad.extend_from_slice(AAD_CONTEXT);
    aad.extend_from_slice(&format_version.to_be_bytes());
    aad.extend_from_slice(&encryption_key_version.to_be_bytes());
    aad.extend_from_slice(public_key);
    aad
}

fn unix_timestamp() -> anyhow::Result<i64> {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("System clock is before the Unix epoch")?
        .as_secs();
    i64::try_from(seconds).context("System clock exceeds SQLite timestamp range")
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx_core::{query::query, row::Row};

    const MASTER_KEY_A: [u8; MASTER_KEY_LENGTH] = [0x11; MASTER_KEY_LENGTH];
    const MASTER_KEY_B: [u8; MASTER_KEY_LENGTH] = [0x22; MASTER_KEY_LENGTH];

    #[tokio::test]
    async fn identity_is_encrypted_and_stable_across_reloads() {
        let pool = db::wireguard_identity_test_pool().await;
        let first = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let second = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        assert_eq!(first.public_key(), second.public_key());

        let row = query(
            "SELECT ciphertext, public_key, format_version, encryption_key_version
             FROM wireguard_server_identity WHERE id = 1",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        let ciphertext: Vec<u8> = row.get("ciphertext");
        assert_eq!(ciphertext.len(), PRIVATE_KEY_LENGTH + 16);
        assert_ne!(ciphertext.as_slice(), first.0.as_bytes());
        assert_eq!(row.get::<Vec<u8>, _>("public_key"), first.public_key());
        assert_eq!(row.get::<i64, _>("format_version"), FORMAT_VERSION);
        assert_eq!(
            row.get::<i64, _>("encryption_key_version"),
            INITIAL_ENCRYPTION_KEY_VERSION
        );
    }

    #[tokio::test]
    async fn concurrent_initialization_persists_one_identity() {
        let pool = db::wireguard_identity_test_pool().await;
        let (left, right) = tokio::join!(
            load_or_create_with_pool(&pool, &MASTER_KEY_A),
            load_or_create_with_pool(&pool, &MASTER_KEY_A)
        );
        assert_eq!(left.unwrap().public_key(), right.unwrap().public_key());
        let count: i64 = query("SELECT COUNT(*) AS count FROM wireguard_server_identity")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get("count");
        assert_eq!(count, 1);
    }

    #[tokio::test]
    async fn wrong_master_key_and_tampered_ciphertext_fail_closed() {
        let pool = db::wireguard_identity_test_pool().await;
        load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();

        let wrong_key_error = load_or_create_with_pool(&pool, &MASTER_KEY_B)
            .await
            .err()
            .unwrap();
        assert!(
            wrong_key_error
                .to_string()
                .contains("Failed to authenticate WireGuard server identity")
        );

        query("UPDATE wireguard_server_identity SET ciphertext = zeroblob(48) WHERE id = 1")
            .execute(&pool)
            .await
            .unwrap();
        let tamper_error = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .err()
            .unwrap();
        assert!(
            tamper_error
                .to_string()
                .contains("Failed to authenticate WireGuard server identity")
        );
    }

    #[test]
    fn master_key_file_requires_exactly_32_binary_bytes() {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "vnts2-wireguard-master-key-{}-{unique}.bin",
            std::process::id()
        ));

        std::fs::write(&path, [0u8; MASTER_KEY_LENGTH - 1]).unwrap();
        let error = load_master_key(&path).err().unwrap();
        assert!(error.to_string().contains("exactly 32 bytes"));

        std::fs::write(&path, MASTER_KEY_A).unwrap();
        assert_eq!(&*load_master_key(&path).unwrap(), &MASTER_KEY_A);
        std::fs::remove_file(path).unwrap();
    }

    #[tokio::test]
    async fn master_key_rotation_preserves_identity_and_rejects_old_key() {
        let pool = db::wireguard_identity_test_pool().await;
        let identity = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let public_key = identity.public_key();

        let rotation = rotate_master_key_with_pool(&pool, &MASTER_KEY_A, &MASTER_KEY_B)
            .await
            .unwrap();
        assert_eq!(rotation.public_key, public_key);
        assert_eq!(rotation.previous_version, 1);
        assert_eq!(rotation.new_version, 2);
        assert!(
            load_or_create_with_pool(&pool, &MASTER_KEY_A)
                .await
                .is_err()
        );
        assert_eq!(
            load_or_create_with_pool(&pool, &MASTER_KEY_B)
                .await
                .unwrap()
                .public_key(),
            public_key
        );
    }

    #[tokio::test]
    async fn failed_rotation_leaves_current_ciphertext_unchanged() {
        let pool = db::wireguard_identity_test_pool().await;
        load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let before = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();

        assert!(
            rotate_master_key_with_pool(&pool, &MASTER_KEY_B, &MASTER_KEY_A)
                .await
                .is_err()
        );
        assert!(
            rotate_master_key_with_pool(&pool, &MASTER_KEY_A, &MASTER_KEY_A)
                .await
                .is_err()
        );
        let after = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(after, before);
    }

    #[tokio::test]
    async fn stale_rotation_compare_and_swap_is_rejected() {
        let pool = db::wireguard_identity_test_pool().await;
        let identity = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let stale = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();
        let replacement = encrypt_identity(
            &MASTER_KEY_B,
            &identity,
            2,
            stale.created_at,
            stale.updated_at + 1,
        )
        .unwrap();
        query("UPDATE wireguard_server_identity SET updated_at = updated_at + 1 WHERE id = 1")
            .execute(&pool)
            .await
            .unwrap();

        let error = replace_wireguard_server_identity_with_pool(&pool, &stale, &replacement)
            .await
            .unwrap_err();
        assert!(error.to_string().contains("changed concurrently"));
        let current = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(current.encryption_key_version, 1);
        assert_eq!(current.ciphertext, stale.ciphertext);
    }

    #[tokio::test]
    async fn identity_rotation_replaces_identity_under_the_same_master_key() {
        let pool = db::wireguard_identity_test_pool().await;
        let current_identity = load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let before = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();

        let rotation = rotate_identity_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        assert_eq!(rotation.previous_public_key, current_identity.public_key());
        assert_ne!(rotation.new_public_key, rotation.previous_public_key);

        let after = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(after.encryption_key_version, before.encryption_key_version);
        assert_ne!(after.public_key, before.public_key);
        assert_ne!(after.nonce, before.nonce);
        assert_ne!(after.ciphertext, before.ciphertext);
        assert_eq!(
            load_or_create_with_pool(&pool, &MASTER_KEY_A)
                .await
                .unwrap()
                .public_key(),
            rotation.new_public_key
        );
        let count: i64 = query("SELECT COUNT(*) AS count FROM wireguard_server_identity")
            .fetch_one(&pool)
            .await
            .unwrap()
            .get("count");
        assert_eq!(count, 1);
    }

    #[tokio::test]
    async fn failed_identity_rotation_leaves_current_record_unchanged() {
        let pool = db::wireguard_identity_test_pool().await;
        load_or_create_with_pool(&pool, &MASTER_KEY_A)
            .await
            .unwrap();
        let before = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();

        assert!(
            rotate_identity_with_pool(&pool, &MASTER_KEY_B)
                .await
                .is_err()
        );
        let after = load_wireguard_server_identity_with_pool(&pool)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(after, before);
    }
}
