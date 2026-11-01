#[cfg(all(windows, feature = "windows-service-host"))]
fn main() -> anyhow::Result<()> {
    rust_lib_vnt_app::service::run()
}

#[cfg(not(all(windows, feature = "windows-service-host")))]
fn main() {
    eprintln!("vnt_service 仅支持启用 windows-service-host 功能的 Windows 构建");
    std::process::exit(1);
}
