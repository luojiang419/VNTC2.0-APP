#[cfg(not(feature = "openwrt"))]
use std::{io::Write, path::PathBuf};

#[cfg(not(feature = "openwrt"))]
pub fn log_init(log_name: &str) {
    let path = PathBuf::from("logs");
    if !path.exists() {
        let _ = std::fs::create_dir(&path);
    }

    let log_config = path.join("log4rs.yaml");
    if !log_config.exists() {
        if let Ok(mut f) = std::fs::File::create(&log_config) {
            let log_file = path.join(format!("{log_name}.log"));
            let log_file_pattern = path.join(format!("{log_name}.{{}}.log"));

            let c = format!(
                r#"
refresh_rate: 30 seconds
appenders:
  rolling_file:
    kind: rolling_file
    path: {}
    append: true
    encoder:
      pattern: "{{d}} [{{f}}:{{L}}] {{h({{l}})}} {{M}}:{{m}}{{n}}"
    policy:
      kind: compound
      trigger:
        kind: size
        limit: 10 mb
      roller:
        kind: fixed_window
        pattern: {}
        base: 1
        count: 5
  console:
    kind: console
    encoder:
      pattern: "{{d}} {{h({{l}})}} {{m}}{{n}}"
root:
  level: info
  appenders:
    - rolling_file
    - console
"#,
                log_file.display(),
                log_file_pattern.display()
            );
            let _ = f.write_all(c.as_bytes());
        }
    }

    let _ = log4rs::init_file(log_config, Default::default());
}

// OpenWrt 由 procd 收集 stderr/stdout，避免日志写满路由器闪存。
#[cfg(feature = "openwrt")]
pub fn log_init(_log_name: &str) {
    use log4rs::{
        append::console::ConsoleAppender,
        config::{Appender, Config, Root},
    };
    let level = std::env::var("RUST_LOG")
        .ok()
        .and_then(|value| value.parse::<log::LevelFilter>().ok())
        .unwrap_or(log::LevelFilter::Warn);
    if let Ok(config) = Config::builder()
        .appender(
            Appender::builder().build("console", Box::new(ConsoleAppender::builder().build())),
        )
        .build(Root::builder().appender("console").build(level))
    {
        let _ = log4rs::init_config(config);
    }
}
