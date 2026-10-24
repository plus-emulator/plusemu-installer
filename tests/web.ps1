# Set up IIS against fake IIS, certificate and firewall commands, and check what the hotel site gets.
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
    $PhpDir = Join-Path $testDir 'php'
    $Downloads = Join-Path $testDir 'downloads'
    $script:Log = Join-Path $testDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 12

    # IIS keeps what the installer writes as "filter|name|value" lines; the other commands are recorded.
    function Reset-Iis {
        $script:Config = [Collections.Generic.List[string]]::new()
        $script:Calls = [Collections.Generic.List[string]]::new()
        $script:Bindings = [Collections.Generic.List[object]]::new()
    }
    function Format-Value($Value) { if ($Value -is [hashtable]) { return (($Value.Keys | Sort-Object | ForEach-Object { "$_=$($Value[$_])" }) -join ';') } return "$Value" }
    function Set-WebConfigurationProperty($PSPath, $Filter, $Name, $Value, $Location) { $script:Config.Add("$Filter|$Name|$(Format-Value $Value)") }
    function Add-WebConfigurationProperty($PSPath, $Filter, $Name, $Value, $Location, $AtIndex) { $script:Config.Add("$Filter|$Name|$(Format-Value $Value)") }
    function Add-WebConfiguration($PSPath, $Filter, $Value) { $script:Config.Add("$Filter||$(Format-Value $Value)") }
    function Get-WebConfiguration { return $null }
    function Clear-WebConfiguration { }
    function Remove-WebConfigurationProperty { }
    function Import-Module { }
    function Get-Website($Name) { return $null }
    function Remove-Website($Name) { $script:Calls.Add("Remove-Website $Name") }
    function New-WebAppPool { }
    function Set-ItemProperty { }
    function New-Website($Name, $PhysicalPath, $ApplicationPool, $HostHeader, $Port, $IPAddress) {
        $script:Calls.Add("New-Website $Name")
        $address = if ($IPAddress) { $IPAddress } else { '*' }
        $script:Bindings.Add([pscustomobject]@{ protocol = 'http'; bindingInformation = "$($address):$($Port):$HostHeader" })
    }
    function Get-WebBinding($Name, $Protocol, $HostHeader, $Port) {
        $found = @($script:Bindings | Where-Object { (-not $Protocol -or $_.protocol -eq $Protocol) -and (-not $HostHeader -or $_.bindingInformation -like "*:$($Port):$HostHeader") })
        foreach ($binding in $found) { $binding | Add-Member -MemberType ScriptMethod -Name AddSslCertificate -Value { } -Force }
        return $found
    }
    function New-WebBinding($Name, $Protocol, $Port, $HostHeader, $SslFlags) { $script:Bindings.Add([pscustomobject]@{ protocol = $Protocol; bindingInformation = "*:$($Port):$HostHeader" }) }
    function New-ItemProperty($Path, $Name, $Value) { $script:Bindings.Add([pscustomobject]@{ protocol = $Value.protocol; bindingInformation = $Value.bindingInformation }) }
    function Get-ChildItem { return $null }
    function New-SelfSignedCertificate { $script:Calls.Add('New-SelfSignedCertificate'); return [pscustomobject]@{ Thumbprint = 'ABC' } }
    function Get-WebVirtualDirectory { return $null }
    function New-WebVirtualDirectory { }
    function Write-Utf8($Path, $Text) { }
    function Run { $script:Calls.Add("$args") }
    function Set-HotelPermissions { }
    function cmd.exe { $script:Calls.Add("cmd.exe $args") }
    function Start-Website { }
    function Get-WebAppPoolState { return [pscustomobject]@{ Value = 'Started' } }
    function Restart-WebAppPool { }
    function Get-NetFirewallRule { return $null }
    function New-NetFirewallRule($Name) { $script:Calls.Add("New-NetFirewallRule $Name") }
    function Write-CloudflareCommand { $script:Calls.Add('Write-CloudflareCommand') }
    function Update-CloudflareFirewall { $script:Calls.Add('Update-CloudflareFirewall') }
    function Get-CimInstance($ClassName) { return [pscustomobject]@{ ProductType = $script:ProductType } }
    function Install-WindowsFeature($Name) { $script:Calls.Add("Install-WindowsFeature $($Name -join ',')"); return [pscustomobject]@{ Success = $true } }
    function Download { }
    function Install-Msi { }

    function Expect-Config($Line) { Assert ($script:Config -contains $Line) "Expected IIS setting: $Line`n$($script:Config -join "`n")" }
    $websocket = "system.webServer/rewrite/globalRules/rule[@name='PlusEMU websocket']"

    # A server: ARR adds X-Forwarded-For without a port, and the game connection gets the visitor's address from Cloudflare.
    Reset-Iis
    $script:ProductType = 3
    $script:state = [pscustomobject]@{ Domain = 'example.com'; WsUrl = 'wss://example.com/ws' }
    $WsHost = 'example.com'; $WsPath = 'ws'
    Install-WebServer *> $null
    Expect-Config 'system.webServer/proxy|enabled|True'
    Expect-Config 'system.webServer/proxy|xForwardedForHeaderName|X-Forwarded-For'
    Expect-Config 'system.webServer/proxy|includePortInXForwardedFor|False'
    Set-IisSite *> $null
    Expect-Config 'system.webServer/rewrite/allowedServerVariables|.|name=HTTP_X_REAL_IP'
    Expect-Config "$websocket/serverVariables|.|name=HTTP_X_REAL_IP;value={HTTP_CF_CONNECTING_IP}"
    Expect-Config "$websocket/conditions|.|input={HTTP_ORIGIN};pattern=^https://example\.com$"
    Expect-Config "$websocket/action|url|http://127.0.0.1:2096/"

    # A local install removes IIS's own welcome site, which answers on every address. A site the owner changed stays.
    $script:state = [pscustomobject]@{ Domain = 'localhost'; WsUrl = 'ws://localhost/ws'; Local = $true }
    $WsHost = 'localhost'; $WsPath = 'ws'
    $script:DefaultSite = [pscustomobject]@{ Name = 'Default Web Site'; physicalPath = '%SystemDrive%\inetpub\wwwroot'
        bindings = [pscustomobject]@{ Collection = @([pscustomobject]@{ protocol = 'http'; bindingInformation = '*:80:' }) } }
    function Get-Website($Name) { if ($Name -eq 'Default Web Site') { return $script:DefaultSite } }
    Reset-Iis
    Set-IisSite *> $null
    Assert ($script:Calls -contains 'Remove-Website Default Web Site') "IIS's welcome site stays open: $($script:Calls -join '; ')"
    $script:DefaultSite.physicalPath = 'C:\sites\mine'
    Reset-Iis
    Set-IisSite *> $null
    Assert ($script:Calls -notcontains 'Remove-Website Default Web Site') 'A site the owner changed was removed'
    $script:DefaultSite.physicalPath = '%SystemDrive%\inetpub\wwwroot'
    $script:DefaultSite.bindings.Collection += [pscustomobject]@{ protocol = 'http'; bindingInformation = '*:8081:' }
    Reset-Iis
    Set-IisSite *> $null
    Assert ($script:Calls -notcontains 'Remove-Website Default Web Site') 'A site with the owner''s own binding was removed'
    Write-Host 'PowerShell web server checks passed'
} finally {
    Remove-Item $testDir -Recurse -Force
}
