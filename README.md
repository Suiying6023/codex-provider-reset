# Codex Provider Reset

一个最简 PowerShell 脚本，用于统一 Codex 的 `model_provider`、修复本地线程状态，并在需要时补回线程原来的工作区。

## 推荐先看

如果你需要更完整的方案，例如：

- 更完善的备份与恢复
- 更完整的同步逻辑
- 图形界面
- 更适合直接分发给普通用户

优先使用现成项目：

[Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)

这个仓库保留的是一个**足够用、方便自己改的极简脚本版**。

## 当前脚本能做什么

当前仓库内的 `reset-provider.ps1` 可以完成这些事情：

1. 按当前 Codex 配置里的 `model_provider` 统一本地线程
2. 按 `CC Switch` 的 `codex` provider 配置统一为 `codex`
3. 输出线程原来的工作区列表
4. 在需要时把活跃线程对应的工作区补回 Codex 工作区配置，帮助这些线程重新显示出来

## 原因

Codex 会把本地线程状态记录到 `~/.codex/state_5.sqlite`，其中每条线程都带有一个 `model_provider`。

如果不同中转站或 `CC Switch` 写出的配置使用了不同的 `model_provider`，那么本地线程会被分到不同的 provider 命名空间中。

另外，即使线程已经恢复，如果这些线程原来的 `cwd` 不在当前 Codex 工作区列表里，界面中也可能不会完整显示。

## 思路

脚本不处理聊天内容文件本身，只处理：

- 当前配置里的 `model_provider`
- 本地线程状态库中的 `model_provider`
- 可选的工作区列表同步

## 文件

- `reset-provider.ps1`
- `sqlite3.exe`

脚本会优先使用同目录下的 `sqlite3.exe`，不依赖系统 PATH。

## 使用方法

### 1. 按当前配置统一线程

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode current
```

适合：

- 当前 Codex 配置已经是你想要的 provider
- 只需要把历史线程统一到当前值

### 2. 按 CC Switch 统一为 `codex`

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs
```

适合：

- 你继续使用 `CC Switch`
- 想把 `CC Switch` 的 `codex` provider 模板与本地线程统一到 `codex`

### 3. 查看线程原来的工作区列表

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs -WorkspaceAction list
```

输出中会列出每个工作区下的：

- 活跃线程数
- 归档线程数

### 4. 补回活跃线程工作区

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs -WorkspaceAction sync
```

这个模式会把检测到的活跃线程工作区补回：

- `~/.codex/.codex-global-state.json`
  中的 `active-workspace-roots`
- `electron-saved-workspace-roots`
- `project-order`

适合：

- 线程在数据库里已经是活跃状态
- 但因为原工作区没在当前界面里激活，导致列表显示不全

## 可选参数

如果默认路径不一致，可以手动指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode current `
  -CodexConfigPath "C:\path\to\.codex\config.toml" `
  -CodexStateDbPath "C:\path\to\.codex\state_5.sqlite"
```

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode ccs `
  -CcSwitchDbPath "C:\path\to\.cc-switch\cc-switch.db"
```

如果需要显式指定 SQLite 可执行文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode current `
  -Sqlite3Path "C:\path\to\sqlite3.exe"
```

如果需要显式指定 Codex 全局状态文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode ccs `
  -WorkspaceAction sync `
  -GlobalStatePath "C:\path\to\.codex\.codex-global-state.json"
```

## 依赖

- Windows PowerShell

## 注意事项

- 脚本会直接修改本地数据库与配置文件
- 脚本不会重建损坏或空白的会话文件
- 如果只想先确认工作区分布，建议先使用 `-WorkspaceAction list`
- 如果你需要更强的兼容性、备份、恢复和 GUI，建议直接使用：
  [Dailin521/codex-provider-sync](https://github.com/Dailin521/codex-provider-sync)
