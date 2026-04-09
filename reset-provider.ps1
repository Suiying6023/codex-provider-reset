param(
    [ValidateSet("current", "ccs")]
    [string]$Mode = "current",
    [string]$CodexConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$CodexStateDbPath = (Join-Path $HOME ".codex\state_5.sqlite"),
    [string]$CcSwitchDbPath = (Join-Path $HOME ".cc-switch\cc-switch.db"),
    [string]$Sqlite3Path = "",
    [ValidateSet("list", "sync", "none")]
    [string]$WorkspaceAction = "list",
    [string]$GlobalStatePath = (Join-Path $HOME ".codex\.codex-global-state.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

function Escape-SqlLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value -replace "'", "''"
}

function Resolve-Sqlite3Path {
    param(
        [AllowEmptyString()]
        [string]$PreferredPath
    )

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (-not (Test-Path -LiteralPath $PreferredPath)) {
            throw "sqlite3 not found: $PreferredPath"
        }
        return $PreferredPath
    }

    $bundled = Join-Path $PSScriptRoot "sqlite3.exe"
    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }

    $command = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    throw "sqlite3 executable not found. Put sqlite3.exe next to reset-provider.ps1 or pass -Sqlite3Path."
}

function Invoke-SqlNonQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $Sql | & $script:Sqlite3Exe $Database | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 update failed."
    }
}

function Invoke-SqlScalar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql
    )

    $value = & $script:Sqlite3Exe $Database $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 scalar query failed."
    }

    if ($value -is [System.Array]) {
        return ($value -join "")
    }

    return [string]$value
}

function Convert-HexToUtf8String {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Hex
    )

    if ([string]::IsNullOrEmpty($Hex)) {
        return ""
    }

    $bytes = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $Hex.Length; $i += 2) {
        $bytes[$i / 2] = [Convert]::ToByte($Hex.Substring($i, 2), 16)
    }

    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-SqlRows {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database,
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )

    $separator = [char]31
    $raw = & $script:Sqlite3Exe -separator $separator $Database $Sql
    if ($LASTEXITCODE -ne 0) {
        throw "sqlite3 row query failed."
    }

    $lines = @()
    if ($null -eq $raw) {
        return @()
    } elseif ($raw -is [System.Array]) {
        $lines = $raw
    } else {
        $text = [string]$raw
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @()
        }
        $lines = @($text -split "`r?`n")
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = [string]$line -split [regex]::Escape([string]$separator), $Columns.Count
        $row = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $row[$Columns[$i]] = if ($i -lt $parts.Count) { $parts[$i] } else { "" }
        }
        $result.Add([pscustomobject]$row) | Out-Null
    }

    return $result
}

function Get-CurrentProviderId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $content = Get-Content -LiteralPath $ConfigPath -Raw
    $match = [regex]::Match($content, '(?m)^model_provider\s*=\s*"([^"]+)"\s*$')
    if (-not $match.Success) {
        throw "model_provider not found in $ConfigPath"
    }

    return $match.Groups[1].Value
}

function Get-SettingsConfigText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Settings
    )

    if ($null -eq $Settings) {
        return $null
    }

    if ($Settings -is [System.Array]) {
        if ($Settings.Count -eq 1) {
            return Get-SettingsConfigText -Settings $Settings[0]
        }
        return $null
    }

    if ($Settings -is [System.Collections.IDictionary]) {
        if ($Settings.Contains("config")) {
            return [string]$Settings["config"]
        }
        return $null
    }

    $member = $Settings | Get-Member -Name "config" -MemberType NoteProperty, Property -ErrorAction SilentlyContinue
    if ($null -ne $member) {
        return [string]$Settings.config
    }

    return $null
}

function Set-SettingsConfigText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Settings,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($null -eq $Settings) {
        throw "settings object is null."
    }

    if ($Settings -is [System.Array]) {
        if ($Settings.Count -eq 1) {
            Set-SettingsConfigText -Settings $Settings[0] -Value $Value
            return
        }
        throw "settings object is an unexpected array."
    }

    if ($Settings -is [System.Collections.IDictionary]) {
        $Settings["config"] = $Value
        return
    }

    $member = $Settings | Get-Member -Name "config" -MemberType NoteProperty, Property -ErrorAction SilentlyContinue
    if ($null -eq $member) {
        throw "settings object does not contain config."
    }

    $Settings.config = $Value
}

function Normalize-ConfigTextToProvider {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigText,
        [Parameter(Mandatory = $true)]
        [string]$ProviderId
    )

    $normalized = $ConfigText -replace "`r", ""
    $normalized = [regex]::Replace(
        $normalized,
        '(?m)^model_provider\s*=\s*".*?"\s*$',
        ('model_provider = "{0}"' -f $ProviderId)
    )
    $normalized = [regex]::Replace(
        $normalized,
        '(?m)^\[model_providers\.[^\]]+\]\s*$',
        ('[model_providers.{0}]' -f $ProviderId)
    )

    return $normalized
}

function Get-StateCounts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database
    )

    return Invoke-SqlRows -Database $Database -Sql "SELECT model_provider, COUNT(*) FROM threads GROUP BY model_provider ORDER BY COUNT(*) DESC;" -Columns @("model_provider", "count")
}

function Normalize-WorkspacePath {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )

    $normalized = $Path -replace '^[\\/]{2}\?\\', ''
    $normalized = $normalized.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $normalized
    }

    return $normalized.TrimEnd('\', '/')
}

function Get-WorkspaceSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Database
    )

    $rows = Invoke-SqlRows -Database $Database -Sql "SELECT cwd, archived FROM threads ORDER BY updated_at DESC;" -Columns @("cwd", "archived")
    $map = @{}

    foreach ($row in $rows) {
        $cwd = Normalize-WorkspacePath -Path ([string]$row.cwd)
        if ([string]::IsNullOrWhiteSpace($cwd)) {
            continue
        }

        if (-not $map.ContainsKey($cwd)) {
            $map[$cwd] = [ordered]@{
                cwd = $cwd
                active_threads = 0
                archived_threads = 0
            }
        }

        if ([string]$row.archived -eq "1") {
            $map[$cwd].archived_threads += 1
        } else {
            $map[$cwd].active_threads += 1
        }
    }

    return @(
        $map.Values |
            Sort-Object -Property @{ Expression = "active_threads"; Descending = $true }, @{ Expression = "archived_threads"; Descending = $true }, @{ Expression = "cwd"; Descending = $false }
    )
}

function Merge-UniqueOrdered {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Existing,
        [Parameter(Mandatory = $true)]
        [object[]]$Incoming
    )

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Existing) + @($Incoming)) {
        if ($null -eq $item) {
            continue
        }
        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }
        if (-not $list.Contains($text)) {
            $list.Add($text) | Out-Null
        }
    }

    return @($list)
}

function Sync-WorkspaceRoots {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StatePath,
        [Parameter(Mandatory = $true)]
        [object[]]$WorkspaceSummary
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    $stateText = Get-Content -LiteralPath $StatePath -Raw
    $state = $stateText | ConvertFrom-Json
    $roots = @($WorkspaceSummary | Where-Object { $_.active_threads -gt 0 } | ForEach-Object { $_.cwd })

    if ($roots.Count -eq 0) {
        return [ordered]@{
            added_saved_roots = @()
            added_active_roots = @()
            added_project_order = @()
        }
    }

    $savedBefore = @($state.'electron-saved-workspace-roots')
    $activeBefore = @($state.'active-workspace-roots')
    $projectOrderBefore = @($state.'project-order')

    $savedAfter = Merge-UniqueOrdered -Existing $savedBefore -Incoming $roots
    $activeAfter = Merge-UniqueOrdered -Existing $activeBefore -Incoming $roots
    $projectOrderAfter = Merge-UniqueOrdered -Existing $projectOrderBefore -Incoming $roots

    $state.'electron-saved-workspace-roots' = $savedAfter
    $state.'active-workspace-roots' = $activeAfter
    $state.'project-order' = $projectOrderAfter

    $json = $state | ConvertTo-Json -Depth 50 -Compress
    Set-Content -LiteralPath $StatePath -Value $json -NoNewline

    return [ordered]@{
        added_saved_roots = @($savedAfter | Where-Object { $savedBefore -notcontains $_ })
        added_active_roots = @($activeAfter | Where-Object { $activeBefore -notcontains $_ })
        added_project_order = @($projectOrderAfter | Where-Object { $projectOrderBefore -notcontains $_ })
    }
}

Assert-PathExists -Path $CodexConfigPath -Label "Codex config"
Assert-PathExists -Path $CodexStateDbPath -Label "Codex state database"
$script:Sqlite3Exe = Resolve-Sqlite3Path -PreferredPath $Sqlite3Path

$updatedCcSwitchProviders = New-Object System.Collections.Generic.List[string]
$targetProvider = $null

if ($Mode -eq "current") {
    $targetProvider = Get-CurrentProviderId -ConfigPath $CodexConfigPath
}

if ($Mode -eq "ccs") {
    Assert-PathExists -Path $CcSwitchDbPath -Label "CC Switch database"
    $targetProvider = "codex"

    $providerRows = Invoke-SqlRows -Database $CcSwitchDbPath -Sql "SELECT id, name, hex(settings_config) FROM providers WHERE app_type = 'codex';" -Columns @("id", "name", "settings_config_hex")
    foreach ($row in $providerRows) {
        $settingsConfig = Convert-HexToUtf8String -Hex $row.settings_config_hex
        try {
            $settings = $settingsConfig | ConvertFrom-Json
        } catch {
            throw "Failed to parse settings_config JSON for CC Switch provider '$($row.name)' (id=$($row.id))."
        }

        $configText = Get-SettingsConfigText -Settings $settings
        if ([string]::IsNullOrEmpty($configText)) {
            continue
        }

        $newConfig = Normalize-ConfigTextToProvider -ConfigText $configText -ProviderId $targetProvider
        if ($newConfig -eq $configText) {
            continue
        }

        Set-SettingsConfigText -Settings $settings -Value $newConfig
        $newSettingsJson = $settings | ConvertTo-Json -Compress -Depth 20
        $escapedSettings = Escape-SqlLiteral -Value $newSettingsJson
        $escapedId = Escape-SqlLiteral -Value ([string]$row.id)
        Invoke-SqlNonQuery -Database $CcSwitchDbPath -Sql "UPDATE providers SET settings_config = '$escapedSettings' WHERE id = '$escapedId';"
        $updatedCcSwitchProviders.Add([string]$row.name) | Out-Null
    }

    $liveConfig = Get-Content -LiteralPath $CodexConfigPath -Raw
    $normalizedLiveConfig = Normalize-ConfigTextToProvider -ConfigText $liveConfig -ProviderId $targetProvider
    if ($normalizedLiveConfig -ne $liveConfig) {
        Set-Content -LiteralPath $CodexConfigPath -Value $normalizedLiveConfig -NoNewline
    }
}

$beforeCounts = Get-StateCounts -Database $CodexStateDbPath
$rowsToMigrateCount = [int](Invoke-SqlScalar -Database $CodexStateDbPath -Sql "SELECT COUNT(*) FROM threads WHERE model_provider <> '$(Escape-SqlLiteral -Value $targetProvider)';")

if ($rowsToMigrateCount -gt 0) {
    Invoke-SqlNonQuery -Database $CodexStateDbPath -Sql "BEGIN IMMEDIATE; UPDATE threads SET model_provider = '$(Escape-SqlLiteral -Value $targetProvider)' WHERE model_provider <> '$(Escape-SqlLiteral -Value $targetProvider)'; COMMIT;"
}

$afterCounts = Get-StateCounts -Database $CodexStateDbPath
$workspaceSummary = Get-WorkspaceSummary -Database $CodexStateDbPath
$workspaceSync = $null

if ($WorkspaceAction -eq "sync") {
    $workspaceSync = Sync-WorkspaceRoots -StatePath $GlobalStatePath -WorkspaceSummary $workspaceSummary
}

[ordered]@{
    mode = $Mode
    target_provider = $targetProvider
    sqlite3_path = $script:Sqlite3Exe
    workspace_action = $WorkspaceAction
    updated_ccswitch_provider_count = $updatedCcSwitchProviders.Count
    updated_ccswitch_providers = @($updatedCcSwitchProviders)
    migrated_thread_rows = $rowsToMigrateCount
    before_state_counts = $beforeCounts
    after_state_counts = $afterCounts
    workspace_summary = if ($WorkspaceAction -eq "none") { @() } else { $workspaceSummary }
    workspace_sync = $workspaceSync
} | ConvertTo-Json -Depth 20
