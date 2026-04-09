# Codex Provider Reset

一个最简 PowerShell 脚本，用于修复 Codex 桌面端在切换不同中转站或不同 `model_provider` 后，历史会话看起来“消失”或被拆散的问题。

> 说明：本项目的脚本与说明文档内容由 Codex 根据需求整理与编写。

## 问题原因

Codex 会把本地线程状态记录到 `~/.codex/state_5.sqlite` 中，每条线程都带有一个 `model_provider` 字段。

如果不同中转站或 `CC Switch` 写出的配置分别使用了不同的 `model_provider`，例如：

- `codex`
- `OpenAI`
- `custom`
- `quicklyapi`

那么历史线程就会被分散到不同的 provider 命名空间中。

结果就是：

- 聊天内容文件实际上还保存在本地
- 但切换 API 后，历史列表会像“丢失”了一样

## 修复思路

本脚本不修改聊天内容文件本身，只修改线程状态中的 `model_provider` 标记，使历史线程重新统一到同一个 provider 命名空间下，从而恢复正常展示。

## 文件说明

本目录只包含一个脚本：

- `reset-provider.ps1`

脚本不会生成备份、日志或其他额外文件。

## 运行模式

- `current`
  只依赖当前 Codex 配置与本地状态库，不依赖 `CC Switch`
- `ccs`
  会读取 `CC Switch` 的 `codex` provider 配置，并统一重置为 `codex`

## 使用方法

### 方法 1：按当前 Codex 配置重置

读取当前 `~/.codex/config.toml` 中的 `model_provider`，并将所有历史线程重置为这个值。

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode current
```

适用场景：

- 你已经手动把当前 Codex 配置调整正确
- 只希望把旧历史线程统一到当前使用的 provider
- 你不使用 `CC Switch`，或者不想修改 `CC Switch` 的数据库

### 方法 2：按 CC Switch 统一为 codex

读取 `CC Switch` 的 `codex` provider 配置，并统一将：

- `CC Switch` 中 `codex` provider 的模板配置
- 当前 `~/.codex/config.toml`
- `~/.codex/state_5.sqlite` 中的历史线程

全部重置为：

```toml
model_provider = "codex"
```

运行命令：

```powershell
powershell -ExecutionPolicy Bypass -File .\reset-provider.ps1 -Mode ccs
```

适用场景：

- 你继续使用 `CC Switch`
- 希望今后切换不同中转站时，不再把会话拆散

## 可选路径参数

如果对方机器上的默认路径不同，可以显式传入：

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

## 注意事项

- 脚本会直接修改本地数据库与配置文件
- 脚本不会重建损坏或空白的会话文件
- 如果某个会话文件本身是零字节或已损坏，它无法被恢复
- 当前版本已经避免依赖 `sqlite3 -json` 的外层 JSON 解析，分享给他人时兼容性比早期版本更好

## License

MIT
