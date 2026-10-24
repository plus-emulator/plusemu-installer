# Install on this PC only (-Local) against fake Windows, IIS and network commands: every address is localhost and the PC's own settings stay.
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
$presets = 'PLUSEMU_LOCAL', 'PLUSEMU_YES', 'PLUSEMU_DOMAIN', 'PLUSEMU_WS_URL', 'PLUSEMU_HOTEL_NAME', 'PLUSEMU_ADMIN_USER', 'PLUSEMU_ADMIN_EMAIL'
try {
    $HotelRoot = Join-Path $testDir 'hotel'
    $StateDir = Join-Path $testDir 'state'
    $StateFile = Join-Path $StateDir 'hotel.json'
    $BackupRoot = Join-Path $StateDir 'backups'
    $NightlyRoot = Join-Path $BackupRoot 'nightly'
    $BackupScript = Join-Path $StateDir 'plusemu-backup.ps1'
    $BackupLog = Join-Path $StateDir 'backup.log'
    $CleanupScript = Join-Path $StateDir 'plusemu-cleanup.ps1'
    $CloudflareScript = Join-Path $StateDir 'plusemu-cloudflare-ips.ps1'
    $CloudflareLog = Join-Path $StateDir 'cloudflare-ips.log'
    $HealthScript = Join-Path $StateDir 'plusemu-health.ps1'
    $HealthLog = Join-Path $StateDir 'health.log'
    $HealthState = Join-Path $StateDir 'health.json'
    $LockFile = Join-Path $StateDir 'update.lock'
    $KeepNightly = 7; $BackupLockWait = 3600
    $Templates = Join-Path $root 'templates'
    $PhpDir = Join-Path $testDir 'php'
    $Downloads = Join-Path $testDir 'downloads'
    $script:Log = Join-Path $StateDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 12
    New-Item -ItemType Directory -Force -Path $StateDir, $HotelRoot, $Downloads | Out-Null

    # Windows, IIS and the network are replaced; every command that could change this PC is recorded.
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:Config = [Collections.Generic.List[string]]::new()
    $script:Bindings = [Collections.Generic.List[object]]::new()
    $script:Prompts = [Collections.Generic.List[string]]::new()
    function Reset-Calls { $script:Calls.Clear(); $script:Config.Clear(); $script:Bindings.Clear() }
    # Enter on every question; a question asked again and again would never end, so it stops the test.
    function Read-Host($Prompt) {
        $script:Prompts.Add("$Prompt")
        if ($script:Prompts.Count -gt 20) { throw "The installer keeps asking: $Prompt" }
        return ''
    }
    function Format-Value($Value) { if ($Value -is [hashtable]) { return (($Value.Keys | Sort-Object | ForEach-Object { "$_=$($Value[$_])" }) -join ';') } return "$Value" }
    function Set-WebConfigurationProperty($PSPath, $Filter, $Name, $Value, $Location) { $script:Config.Add("$Filter|$Name|$(Format-Value $Value)") }
    function Add-WebConfigurationProperty($PSPath, $Filter, $Name, $Value, $Location, $AtIndex) { $script:Config.Add("$Filter|$Name|$(Format-Value $Value)") }
    function Add-WebConfiguration($PSPath, $Filter, $Value) { $script:Config.Add("$Filter||$(Format-Value $Value)") }
    function Get-WebConfiguration { return $null }
    function Clear-WebConfiguration { }
    function Remove-WebConfigurationProperty { }
    function Import-Module { }
    $script:Sites = @{}
    function Get-Website($Name) { if ($script:Sites.ContainsKey("$Name")) { return [pscustomobject]@{ Name = $Name; id = $script:Sites["$Name"] } } }
    function Remove-Website($Name) { $script:Calls.Add("Remove-Website $Name") }
    function New-WebAppPool { }
    function Set-ItemProperty { }
    function New-Website($Name, $PhysicalPath, $ApplicationPool, $HostHeader, $Port, $IPAddress) {
        $address = if ($IPAddress) { $IPAddress } else { '*' }
        $script:Bindings.Add([pscustomobject]@{ protocol = 'http'; bindingInformation = "$($address):$($Port):$HostHeader" })
    }
    function Get-WebBinding($Name, $Protocol, $HostHeader, $Port) {
        $found = @($script:Bindings | Where-Object { (-not $Protocol -or $_.protocol -eq $Protocol) -and (-not $HostHeader -or $_.bindingInformation -like "*:$($Port):$HostHeader") })
        foreach ($binding in $found) { $binding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value { } -Force }
        return $found
    }
    function New-WebBinding($Name, $Protocol, $Port, $HostHeader, $SslFlags, $IPAddress) {
        $address = if ($IPAddress) { $IPAddress } else { '*' }
        $script:Bindings.Add([pscustomobject]@{ protocol = $Protocol; bindingInformation = "$($address):$($Port):$HostHeader" })
    }
    function New-ItemProperty($Path, $Name, $Value) {
        if ("$Path" -like 'IIS:*') { $script:Bindings.Add([pscustomobject]@{ protocol = $Value.protocol; bindingInformation = $Value.bindingInformation }) }
        else { $script:Calls.Add("New-ItemProperty $Path $Name") }
    }
    function Get-ChildItem { return $null }
    function New-SelfSignedCertificate { $script:Calls.Add('New-SelfSignedCertificate'); return [pscustomobject]@{ Thumbprint = 'ABC' } }
    function Get-WebVirtualDirectory { return $null }
    function New-WebVirtualDirectory { }
    function Run { $script:Calls.Add("$args") }
    function Set-HotelPermissions { }
    function cmd.exe { $script:Calls.Add("cmd.exe $args") }
    function Start-Website { }
    function Get-WebAppPoolState { return [pscustomobject]@{ Value = 'Started' } }
    function Restart-WebAppPool { }
    function Get-NetFirewallRule { return $null }
    function New-NetFirewallRule($Name) { $script:Calls.Add("New-NetFirewallRule $Name") }
    function Set-NetFirewallRule { $script:Calls.Add('Set-NetFirewallRule') }
    function Disable-NetFirewallRule { $script:Calls.Add('Disable-NetFirewallRule') }
    function Get-CimInstance($ClassName) { return [pscustomobject]@{ ProductType = $script:ProductType; DomainRole = 0 } }
    function Install-WindowsFeature($Name) { $script:Calls.Add("Install-WindowsFeature $($Name -join ',')"); return [pscustomobject]@{ Success = $true } }
    function Enable-WindowsOptionalFeature([switch]$Online, [string[]]$FeatureName, [switch]$All, [switch]$NoRestart) {
        $script:Calls.Add("Enable-WindowsOptionalFeature $($FeatureName -join ',')")
        return [pscustomobject]@{ RestartNeeded = $false }
    }
    function Download($Url) { $script:Calls.Add("Download $Url") }
    function Install-Msi { }
    function Invoke-WebRequest($Uri) {
        $script:Calls.Add("Invoke-WebRequest $Uri")
        if ("$Uri" -eq 'http://127.0.0.1:8080/api/gamedata/furnidata') { return [pscustomobject]@{ Content = '{}' } }
        throw 'The remote name could not be resolved'
    }
    function Invoke-RestMethod($Uri) { $script:Calls.Add("Invoke-RestMethod $Uri"); throw 'The remote name could not be resolved' }
    function Get-ScheduledTask { return 'task' }
    function New-ScheduledTaskAction { return "action $args" }
    function New-ScheduledTaskTrigger { return "trigger $args" }
    function Register-ScheduledTask { $script:Calls.Add("Register-ScheduledTask $args") }
    function Start-Process($FilePath) { $script:Calls.Add("open $FilePath") }
    function Copy-Item { }
    function Set-WindowsUpdates { $script:Calls.Add('Set-WindowsUpdates') }

    function Expect-Config($Line) { Assert ($script:Config -contains $Line) "Expected IIS setting: $Line`n$($script:Config -join "`n")" }
    function Expect-NoConfig($Pattern) { $found = @($script:Config | Where-Object { $_ -match $Pattern }); Assert (-not $found) "Unexpected IIS setting: $($found -join "`n")" }
    function Expect-NoCall($Pattern) { $found = @($script:Calls | Where-Object { $_ -match $Pattern }); Assert (-not $found) "Unexpected call: $($found -join "`n")" }
    function Read-State { return Get-Content $StateFile -Raw | ConvertFrom-Json }
    function Invoke-Answers([hashtable]$Environment = @{}) {
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
        $script:Prompts.Clear()
        try { $script:Output = Read-Answers 6>&1 | Out-String }
        finally { foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $null) } }
    }
    function Assert-Refused([hashtable]$Environment = @{}) {
        $before = Get-Content $StateFile -Raw
        $refused = $false
        try { Invoke-Answers $Environment } catch { $refused = $true; $script:Refusal = "$_" }
        Assert $refused "Switching was accepted with $($Environment.Keys -join ',')"
        Assert ((Get-Content $StateFile -Raw) -ceq $before) 'A refused switch changed the saved settings'
    }
    function Assert-OnlyLocalhost($Files) {
        foreach ($file in $Files) {
            $text = Get-Content $file -Raw
            Assert (-not $text.Contains('https://')) "https:// in $file"
            foreach ($match in [regex]::Matches($text, '[a-z]+://[^"'' ]*')) {
                Assert ($match.Value -match '^(http://localhost($|[/:])|ws://localhost/)') "Not a local address in $($file): $($match.Value)"
            }
        }
    }

    # ---------------------------------------------------------------- the questions

    # Enter takes every suggested answer: no domain, no WebSocket address and no Discord question.
    Invoke-Answers @{ PLUSEMU_LOCAL = '1' }
    $saved = Read-State
    Assert ($saved.Local -eq $true) 'The local choice was not saved'
    Assert ($saved.Domain -eq 'localhost' -and $saved.WsUrl -eq 'ws://localhost/ws') "Local addresses: $($saved.Domain) $($saved.WsUrl)"
    Assert ($saved.HotelName -and $saved.AdminUser -eq 'admin' -and $saved.AdminEmail -match '^admin@[a-z.]+\.[a-z]+$') "Local defaults: $($saved.HotelName) $($saved.AdminUser) $($saved.AdminEmail)"
    Assert (-not $saved.DiscordWebhook) 'A local install saved a Discord webhook'
    Assert (-not ($Prompts | Where-Object { $_ -match 'domain|WebSocket|Discord' })) "Asked: $($Prompts -join '; ')"
    Assert ($Output.Contains('http://localhost')) "Summary: $Output"
    $initial = $saved.AdminPassword

    # A rerun, and the update, keep the local install without being told again.
    Invoke-Answers
    $saved = Read-State
    Assert ($saved.Local -eq $true -and $saved.AdminPassword -ceq $initial) 'A rerun lost the local choice or the passwords'
    $Local = $true
    Invoke-Answers
    Assert ((Read-State).Local -eq $true) 'The -Local switch on a rerun changed the local choice'
    $Local = $false

    # Switching an installed hotel is refused, and nothing changes.
    Assert-Refused @{ PLUSEMU_LOCAL = '0' }
    Assert ($Refusal.Contains('localhost') -and $Refusal.Contains('Nothing was changed')) "Refusal: $Refusal"
    Assert-Refused @{ PLUSEMU_LOCAL = 'maybe' }

    # A server install is never turned into a local one, also one made before local installs existed.
    Remove-Item $StateFile
    Invoke-Answers @{ PLUSEMU_DOMAIN = 'example.com'; PLUSEMU_WS_URL = 'wss://example.com/ws'; PLUSEMU_HOTEL_NAME = 'Example'; PLUSEMU_ADMIN_USER = 'admin'; PLUSEMU_ADMIN_EMAIL = 'admin@example.com'; PLUSEMU_YES = '1' }
    Assert (-not (Read-State).Local) 'A server install was saved as local'
    $server = Read-State
    $server.PSObject.Properties.Remove('Local')
    $server | ConvertTo-Json | Set-Content $StateFile
    Assert-Refused @{ PLUSEMU_LOCAL = '1' }
    Assert ($Refusal.Contains('example.com') -and $Refusal.Contains('Nothing was changed')) "Refusal: $Refusal"
    $Local = $true
    Assert-Refused
    $Local = $false
    Remove-Item $StateFile
    Invoke-Answers @{ PLUSEMU_LOCAL = '1' }
    $script:state = Read-State

    # ---------------------------------------------------------------- ports already in use

    $script:Listeners = @{}
    function Get-NetTCPConnection($State, $LocalPort) {
        if ($script:Listeners.ContainsKey([int]$LocalPort)) { return [pscustomobject]@{ LocalPort = $LocalPort; OwningProcess = $script:Listeners[[int]$LocalPort].Id } }
    }
    function Get-Process($Id) { return $script:Listeners.Values | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
    function Set-Listeners([hashtable]$Listeners) { $script:Listeners = $Listeners }
    function Assert-PortsRefused($Expected) {
        $refused = $false
        try { Assert-FreePorts } catch { $refused = $true; $reason = "$_" }
        Assert $refused "Busy ports were accepted: $($Listeners.Keys -join ',')"
        foreach ($text in $Expected) { Assert $reason.Contains($text) "The port message does not name $($text): $reason" }
    }
    function Find-MariaDb { return 'C:\Program Files\MariaDB 11.4\bin\mariadb.exe' }
    $mariadb = 'C:\Program Files\MariaDB 11.4\bin\mariadbd.exe'
    Set-Listeners @{}
    Assert-FreePorts
    # The installer's own programs may hold their ports, so a rerun works. IIS listens through Windows itself (process 4).
    $emulator = [pscustomobject]@{ Id = 4242; ProcessName = 'Plus Emulator'; Path = (Join-Path (Join-Path $HotelRoot 'emulator') 'Plus Emulator.exe') }
    Set-Listeners @{ 80 = [pscustomobject]@{ Id = 4; ProcessName = 'System'; Path = $null }; 3306 = [pscustomobject]@{ Id = 300; ProcessName = 'mariadbd'; Path = $mariadb }
                     2096 = $emulator; 8080 = $emulator; 30001 = $emulator }
    Assert-FreePorts
    # Another program on a port stops the install and is named with its port and process.
    Set-Listeners @{ 80 = [pscustomobject]@{ Id = 777; ProcessName = 'httpd'; Path = 'C:\Apache24\bin\httpd.exe' } }
    Assert-PortsRefused @('port 80', 'httpd', '777')
    Set-Listeners @{ 3306 = [pscustomobject]@{ Id = 310; ProcessName = 'mysqld'; Path = 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqld.exe' }
                     8080 = [pscustomobject]@{ Id = 901; ProcessName = 'java'; Path = 'C:\java\bin\java.exe' } }
    Assert-PortsRefused @('port 3306', 'mysqld', 'port 8080', 'java')
    Set-Listeners @{}

    # ---------------------------------------------------------------- what gets installed

    Reset-Calls
    Get-Derived
    Assert ($WsHost -eq 'localhost' -and $WsPath -eq 'ws') "Game address: $WsHost / $WsPath"
    Expect-NoCall 'ipify'

    # A Windows 10 or 11 PC gets IIS from its optional features; Windows Server from its roles.
    Reset-Calls
    $script:ProductType = 1
    Install-WebServer *> $null
    $enabled = @($Calls | Where-Object { $_ -like 'Enable-WindowsOptionalFeature *' })
    Assert ($enabled.Count -eq 1) "Optional features: $($Calls -join '; ')"
    foreach ($feature in 'IIS-WebServerRole', 'IIS-WebServer', 'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors', 'IIS-HttpLogging', 'IIS-HttpCompressionStatic',
                         'IIS-HttpCompressionDynamic', 'IIS-RequestFiltering', 'IIS-CGI', 'IIS-WebSockets', 'IIS-ManagementConsole') {
        Assert ($enabled[0] -match "[ ,]$feature(,|$)") "Missing feature $($feature): $($enabled[0])"
    }
    Assert ($enabled[0] -notmatch 'IIS-IPSecurity') 'A local install turned on the per-visitor IP limits'
    Expect-NoCall '^Install-WindowsFeature'
    Expect-Config 'system.webServer/proxy|enabled|True'
    Reset-Calls
    $script:ProductType = 3
    Install-WebServer *> $null
    Assert ($Calls | Where-Object { $_ -like 'Install-WindowsFeature *Web-WebSockets*' }) "Server roles: $($Calls -join '; ')"
    Expect-NoCall '^Enable-WindowsOptionalFeature'
    $script:ProductType = 1

    # The client, the website and the game connection use http://localhost and ws://localhost only.
    $clientConfig = Join-Path $testDir 'client-configuration'
    Write-ClientConfig $clientConfig
    Assert-OnlyLocalhost @((Join-Path $clientConfig 'renderer-config.json'), (Join-Path $clientConfig 'ui-config.json'), (Join-Path $clientConfig 'client-mode.json'))
    $renderer = Get-Content (Join-Path $clientConfig 'renderer-config.json') -Raw | ConvertFrom-Json
    Assert ($renderer.'socket.url' -eq 'ws://localhost/ws' -and $renderer.'furnidata.url' -eq 'http://localhost/api/gamedata/furnidata') "Renderer: $($renderer.'socket.url') $($renderer.'furnidata.url')"

    $cms = Join-Path $HotelRoot 'cms'
    New-Item -ItemType Directory -Force -Path $cms | Out-Null
    Set-Content (Join-Path $cms '.env') 'APP_URL=http://example.test'
    $script:Queries = [Collections.Generic.List[string]]::new()
    function Sql([string]$Query, [string]$Database = '') { $script:Queries.Add($Query); return '1' }
    Reset-Calls
    Install-Cms *> $null
    $envText = Get-Content (Join-Path $cms '.env') -Raw
    foreach ($line in 'APP_URL="http://localhost"', 'NITRO_CLIENT_PATH="http://localhost/client"', 'FORCE_HTTPS="false"', 'SESSION_SECURE_COOKIE="false"', 'TRUSTED_PROXIES="127.0.0.1"') {
        Assert ($envText.Contains($line)) "Missing in .env: $line`n$envText"
    }
    Expect-NoCall 'cloudflare'
    Set-Content (Join-Path $testDir 'queries.sql') ($Queries -join "`n")
    Assert (($Queries -join "`n").Contains("'http://localhost/client'")) "Website settings: $($Queries -join '; ')"
    Assert-OnlyLocalhost @((Join-Path $cms '.env'), (Join-Path $testDir 'queries.sql'))

    # IIS answers only on this PC, without HTTPS, HSTS, Cloudflare, per-visitor limits or firewall rules.
    Reset-Calls
    $WsHost = 'localhost'; $WsPath = 'ws'
    # A PC may already serve its own sites with IIS; they stay.
    $script:Sites = @{ 'Default Web Site' = 1 }
    Set-IisSite *> $null
    $bindings = @($Bindings | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" })
    Assert ($bindings.Count -eq 2 -and $bindings -contains 'http 127.0.0.1:80:localhost' -and $bindings -contains 'http [::1]:80:localhost') "Bindings: $($bindings -join ';')"
    Expect-NoCall '^(New-SelfSignedCertificate|New-NetFirewallRule|Set-NetFirewallRule|Disable-NetFirewallRule|Write-CloudflareCommand|Update-CloudflareFirewall|Remove-Website)'
    Expect-NoCall 'netsh'
    $websocket = "system.webServer/rewrite/globalRules/rule[@name='PlusEMU websocket']"
    Expect-Config "$websocket/conditions|.|input={HTTP_HOST};pattern=^localhost$"
    Expect-Config "$websocket/conditions|.|input={HTTP_ORIGIN};pattern=^http://localhost$"
    Expect-Config "$websocket/serverVariables|.|name=HTTP_X_REAL_IP;value={REMOTE_ADDR}"
    Expect-Config 'system.webServer/rewrite/allowedServerVariables|.|name=HTTP_X_REAL_IP'
    Expect-NoConfig "PlusEMU www|dynamicIpSecurity|Strict-Transport-Security|https://"

    # Only the hotel's own logs, backups and health check: the lockout policy and Windows Update stay as they are.
    Reset-Calls
    $script:Sites = @{ 'Default Web Site' = 1; 'Hotel' = 3 }
    Protect-Server *> $null
    Expect-NoCall '^(net\.exe|Set-WindowsUpdates)'
    Expect-NoCall '^New-ItemProperty HKLM'
    $cleanup = Get-Content $CleanupScript -Raw
    Assert ($cleanup.Contains('W3SVC3')) "The log cleanup does not stay in the hotel's IIS logs: $cleanup"
    Assert (-not $cleanup.Contains('LogFiles\*\')) "The log cleanup removes the logs of every IIS site: $cleanup"
    Assert ($Calls | Where-Object { $_ -like '*PlusEMU nightly backup*' }) 'The nightly backup was not registered'
    Assert ($Calls | Where-Object { $_ -like '*PlusEMU health check*' }) 'The health check was not registered'
    $checks = @(Get-HealthChecks | ForEach-Object { $_.Name })
    Assert ($checks -contains 'Website' -and $checks -contains 'Backup') "Health checks: $($checks -join ',')"
    Assert ($checks -notcontains 'Certificate' -and $checks -notcontains 'Cloudflare') "Local health checks: $($checks -join ',')"
    $health = Get-Content $HealthScript -Raw
    Assert (-not $health.Contains('function Test-HealthCertificate') -and -not $health.Contains('function Test-HealthCloudflare')) 'The health command carries the server checks'
    $script:state | Add-Member -NotePropertyName Domain -NotePropertyValue 'localhost' -Force
    function Get-ProbeResult { return @{ Code = 0; Output = '000' } }
    Assert ((Test-HealthWebsite) -like 'http://localhost *') "Website problem: $(Test-HealthWebsite)"

    # ---------------------------------------------------------------- the guide and the summary

    Reset-Calls
    Write-GuideFile
    $guide = Get-Content (Join-Path (Join-Path $HotelRoot 'setup-guide') 'index.html') -Raw
    Assert (-not $guide.Contains('{{')) 'The local guide has an empty placeholder'
    foreach ($text in 'http://localhost/housekeeping', $state.AdminUser, 'Restart-Service PlusEMU', 'Stop-Service PlusEMU', 'plusemu-update', $NightlyRoot, '-Local', $StateFile) {
        Assert ($guide.Contains($text)) "The local guide does not mention $text"
    }
    foreach ($secret in $state.AdminPassword, $state.DbPassword, $state.DbRootPassword) { Assert (-not $guide.Contains($secret)) 'The local guide shows a password' }

    Reset-Calls
    $summary = Complete-Install 6>&1 | Out-String
    Assert ($summary.Contains('http://localhost')) "Summary: $summary"
    Assert ($summary -notmatch 'Cloudflare') "The local summary talks about Cloudflare: $summary"

    # ---------------------------------------------------------------- the whole run

    $steps = 'Get-InstallerFiles', 'Get-Derived', 'Install-WebServer', 'Install-Toolchains', 'Install-Database', 'Get-Releases', 'Initialize-HotelDatabase', 'Get-HotelFiles',
             'Start-Emulator', 'Write-ClientConfig', 'Install-Cms', 'Set-IisSite', 'Protect-Server', 'Write-Guide', 'Write-UpdateCommand', 'Connect-Cloudflare', 'Assert-FreePorts'
    foreach ($name in $steps) { . ([scriptblock]::Create("function $name { `$script:Calls.Add('$name') }")) }
    function Complete-Install { $script:Calls.Add("Complete-Install $script:TotalSteps") }
    Remove-Item $StateFile
    Reset-Calls
    $env:PLUSEMU_LOCAL = '1'
    Install-Hotel *> $null
    Remove-Item Env:\PLUSEMU_LOCAL
    Assert ($Calls -contains 'Assert-FreePorts' -and $Calls -contains 'Set-IisSite') "Local steps: $($Calls -join ', ')"
    Assert ($Calls -notcontains 'Connect-Cloudflare') 'A local install ran the Cloudflare step'
    Assert ($Calls -contains 'Complete-Install 11') "Local steps: $($Calls -join ', ')"
    Assert ($Calls.IndexOf('Assert-FreePorts') -lt $Calls.IndexOf('Install-WebServer')) 'The port check came after the installation started'
    Assert ($Calls | Where-Object { $_ -like 'open *index.html' }) 'The local guide was not opened in the browser'

    Remove-Item $StateFile
    Reset-Calls
    $script:TotalSteps = 12
    Invoke-Answers @{ PLUSEMU_DOMAIN = 'example.com'; PLUSEMU_WS_URL = 'wss://example.com/ws'; PLUSEMU_HOTEL_NAME = 'Example'; PLUSEMU_ADMIN_USER = 'admin'; PLUSEMU_ADMIN_EMAIL = 'admin@example.com'; PLUSEMU_YES = '1' }
    $env:PLUSEMU_YES = '1'
    Install-Hotel *> $null
    Remove-Item Env:\PLUSEMU_YES
    Assert ($Calls -contains 'Connect-Cloudflare' -and $Calls -notcontains 'Assert-FreePorts') "Server steps: $($Calls -join ', ')"
    Assert ($Calls -contains 'Complete-Install 12') "Server steps: $($Calls -join ', ')"
    Write-Host 'PowerShell local install checks passed'
} finally {
    foreach ($name in $presets) { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    # A failed website step stays in its folder, which would hide its error behind this one.
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item $testDir -Recurse -Force
}
