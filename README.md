# Codex Provider Reset

一个最简 PowerShell 脚本，用于统一 Codex 的 `model_provider` 与本地线程状态。

## 原因

Codex 会把本地线程状态记录到 `~/.codex/state_5.sqlite`，其中每条线程都带有一个 `model_provider`。

如果不同中转站或 `CC Switch` 写出的配置使用了不同的 `model_provider`，那么本地线程会被分到不同的 provider 命名空间中。

## 思路

脚本不处理聊天内容文件本身，只处理当前配置与本地线程状态中的 `model_provider`：

- `current` 模式：按当前 Codex 配置里的标记统一历史线程
- `ccs` 模式：按 `CC Switch` 的 `codex` 配置统一为 `codex`

脚本还支持输出或补回线程原来的工作区列表，方便 Codex 在界面里重新显示这些线程。

## 文件

- `reset-provider.ps1`
- `sqlite3.exe`

脚本会优先使用同目录下的 `sqlite3.exe`，不依赖系统 PATH。

## 运行模式

### `current`

读取当前 `~/.codex/config.toml` 中的 `model_provider`，并将 `~/.codex/state_5.sqlite` 中的所有线程统一为这个值。

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode current
```

### `ccs`

将 `CC Switch` 中 `app_type='codex'` 的 provider 配置统一为 `model_provider = "codex"`，并同时更新：

- `~/.codex/config.toml`
- `~/.codex/state_5.sqlite`

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs
```

## 可选参数

### 工作区处理

- `-WorkspaceAction list`
  输出线程涉及的工作区列表
- `-WorkspaceAction sync`
  把检测到的活跃线程工作区补回 `~/.codex/.codex-global-state.json`
- `-WorkspaceAction none`
  不输出工作区信息，也不修改工作区配置

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs -WorkspaceAction list
```

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs -WorkspaceAction sync
```

如果本机路径不是默认值，可以手动指定：

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

如果需要补回工作区配置，也可以显式指定全局状态文件：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode ccs `
  -WorkspaceAction sync `
  -GlobalStatePath "C:\path\to\.codex\.codex-global-state.json"
```

如果你不想使用仓库内自带的 `sqlite3.exe`，也可以显式指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 `
  -Mode current `
  -Sqlite3Path "C:\path\to\sqlite3.exe"
```

## 依赖

- Windows PowerShell

## 注意

- 脚本会直接修改本地数据库与配置文件
- 脚本不会重建损坏或空白的会话文件
- 如果使用 `-WorkspaceAction sync`，脚本会修改 `~/.codex/.codex-global-state.json`
