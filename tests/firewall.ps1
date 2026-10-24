# Exercise the Cloudflare-only website firewall against fake downloads and firewall rules.
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
    $StateDir = $testDir
    $CloudflareScript = Join-Path $testDir 'plusemu-cloudflare-ips.ps1'
    $CloudflareLog = Join-Path $testDir 'cloudflare-ips.log'
    $script:Log = Join-Path $testDir 'install.log'
    $script:Step = 0; $TotalSteps = 11

    # The firewall and the downloads are replaced; everything else is the real installer code.
    $mocks = @'
$script:Lists = @{ 4 = "173.245.48.0/20`n103.21.244.0/22`n104.16.0.0/13"; 6 = "2400:cb00::/32`n2606:4700::/32" }
$script:Rules = @{ 'PlusEMU-80' = @('Any'); 'PlusEMU-443' = @('Any') }
function Invoke-WebRequest($Uri) {
    $version = [int]"$Uri".Substring("$Uri".Length - 1)
    if ($null -eq $script:Lists[$version]) { throw 'The remote name could not be resolved' }
    return [pscustomobject]@{ Content = $script:Lists[$version] }
}
function Set-NetFirewallRule([string]$Name, [string[]]$RemoteAddress) {
    if (-not $script:Rules.ContainsKey($Name)) { throw "No firewall rule $Name" }
    $script:Rules[$Name] = $RemoteAddress
    if ($env:FIREWALL_CALLS) { Add-Content $env:FIREWALL_CALLS "$Name $($RemoteAddress -join ',')" }
}
function Disable-NetFirewallRule([string[]]$Name) {
    $script:Disabled = $Name
    if ($env:FIREWALL_CALLS) { Add-Content $env:FIREWALL_CALLS "disable $($Name -join ',')" }
}
'@
    . ([scriptblock]::Create($mocks))
    function New-ScheduledTaskAction { return "action $args" }
    function New-ScheduledTaskTrigger { return "trigger $args" }
    function Register-ScheduledTask { $script:Registered = $args -join ' ' }

    $expected = '173.245.48.0/20,103.21.244.0/22,104.16.0.0/13,2400:cb00::/32,2606:4700::/32'

    # Both website ports take only Cloudflare's ranges.
    Update-CloudflareFirewall
    Assert (($Rules['PlusEMU-443'] -join ',') -eq $expected) "HTTPS allows $($Rules['PlusEMU-443'] -join ',')"
    Assert (($Rules['PlusEMU-80'] -join ',') -eq $expected) "HTTP allows $($Rules['PlusEMU-80'] -join ',')"
    Assert (($Disabled -join ',') -eq 'IIS-WebServerRole-HTTP-In-TCP,IIS-WebServerRole-HTTPS-In-TCP') "IIS's own rules still let every address in: $Disabled"

    # A failed download or a page that is not an address list changes nothing.
    foreach ($broken in @($null, '', '<html>Attention Required</html>', '2400:cb00::/32', '12/8', '173.245.48.0/33', '173.245.48.0')) {
        $Lists[4] = $broken
        $Rules['PlusEMU-443'] = @('198.51.100.0/24')
        $failed = $false
        try { Update-CloudflareFirewall } catch { $failed = $true }
        Assert $failed "Accepted a broken list: $broken"
        Assert (($Rules['PlusEMU-443'] -join ',') -eq '198.51.100.0/24') "A broken list changed the firewall: $broken"
    }
    $Lists[4] = "173.245.48.0/20`n103.21.244.0/22`n104.16.0.0/13"
    $Lists[6] = "2400:cb00::/32`n173.245.48.0/20"
    $failed = $false
    try { Update-CloudflareFirewall } catch { $failed = $true }
    Assert $failed 'Accepted an IPv4 range in the IPv6 list'

    # The installed command carries its own copy of the functions it needs and runs on its own.
    Write-CloudflareCommand
    $command = Get-Content $CloudflareScript -Raw
    $null = [scriptblock]::Create($command)
    foreach ($name in 'Write-Log', 'Get-CloudflareRanges', 'Update-CloudflareFirewall') {
        Assert ($command -match "(?m)^function $name \{") "The Cloudflare command misses $name"
    }
    Assert ($command.Contains('Tls12')) 'The Cloudflare command does not use TLS 1.2'
    Assert ($script:Registered -like '*PlusEMU Cloudflare addresses*') 'The Cloudflare task was not registered'
    Assert ($script:Registered -like '*-Weekly -DaysOfWeek Sunday -At 03:00*') "The Cloudflare task does not run on Sunday at 03:00: $script:Registered"
    Assert ($script:Registered -like '*SYSTEM*') 'The Cloudflare task does not run as SYSTEM'

    # The task runs the installed command in a new PowerShell.
    $runner = Join-Path $testDir 'run.ps1'
    $env:FIREWALL_CALLS = Join-Path $testDir 'firewall-calls'
    $pwsh = (Get-Process -Id $PID).Path
    function Invoke-CloudflareCommand([string]$Setup) {
        # exit in a dot-sourced script only leaves that script, so the runner passes its exit code on.
        Set-Content $runner "$mocks`n$Setup`n`$global:LASTEXITCODE = 0`n. '$CloudflareScript'`nexit `$LASTEXITCODE"
        Set-Content $env:FIREWALL_CALLS ''
        & $pwsh -NoProfile -File $runner | Out-Null
        return $LASTEXITCODE
    }
    $code = Invoke-CloudflareCommand ''
    Assert ($code -eq 0) "The Cloudflare command failed with exit code $code"
    $calls = @(Get-Content $env:FIREWALL_CALLS | Where-Object { $_ })
    Assert (($calls -join ';') -eq "PlusEMU-80 $expected;PlusEMU-443 $expected;disable IIS-WebServerRole-HTTP-In-TCP,IIS-WebServerRole-HTTPS-In-TCP") "The Cloudflare command set: $($calls -join ';')"
    Assert ((Get-Content $CloudflareLog -Raw) -match 'only Cloudflare') 'The Cloudflare command did not log the update'

    $code = Invoke-CloudflareCommand '$script:Lists[6] = $null'
    Assert ($code -eq 1) "A failed download ended with exit code $code"
    Assert (-not (Get-Content $env:FIREWALL_CALLS | Where-Object { $_ })) 'A failed download reached the firewall'
    Assert ((Get-Content $CloudflareLog -Raw) -match 'left as it is') 'A failed download was not logged'
    Write-Host 'PowerShell firewall checks passed'
} finally {
    Remove-Item Env:FIREWALL_CALLS -ErrorAction SilentlyContinue
    Remove-Item $testDir -Recurse -Force
}
