//! OpenWrt 输入路由的内核入口。只新增本次连接的路由，不覆盖现有系统路由。
use std::process::Command;

use anyhow::{Context, Result, bail};
use ipnet::Ipv4Net;

pub(crate) struct InputRoutes {
    tun: String,
    installed: Vec<Ipv4Net>,
}

pub(crate) fn validate(routes: &[Ipv4Net], overlay: Ipv4Net) -> Result<()> {
    for (index, route) in routes.iter().enumerate() {
        if route.prefix_len() == 0
            || route.contains(&overlay.network())
            || overlay.contains(&route.network())
        {
            bail!("输入路由不能覆盖默认路由或虚拟网段：{route}");
        }
        if routes[..index].contains(route) {
            bail!("重复的输入路由：{route}");
        }
    }
    Ok(())
}

impl InputRoutes {
    pub(crate) fn install(tun: String, routes: Vec<Ipv4Net>, overlay: Ipv4Net) -> Result<Self> {
        validate(&routes, overlay)?;
        let mut guard = Self {
            tun,
            installed: Vec::new(),
        };
        for route in routes {
            let output = Command::new("ip")
                .args([
                    "-4",
                    "route",
                    "add",
                    &route.to_string(),
                    "dev",
                    &guard.tun,
                    "proto",
                    "186",
                ])
                .output()
                .context("无法执行 OpenWrt ip 路由命令")?;
            if !output.status.success() {
                bail!(
                    "添加输入路由 {route} 失败（不会覆盖已有路由）：{}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            guard.installed.push(route);
        }
        Ok(guard)
    }
}

impl Drop for InputRoutes {
    fn drop(&mut self) {
        for route in self.installed.iter().rev() {
            let _ = Command::new("ip")
                .args([
                    "-4",
                    "route",
                    "del",
                    &route.to_string(),
                    "dev",
                    &self.tun,
                    "proto",
                    "186",
                ])
                .output();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_default_overlay_and_duplicate_routes() {
        let overlay = "10.26.0.0/24".parse().unwrap();
        for route in ["0.0.0.0/0", "10.0.0.0/8", "10.26.0.5/32"] {
            assert!(validate(&[route.parse().unwrap()], overlay).is_err());
        }
        let route = "192.168.50.0/24".parse().unwrap();
        assert!(validate(&[route, route], overlay).is_err());
        assert!(validate(&[route, "192.168.60.0/24".parse().unwrap()], overlay).is_ok());
    }
}
