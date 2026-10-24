# A local install that stops at the port check keeps no settings, so the PC can still get a server install.
# Load function definitions only; never execute the installer's entry point.
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
    $HotelRoot = Join-Path $testDir 'hotel'
    $StateDir = Join-Path $testDir 'state'
    $StateFile = Join-Path $StateDir 'hotel.json'
    $script:Log = Join-Path $StateDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 12
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $env:PLUSEMU_YES = '1'

    # Apache holds port 80.
    function Get-NetTCPConnection($State, $LocalPort) { if ([int]$LocalPort -eq 80) { return [pscustomobject]@{ LocalPort = 80; OwningProcess = 777 } } }
    function Get-Process($Id) { return [pscustomobject]@{ Id = 777; ProcessName = 'httpd'; Path = 'C:\Apache24\bin\httpd.exe' } }
    $script:Calls = [Collections.Generic.List[string]]::new()
    foreach ($name in 'Get-InstallerFiles', 'Get-Derived', 'Install-WebServer', 'Install-Toolchains', 'Install-Database', 'Get-Releases', 'Initialize-HotelDatabase',
                      'Get-HotelFiles', 'Start-Emulator', 'Write-ClientConfig', 'Install-Cms', 'Set-IisSite', 'Protect-Server', 'Write-Guide', 'Write-UpdateCommand',
                      'Connect-Cloudflare', 'Open-LocalGuide', 'Complete-Install') {
        . ([scriptblock]::Create("function $name { `$script:Calls.Add('$name') }"))
    }

    # The first run stops before anything is installed and leaves no saved choice behind.
    $env:PLUSEMU_LOCAL = '1'
    $stopped = $false
    try { Install-Hotel *> $null } catch { $stopped = $true; $reason = "$_" }
    Remove-Item Env:\PLUSEMU_LOCAL
    Assert $stopped 'The install went on with port 80 in use'
    Assert ($reason.Contains('httpd')) "The port message: $reason"
    Assert (-not (Test-Path $StateFile)) 'A stopped first run saved its settings'
    Assert ($Calls -notcontains 'Install-WebServer') 'The install started before the port check'

    # A server install still works on this PC afterwards.
    foreach ($name in 'PLUSEMU_DOMAIN=example.com', 'PLUSEMU_WS_URL=wss://example.com/ws', 'PLUSEMU_HOTEL_NAME=Example', 'PLUSEMU_ADMIN_USER=admin', 'PLUSEMU_ADMIN_EMAIL=admin@example.com') {
        $pair = $name -split '=', 2
        [Environment]::SetEnvironmentVariable($pair[0], $pair[1])
    }
    $Calls.Clear()
    Install-Hotel *> $null
    Assert ($Calls -contains 'Connect-Cloudflare') "Server steps: $($Calls -join ', ')"

    # A rerun of an installed local hotel keeps its settings when a port is taken.
    Remove-Item $StateFile
    $env:PLUSEMU_LOCAL = '1'
    Read-Answers *> $null
    Remove-Item Env:\PLUSEMU_LOCAL
    $before = Get-Content $StateFile -Raw
    $stopped = $false
    try { Install-Hotel *> $null } catch { $stopped = $true }
    Assert $stopped 'The rerun went on with port 80 in use'
    Assert ((Get-Content $StateFile -Raw) -ceq $before) 'A stopped rerun changed the saved settings'
    Write-Host 'PowerShell local first run checks passed'
} finally {
    foreach ($name in 'PLUSEMU_YES', 'PLUSEMU_LOCAL', 'PLUSEMU_DOMAIN', 'PLUSEMU_WS_URL', 'PLUSEMU_HOTEL_NAME', 'PLUSEMU_ADMIN_USER', 'PLUSEMU_ADMIN_EMAIL') {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Item $testDir -Recurse -Force
}
