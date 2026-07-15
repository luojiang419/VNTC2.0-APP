use anyhow::{Context, anyhow};
use rcgen::generate_simple_self_signed;
use rustls::pki_types;
use rustls::pki_types::pem::PemObject;
use std::fs::File;
use std::path::{Path, PathBuf};

pub fn get_cert_and_key(
    cert_path: Option<PathBuf>,
    key_path: Option<PathBuf>,
) -> anyhow::Result<(
    Vec<pki_types::CertificateDer<'static>>,
    pki_types::PrivateKeyDer<'static>,
)> {
    let default_cert_path = Path::new("cert.pem");
    let default_key_path = Path::new("key.pem");

    if let (Some(c_path), Some(k_path)) = (cert_path, key_path) {
        let certs = load_certs(&c_path)?;
        let key = load_private_key(&k_path)?;
        return Ok((certs, key));
    }

    if default_cert_path.exists() && default_key_path.exists() {
        let certs = load_certs(default_cert_path)?;
        let key = load_private_key(default_key_path)?;
        return Ok((certs, key));
    }

    let subject_alt_names = vec!["localhost".to_string(), "127.0.0.1".to_string()];
    let cert = generate_simple_self_signed(subject_alt_names)?;

    let cert_pem = cert.cert.pem();
    let key_pem = cert.signing_key.serialize_pem();

    std::fs::write(default_cert_path, cert_pem).context("无法写入 cert.pem")?;
    std::fs::write(default_key_path, key_pem).context("无法写入 key.pem")?;

    log::info!(
        "自动创建证书,cert={:?} ,key={:?}",
        default_cert_path,
        default_key_path
    );

    let cert_der = cert.cert.der().to_vec();
    let cert_parsed = pki_types::CertificateDer::from(cert_der);

    let key_der = cert.signing_key.serialize_der();
    let key_parsed =
        pki_types::PrivateKeyDer::try_from(key_der).map_err(|e| anyhow!("私钥转换失败: {}", e))?;

    Ok((vec![cert_parsed], key_parsed))
}

fn load_certs(path: &Path) -> anyhow::Result<Vec<pki_types::CertificateDer<'static>>> {
    let file = File::open(path).context("无法打开证书文件")?;
    pki_types::CertificateDer::pem_reader_iter(file)
        .collect::<anyhow::Result<Vec<_>, _>>()
        .context("证书解析错误")
}

fn load_private_key(path: &Path) -> anyhow::Result<pki_types::PrivateKeyDer<'static>> {
    let file = File::open(path).context("无法打开私钥文件")?;
    match pki_types::PrivateKeyDer::from_pem_reader(file) {
        Ok(key) => Ok(key),
        Err(pki_types::pem::Error::NoItemsFound) => Err(anyhow!("未找到有效私钥")),
        Err(error) => Err(error).context("私钥解析错误"),
    }
}
