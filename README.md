# Launchd Manager

一个 macOS 本地工具，用来查看和管理当前用户的 `~/Library/LaunchAgents`。

## 功能

- 查看当前用户的 LaunchAgents
- 查看任务命令、plist 路径、执行时间、启用状态
- 修改每天固定时间
- 启用、停用和立即执行任务
- 编辑任务备注，并写回 plist 自定义字段

## 要求

- macOS 12+
- Xcode Command Line Tools

## 启动源码

```bash
./scripts/open_launchd_manager.sh
```

## 构建 `.app`

```bash
./scripts/build_launchd_manager_app.sh
```

构建后会生成可双击打开的 `launchd 定时任务管理.app`，也会在 GitHub Release 中提供对应压缩包。

## 说明

- 只管理当前用户的 LaunchAgents
- 会直接读写对应 plist 文件
- 支持的计划类型目前是每天固定时刻执行

## License

MIT
