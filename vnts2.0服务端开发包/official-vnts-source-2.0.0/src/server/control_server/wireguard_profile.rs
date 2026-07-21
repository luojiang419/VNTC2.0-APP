use super::db::{
    self, EncryptedWireGuardPeerSecret, WireGuardPeerProfileRecord,
    load_all_wireguard_peer_secrets_with_pool,
};
use super::wireguard_identity::load_master_key;
use anyhow::{Context, ensure};
use chacha20poly1305::{
    XChaCha20Poly1305, XNonce,
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
};
use sqlx_sqlite::SqlitePool;
use std::path::Path;
use zeroize::Zeroizing;

const FORMAT_VERSION: i64 = 1;
const INITIAL_KEY_VERSION: i64 = 1;
const AAD_CONTEXT: &[u8] = b"vnts2/wireguard-peer-secret";

pub(crate) async fn save_generated_profile(
    master_key_file: &Path,
    profile: &WireGuardPeerProfileRecord,
    public_key: [u8; 32],
    private_key: [u8; 32],
) -> anyhow::Result<()> {
    let master_key = load_master_key(master_key_file)?;
    let secret = encrypt_secret(
        &master_key,
        profile,
        public_key,
        &private_key,
        INITIAL_KEY_VERSION,
    )?;
    db::save_wireguard_peer_profile(profile, Some(&secret)).await
}

pub(crate) async fn save_profile(profile: &WireGuardPeerProfileRecord) -> anyhow::Result<()> {
    db::save_wireguard_peer_profile(profile, None).await
}

pub(crate) async fn load_private_key(
    master_key_file: &Path,
    network_code: &str,
    peer_id: &str,
) -> anyhow::Result<Option<Zeroizing<[u8; 32]>>> {
    let Some(record) = db::load_wireguard_peer_secret(network_code, peer_id).await? else {
        return Ok(None);
    };
    let master_key = load_master_key(master_key_file)?;
    decrypt_secret(&master_key, &record).map(Some)
}

fn encrypt_secret(
    master_key: &[u8; 32],
    profile: &WireGuardPeerProfileRecord,
    public_key: [u8; 32],
    private_key: &[u8; 32],
    encryption_key_version: i64,
) -> anyhow::Result<EncryptedWireGuardPeerSecret> {
    ensure!(
        encryption_key_version > 0,
        "WireGuard peer secret key version must be positive"
    );
    let cipher = XChaCha20Poly1305::new_from_slice(master_key)?;
    let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
    let aad = associated_data(
        FORMAT_VERSION,
        encryption_key_version,
        &profile.network_code,
        &profile.peer_id,
        &public_key,
    );
    let ciphertext = cipher
        .encrypt(
            &nonce,
            Payload {
                msg: private_key,
                aad: &aad,
            },
        )
        .map_err(|_| anyhow::anyhow!("Failed to encrypt WireGuard peer private key"))?;
    Ok(EncryptedWireGuardPeerSecret {
        network_code: profile.network_code.clone(),
        peer_id: profile.peer_id.clone(),
        format_version: FORMAT_VERSION,
        encryption_key_version,
        nonce: nonce.to_vec(),
        ciphertext,
        public_key: public_key.to_vec(),
        created_at: profile.created_at,
        updated_at: profile.updated_at,
    })
}

fn decrypt_secret(
    master_key: &[u8; 32],
    record: &EncryptedWireGuardPeerSecret,
) -> anyhow::Result<Zeroizing<[u8; 32]>> {
    ensure!(
        record.format_version == FORMAT_VERSION,
        "Unsupported WireGuard peer secret format"
    );
    ensure!(
        record.encryption_key_version > 0,
        "Invalid WireGuard peer secret key version"
    );
    let public_key: [u8; 32] = record
        .public_key
        .as_slice()
        .try_into()
        .context("Invalid WireGuard peer public key length")?;
    let nonce: [u8; 24] = record
        .nonce
        .as_slice()
        .try_into()
        .context("Invalid WireGuard peer secret nonce length")?;
    let aad = associated_data(
        record.format_version,
        record.encryption_key_version,
        &record.network_code,
        &record.peer_id,
        &public_key,
    );
    let plaintext = Zeroizing::new(
        XChaCha20Poly1305::new_from_slice(master_key)?
            .decrypt(
                &XNonce::from(nonce),
                Payload {
                    msg: &record.ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| anyhow::anyhow!("Failed to authenticate WireGuard peer private key"))?,
    );
    let private_key: [u8; 32] = plaintext
        .as_slice()
        .try_into()
        .context("Invalid decrypted WireGuard peer private key length")?;
    let derived_public =
        x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(private_key)).to_bytes();
    ensure!(
        derived_public == public_key,
        "WireGuard peer private key does not match public key"
    );
    Ok(Zeroizing::new(private_key))
}

pub(super) async fn reencrypt_all_peer_secrets_with_pool(
    pool: &SqlitePool,
    current_master_key: &[u8; 32],
    new_master_key: &[u8; 32],
    new_key_version: i64,
    updated_at: i64,
) -> anyhow::Result<Vec<EncryptedWireGuardPeerSecret>> {
    let current = load_all_wireguard_peer_secrets_with_pool(pool).await?;
    let mut replacements = Vec::with_capacity(current.len());
    for record in current {
        let private_key = decrypt_secret(current_master_key, &record)?;
        let public_key: [u8; 32] = record.public_key.as_slice().try_into()?;
        let profile = WireGuardPeerProfileRecord {
            network_code: record.network_code.clone(),
            peer_id: record.peer_id.clone(),
            dns_servers: None,
            persistent_keepalive: 25,
            routes: vec![],
            config_available: true,
            created_at: record.created_at,
            updated_at,
        };
        replacements.push(encrypt_secret(
            new_master_key,
            &profile,
            public_key,
            &private_key,
            new_key_version,
        )?);
    }
    Ok(replacements)
}

fn associated_data(
    format_version: i64,
    encryption_key_version: i64,
    network_code: &str,
    peer_id: &str,
    public_key: &[u8; 32],
) -> Vec<u8> {
    let mut aad = Vec::new();
    aad.extend_from_slice(AAD_CONTEXT);
    aad.extend_from_slice(&format_version.to_be_bytes());
    aad.extend_from_slice(&encryption_key_version.to_be_bytes());
    aad.extend_from_slice(&(network_code.len() as u32).to_be_bytes());
    aad.extend_from_slice(network_code.as_bytes());
    aad.extend_from_slice(&(peer_id.len() as u32).to_be_bytes());
    aad.extend_from_slice(peer_id.as_bytes());
    aad.extend_from_slice(public_key);
    aad
}

#[cfg(test)]
mod tests {
    use super::*;
    use ipnet::Ipv4Net;

    fn profile() -> WireGuardPeerProfileRecord {
        WireGuardPeerProfileRecord {
            network_code: "network-a".to_string(),
            peer_id: "peer-a".to_string(),
            dns_servers: None,
            persistent_keepalive: 25,
            routes: vec![],
            config_available: true,
            created_at: 1,
            updated_at: 1,
        }
    }

    #[test]
    fn peer_private_key_is_encrypted_authenticated_and_owner_bound() {
        let master_key = [0x11; 32];
        let private_key = [0x22; 32];
        let public_key =
            x25519_dalek::PublicKey::from(&x25519_dalek::StaticSecret::from(private_key))
                .to_bytes();
        let encrypted =
            encrypt_secret(&master_key, &profile(), public_key, &private_key, 1).unwrap();
        assert_ne!(encrypted.ciphertext.as_slice(), private_key);
        assert_eq!(
            *decrypt_secret(&master_key, &encrypted).unwrap(),
            private_key
        );

        let mut moved = encrypted.clone();
        moved.peer_id = "peer-b".to_string();
        assert!(decrypt_secret(&master_key, &moved).is_err());
        assert!(decrypt_secret(&[0x33; 32], &encrypted).is_err());
    }

    #[test]
    fn route_record_uses_normalized_ipv4_network() {
        let route = db::WireGuardPeerRouteRecord {
            lan_network: "192.168.10.0/24".parse::<Ipv4Net>().unwrap(),
            vnt_cli_ip: "10.26.0.2".parse().unwrap(),
        };
        assert_eq!(route.lan_network.to_string(), "192.168.10.0/24");
    }
}
