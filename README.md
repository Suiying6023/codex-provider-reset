# Codex Provider Reset

一个最简 PowerShell 脚本，用于统一 Codex 的 `model_provider` 与本地线程状态。

## 文件

- `reset-provider.ps1`

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

## 依赖

- Windows PowerShell
- `sqlite3` 已加入系统 `PATH`
