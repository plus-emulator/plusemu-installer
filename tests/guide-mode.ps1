$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile("$root/install.ps1", [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($statement.Extent.Text))
    }
}
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$testDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $testDir | Out-Null
try {
    $StateFile = Join-Path $testDir 'hotel.json'
    $Log = Join-Path $testDir 'install.log'
    $env:PLUSEMU_DOMAIN = 'example.com'; $env:PLUSEMU_WS_URL = 'wss://example.com/ws'
    $env:PLUSEMU_HOTEL_NAME = 'Example'; $env:PLUSEMU_ADMIN_USER = 'Admin'
    $env:PLUSEMU_ADMIN_EMAIL = 'admin@example.com'; $env:PLUSEMU_YES = '1'
    $env:PLUSEMU_GUIDE_MODE = 'advanced'
    Read-Answers *> $null
    Assert ($state.GuideMode -eq 'advanced') 'Guide mode: explicit advanced choice was ignored'
    $initial = $state.AdminPassword
    Remove-Item Env:\PLUSEMU_GUIDE_MODE
    $script:state = $null
    Read-Answers *> $null
    Assert ($state.GuideMode -eq 'advanced' -and $state.AdminPassword -ceq $initial) 'Saved guide mode or credentials changed'
    $env:PLUSEMU_GUIDE_MODE = 'simple'
    Read-Answers *> $null
    Assert ($state.GuideMode -eq 'simple' -and $state.AdminPassword -ceq $initial) 'Explicit simple choice failed'
    Remove-Item Env:\PLUSEMU_GUIDE_MODE
    $script:state = $null
    Read-Answers *> $null
    Assert ($state.GuideMode -eq 'simple') 'Simple choice was not persisted'
    $state.PSObject.Properties.Remove('GuideMode')
    $state | ConvertTo-Json | Set-Content $StateFile
    Read-Answers *> $null
    Assert ($state.GuideMode -eq 'simple' -and $state.AdminPassword -ceq $initial) 'Legacy settings did not default to simple'
    $before = Get-Content $StateFile -Raw
    $env:PLUSEMU_GUIDE_MODE = 'typo'
    $rejected = $false
    try { Read-Answers *> $null } catch { $rejected = $true }
    Assert $rejected 'Guide mode: invalid choice was accepted'
    Assert ((Get-Content $StateFile -Raw) -ceq $before) 'Invalid choice changed saved settings'
    Write-Host 'PowerShell guide mode checks passed'
} finally {
    foreach ($name in 'PLUSEMU_DOMAIN', 'PLUSEMU_WS_URL', 'PLUSEMU_HOTEL_NAME', 'PLUSEMU_ADMIN_USER', 'PLUSEMU_ADMIN_EMAIL', 'PLUSEMU_YES', 'PLUSEMU_GUIDE_MODE') {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Item $testDir -Recurse -Force
}
