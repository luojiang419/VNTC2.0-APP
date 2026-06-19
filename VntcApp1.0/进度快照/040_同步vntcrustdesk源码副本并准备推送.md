# 040 同步vntcrustdesk源码副本并准备推送

## 时间
- 2026-06-19

## 本次目标
- 将 `D:\Myproject\vnt2.0\vntcrustdesk-src` 对应源码复制一份到 `D:\Myproject\vnt2.0\VntcApp1.0`。
- 让复制后的源码副本进入当前 GitHub 仓库的可提交范围。
- 重新提交并推送最新代码到 GitHub。

## 本次已完成

### 1. 已读取历史进度快照
- 当前最新历史快照为：
  - `039_Android新版本3.0编译完成.md`
- 历史快照已带数字序号，本轮继续使用 `040`。

### 2. 已完成大改动前备份
- 备份目录：
  - `D:\Myproject\vnt2.0\backup\023_VntcApp1源码同步前备份_20260619_200604`
- 备份策略：
  - 备份当前 `VntcApp1.0` 源码目录
  - 排除构建缓存、日志、发行包和临时目录
  - `backup` 目录保留最近 10 次备份

### 3. 已调整 Git 忽略规则
- 修改：
  - `D:\Myproject\vnt2.0\.gitignore`
  - `D:\Myproject\vnt2.0\VntcApp1.0\.gitignore`
- 处理内容：
  - 继续忽略项目根目录原始 `vntcrustdesk-src`
  - 允许 `VntcApp1.0\vntcrustdesk-src` 作为源码副本进入 Git 跟踪范围

### 4. 已同步 vntcrustdesk 源码副本
- 源目录：
  - `D:\Myproject\vnt2.0\vntcrustdesk-src`
- 目标目录：
  - `D:\Myproject\vnt2.0\VntcApp1.0\vntcrustdesk-src`
- 已排除：
  - `.git`
  - `target`
  - `build`
  - `.dart_tool`
  - `logs`
  - `artifacts`
  - `vntcrustdesk`
  - `dist`
  - `output`
  - 常见二进制/安装包/调试符号文件
- 当前副本统计：
  - 文件数：`948`
  - 大小：约 `15.2 MB`

### 5. 已清理副本内生成文件
- 已删除 Flutter 本机生成文件：
  - `.flutter-plugins`
  - `.flutter-plugins-dependencies`
  - `build_windows_verbose.log`
  - `local.properties`
  - `GeneratedPluginRegistrant.*`
  - `Generated.xcconfig`
  - `flutter_export_environment.sh`

### 6. 已按源仓库跟踪清单收口副本内容
- 处理内容：
  - 保留源仓库及其子模块已跟踪的源码文件
  - 删除未在源仓库跟踪清单内的生成桥接文件、缓存和制品文件

## 当前修改位置
- `D:\Myproject\vnt2.0\.gitignore`
  - 调整根目录 `vntcrustdesk-src` 忽略范围
- `D:\Myproject\vnt2.0\VntcApp1.0\.gitignore`
  - 移除对 `VntcApp1.0\vntcrustdesk-src` 的整体忽略
- `D:\Myproject\vnt2.0\VntcApp1.0\vntcrustdesk-src`
  - 新增源码副本目录
- `D:\Myproject\vnt2.0\VntcApp1.0\进度快照\040_同步vntcrustdesk源码副本并准备推送.md`
  - 新增本次进度快照

## 本次验证
- 已确认目标源码副本关键文件存在：
  - `Cargo.toml`
  - `flutter\pubspec.yaml`
  - `src\client.rs`
- 已确认源码副本内没有超过 `90 MB` 的文件。
- 已确认 Git 可以看到 `VntcApp1.0\vntcrustdesk-src` 作为新增内容。

## 待办清单
- 将本次改动显式加入 Git 暂存区。
- 提交本次源码同步改动。
- 推送到 GitHub `main` 分支。
- 推送后核对本地 HEAD 与远端 `origin/main` 是否一致。

## 下一步要做什么
- 执行 Git 暂存、提交、推送，并确认 GitHub 最新提交记录。
