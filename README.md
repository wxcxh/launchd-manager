# Launchd Manager

一个 macOS 本地工具，用来查看和管理当前用户的 `~/Library/LaunchAgents`。

## 功能

- 查看当前用户的 LaunchAgents
- 查看任务命令、plist 路径、执行时间、启用状态
- 使用小时/分钟下拉菜单修改每天固定时间
- 启用、停用和通过 `launchctl kickstart` 立即执行任务
- 编辑任务备注，并写回 plist 自定义字段
- 为没有备注的任务自动生成 AI 备注
- 通过 AI 配置弹窗设置 OpenAI 兼容接口、模型 ID 和 API 密钥
- 测试 AI 接口连通性
- 操作成功或失败时显示自动消失的提示
- 未选中任务时显示新增脚本入口

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

## macOS 提示 App 已损坏

如果从 GitHub Release 下载后，macOS 提示：

```text
“launchd 定时任务管理.app”已损坏，无法打开。你应该将它移到废纸篓。
```

通常不是文件真的损坏，而是 macOS Gatekeeper 给未签名应用加了隔离属性。可以在终端执行：

```bash
xattr -dr com.apple.quarantine "/Applications/launchd 定时任务管理.app"
```

如果 app 不在 `/Applications`，把命令里的路径换成实际位置，例如：

```bash
xattr -dr com.apple.quarantine "/Users/你的用户名/Downloads/launchd 定时任务管理.app"
```

然后重新双击打开。也可以右键点击 app，选择“打开”，再在系统提示里确认打开。

## 说明

- 只管理当前用户的 LaunchAgents
- 会直接读写对应 plist 文件
- 支持的计划类型目前是每天固定时刻执行
- AI 备注只会处理 `CodexNote` 为空的任务，不会覆盖已有备注
- AI 接口配置保存在本机 UserDefaults，不写入仓库
- 构建出的 app 允许访问 HTTP 接口，以兼容本地或自建 OpenAI 兼容网关
- 新增脚本界面目前是入口占位，创建 plist 的流程还未接入

## License

MIT
