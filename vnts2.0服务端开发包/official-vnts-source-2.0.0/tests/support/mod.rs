use std::path::Path;
use std::process::Command;

pub fn capture_openwrt_logs(command: &mut Command, config: &Path) {
    #[cfg(feature = "openwrt")]
    {
        // 路由器只输出控制台日志；测试自行捕获到隔离临时目录，保持原有密钥断言。
        let folder = config.parent().unwrap().join("logs");
        std::fs::create_dir_all(&folder).unwrap();
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(folder.join("vnts2.log"))
            .unwrap();
        command
            .env("RUST_LOG", "info")
            .stdout(std::process::Stdio::from(file.try_clone().unwrap()))
            .stderr(std::process::Stdio::from(file));
    }
    #[cfg(not(feature = "openwrt"))]
    let _ = (command, config);
}
