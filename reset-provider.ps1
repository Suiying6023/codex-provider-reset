param(
    [ValidateSet("current", "ccs")]
    [string]$Mode = "current",
    [string]$CodexConfigPath = (Join-Path $HOME ".codex\config.toml"),
    [string]$CodexStateDbPath = (Join-Path $HOME ".codex\state_5.sqlite"),
    [string]$CcSwitchDbPath = (Join-Path $HOME ".cc-switch\cc-switch.db"),
    [string]$Sqlite3Path = ""
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

        if (-not $settings.PSObject.Properties.Name.Contains("config")) {
            continue
        }

        $newConfig = Normalize-ConfigTextToProvider -ConfigText ([string]$settings.config) -ProviderId $targetProvider
        if ($newConfig -eq $settings.config) {
            continue
        }

        $settings.config = $newConfig
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

[ordered]@{
    mode = $Mode
    target_provider = $targetProvider
    sqlite3_path = $script:Sqlite3Exe
    updated_ccswitch_provider_count = $updatedCcSwitchProviders.Count
    updated_ccswitch_providers = @($updatedCcSwitchProviders)
    migrated_thread_rows = $rowsToMigrateCount
    before_state_counts = $beforeCounts
    after_state_counts = $afterCounts
} | ConvertTo-Json -Depth 20
