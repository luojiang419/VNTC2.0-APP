# VNTS 2.0 服务端开发包

这个开发包是为了方便你在其他电脑继续开发而整理的，已经把三类内容放在一起：

- `web-ui-source/`
  当前正在使用的 `VNTS 2.0` Linux 服务端 Web UI 源码
- `official-vnts-source-2.0.0/`
  官方 `vnts 2.0.0` Rust 源代码
- `linux-deploy/`
  当前正在使用的 Linux 服务端部署文件与二进制
- `windows-deploy/`
  Windows 服务端部署目录，包含配置和服务安装脚本

## 你应该从哪里开始

如果你要继续开发 Web 管理页面：

- 先看 `web-ui-source/server.py`
- 前端页面在 `web-ui-source/static/`
- 后端逻辑在 `web-ui-source/vnt_panel/`

如果你要继续修改官方 `vnts` 服务端本体：

- 先看 `official-vnts-source-2.0.0/src/main.rs`
- 服务端核心逻辑在 `official-vnts-source-2.0.0/src/server/`
- 配置与证书相关在 `official-vnts-source-2.0.0/src/utils/`

如果你只是想先跑起来：

- 直接使用 `linux-deploy/`
- 里面已有 `install.sh`、`config.toml`、`vnts2.service` 和当前实际运行版二进制

如果你要部署 Windows 版服务端：

- 优先看 `windows-deploy/README.md`
- 服务安装脚本在 `windows-deploy/*.ps1`
- 核心二进制放在 `windows-deploy/vnts2.exe`

## 目录说明

```text
vnts2.0服务端开发包/
├── README.md
├── web-ui-source/
├── official-vnts-source-2.0.0/
├── linux-deploy/
└── windows-deploy/
```

## 建议开发方式

1. 在其他电脑上先解压这个开发包
2. 如果只改页面，优先在 `web-ui-source/` 里开发
3. 如果要联动修改服务端本体，再同步参考 `official-vnts-source-2.0.0/`
4. 最后把编译结果或部署文件更新到 `linux-deploy/`

## 当前默认信息

- `VNTS 服务端口`: `2222`
- `VNTS Web UI`: `2223`
- 默认登录用户名：`luojiang`
- 默认登录密码：`luojiang`

## 备注

这个包里的官方源码来自 `vnt-dev/vnts` 的 `2.0.0` 发布版本源码归档。
