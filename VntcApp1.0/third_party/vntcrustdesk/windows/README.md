# vntcrustdesk Windows 产物目录

当前仓库**不存放** `vntcrustdesk` 的源码，源码应维护在独立 fork 仓库中。  
本目录只消费 Windows 构建产物，供当前项目的安装器集成使用。

## 期望文件

- `dist/vntcrustdesk.msi`
- `dist/vntcrustdesk.version.json`

## 推荐接入方式

1. 在独立 `vntcrustdesk` fork 仓库中完成编译与 MSI 打包。
2. 使用当前仓库的 `scripts/stage_vntcrustdesk_artifact.ps1` 将产物复制到 `dist/`。
3. 再执行当前项目的 `scripts/export_installer_package.ps1` 生成主安装包。

## 注意

- 不再使用旧的便携 runtime/内嵌 rustdesk 目录方案。
- 当前仓库只认 `vntcrustdesk.msi` 这一条新链路。
