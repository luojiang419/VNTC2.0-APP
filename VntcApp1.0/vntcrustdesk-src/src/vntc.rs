use std::{
    collections::HashMap,
    net::{Ipv4Addr, SocketAddrV4},
};

use hbb_common::config::{self, keys};

pub const APP_DISPLAY_NAME: &str = "VNTC RustDesk";
pub const APP_ID: &str = "vntcrustdesk";
pub const APP_EXE_NAME: &str = "vntcrustdesk.exe";
pub const SERVICE_NAME: &str = "vntcrustdesk";
pub const DIRECT_ACCESS_PORT: i32 = 49999;
pub const DIRECT_ONLY_ERROR: &str =
    "Only VNT virtual IPv4 direct connections are supported. Use <IPv4> or <IPv4:49999>.";
pub const ACCESS_PASSWORD_CONFIG_SUCCESS_PREFIX: &str = "VNTC_ACCESS_PASSWORD_CONFIGURED:";

fn insert_setting(map: &mut HashMap<String, String>, key: &str, value: &str) {
    map.insert(key.to_owned(), value.to_owned());
}

pub fn is_direct_only_mode() -> bool {
    true
}

pub fn apply_profile() {
    *config::APP_NAME.write().unwrap() = APP_DISPLAY_NAME.to_owned();

    {
        let mut overwrite = config::OVERWRITE_SETTINGS.write().unwrap();
        insert_setting(&mut overwrite, keys::OPTION_DIRECT_SERVER, "Y");
        insert_setting(
            &mut overwrite,
            keys::OPTION_DIRECT_ACCESS_PORT,
            &DIRECT_ACCESS_PORT.to_string(),
        );
        insert_setting(&mut overwrite, keys::OPTION_ALLOW_AUTO_UPDATE, "N");
        insert_setting(&mut overwrite, keys::OPTION_CUSTOM_RENDEZVOUS_SERVER, "");
        insert_setting(&mut overwrite, keys::OPTION_RELAY_SERVER, "");
        insert_setting(&mut overwrite, keys::OPTION_API_SERVER, "");
        insert_setting(&mut overwrite, "key", "");
    }

    {
        let mut defaults = config::DEFAULT_SETTINGS.write().unwrap();
        insert_setting(&mut defaults, keys::OPTION_APPROVE_MODE, "click");
    }

    if !config::Config::get_permanent_password().is_empty()
        && config::Config::get_option(keys::OPTION_APPROVE_MODE) == "click"
    {
        config::Config::set_option(
            keys::OPTION_VERIFICATION_METHOD.to_owned(),
            "use-permanent-password".to_owned(),
        );
        config::Config::set_option(keys::OPTION_APPROVE_MODE.to_owned(), "password".to_owned());
    }

    {
        let mut hard = config::HARD_SETTINGS.write().unwrap();
        insert_setting(&mut hard, "disable-ab", "Y");
        insert_setting(&mut hard, "disable-account", "Y");
    }

    {
        let mut builtin = config::BUILTIN_SETTINGS.write().unwrap();
        insert_setting(&mut builtin, keys::OPTION_HIDE_SERVER_SETTINGS, "Y");
        insert_setting(&mut builtin, keys::OPTION_HIDE_PROXY_SETTINGS, "Y");
        insert_setting(&mut builtin, keys::OPTION_HIDE_WEBSOCKET_SETTINGS, "Y");
        insert_setting(&mut builtin, keys::OPTION_HIDE_TRAY, "Y");
        insert_setting(&mut builtin, "hide-stop-service", "Y");
        insert_setting(&mut builtin, "hide-help-cards", "Y");
        insert_setting(&mut builtin, "hide-powered-by-me", "Y");
        insert_setting(&mut builtin, keys::OPTION_DISABLE_CHANGE_ID, "Y");
    }
}

pub fn app_id() -> &'static str {
    APP_ID
}

pub fn executable_name() -> &'static str {
    APP_EXE_NAME
}

pub fn executable_basename() -> &'static str {
    APP_ID
}

pub fn service_name() -> &'static str {
    SERVICE_NAME
}

pub fn install_dir_name() -> &'static str {
    APP_DISPLAY_NAME
}

pub fn normalize_direct_target(target: &str) -> Result<String, &'static str> {
    let trimmed = target.trim();
    if trimmed.is_empty() || trimmed.ends_with(r"\r") || trimmed.ends_with("/r") {
        return Err(DIRECT_ONLY_ERROR);
    }
    if let Ok(addr) = trimmed.parse::<SocketAddrV4>() {
        return Ok(addr.to_string());
    }
    if let Ok(ipv4) = trimmed.parse::<Ipv4Addr>() {
        return Ok(format!("{ipv4}:{DIRECT_ACCESS_PORT}"));
    }
    Err(DIRECT_ONLY_ERROR)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_ipv4_without_port() {
        assert_eq!(
            normalize_direct_target("10.0.0.8").unwrap(),
            "10.0.0.8:49999"
        );
    }

    #[test]
    fn preserves_ipv4_with_port() {
        assert_eq!(
            normalize_direct_target("10.0.0.8:40123").unwrap(),
            "10.0.0.8:40123"
        );
    }

    #[test]
    fn rejects_non_ipv4_targets() {
        assert!(normalize_direct_target("123456789").is_err());
        assert!(normalize_direct_target("peer.example.com:49999").is_err());
        assert!(normalize_direct_target("10.0.0.8/r").is_err());
        assert!(normalize_direct_target("2001:db8::1").is_err());
    }

    #[test]
    fn profile_hides_tray_icon() {
        apply_profile();

        assert_eq!(
            config::BUILTIN_SETTINGS
                .read()
                .unwrap()
                .get(keys::OPTION_HIDE_TRAY)
                .map(String::as_str),
            Some("Y"),
        );
    }
}
