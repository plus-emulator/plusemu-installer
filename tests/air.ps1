# Set up the AIR client against fake downloads, IIS, firewall, PHP and emulator commands, and check what it writes.
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
    $LockFile = Join-Path $testDir 'lock'
    $Downloads = Join-Path $testDir 'downloads'
    $PhpDir = Join-Path $testDir 'php'
    $AirManifestUrl = 'https://assets.test/air/latest.json'
    $AirPort = 30000
    $script:Log = Join-Path $testDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 1
    $script:ServerIp = '192.0.2.10'
    $published = Join-Path $testDir 'published'
    $emulator = Join-Path $HotelRoot 'emulator'
    $configDir = Join-Path $emulator 'Config'
    $config = Join-Path $configDir 'config.json'
    New-Item -ItemType Directory -Force -Path $StateDir, $Downloads, $published, $configDir, (Join-Path $HotelRoot 'cms') | Out-Null
    $script:state = [pscustomobject]@{ Domain = 'example.com'; Local = $false; Air = $true; AirGameHost = '' }

    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:FirewallRules = [Collections.Generic.List[string]]::new()
    function Run {
        $script:Calls.Add("$args")
        # The emulator writes a new key, and refuses to overwrite one, like PlusEMU's --generate-rsa-key.
        if ($args[1] -eq '--generate-rsa-key') {
            if (Test-Path $args[2]) { throw 'exists' }
            Set-Content $args[2] "key $([guid]::NewGuid())"
        }
        if ("$args" -match 'advfirewall firewall add rule name=(\S+)') { $script:FirewallRules.Add($Matches[1]) }
    }
    function Test-AirFirewallRule { return $script:FirewallRules -contains "plusemu-air-$AirPort" }
    # The published files are served from the test folder, like assets.plusemu.dev.
    function Invoke-Curl([string[]]$Arguments) {
        $out = $Arguments[[array]::IndexOf($Arguments, '-o') + 1]
        $source = Join-Path $published ($Arguments[-1] -replace '^.*/', '')
        if (-not (Test-Path $source)) { return @{ Code = 22; Output = '' } }
        Copy-Item $source $out
        return @{ Code = 0; Output = '' }
    }
    function Get-Sha($File) { return (Get-FileHash $File -Algorithm SHA256).Hash.ToLower() }
    function Publish($Version, $Texts) {
        Set-Content (Join-Path $published 'external_variables.txt') "flash.client.url=https://images.habbo.com/$Version"
        Set-Content (Join-Path $published 'external_flash_texts.txt') $Texts
        Write-Utf8 (Join-Path $published 'latest.json') (@{
            version = $Version
            client = @{ url = "https://assets.test/air/client/$Version/HabboWin.zip" }
            externalVariables = @{ url = 'https://assets.test/air/external_variables.txt'; sha256 = Get-Sha (Join-Path $published 'external_variables.txt') }
            externalFlashTexts = @{ url = 'https://assets.test/air/external_flash_texts.txt'; sha256 = Get-Sha (Join-Path $published 'external_flash_texts.txt') }
        } | ConvertTo-Json -Depth 5)
    }
    $textsFile = Join-Path (Join-Path $configDir 'air') 'external_flash_texts.txt'

    # The choice: -WithAir or PLUSEMU_AIR=1 turns it on, a saved choice keeps it on.
    Assert (-not (Resolve-Air $false)) 'The AIR client is on without the option'
    Assert (Resolve-Air $true) 'The saved choice was lost'
    $env:PLUSEMU_AIR = '1'
    Assert (Resolve-Air $false) 'PLUSEMU_AIR=1 did not turn it on'
    Remove-Item Env:\PLUSEMU_AIR

    # The published texts are downloaded and checked.
    Publish '38-1' 'texts one'
    Assert (Get-AirFiles $configDir) "Download: $script:AirError"
    Assert ($script:AirVersion -eq '38-1') "Version: $script:AirVersion"
    Assert ($script:AirClientUrl -eq 'https://assets.test/air/client/38-1/HabboWin.zip') "Client: $script:AirClientUrl"
    Assert ((Get-Content $textsFile -Raw).Trim() -eq 'texts one') 'The texts were not saved'
    # A file that does not match its checksum changes nothing, and says why.
    Publish '39-1' 'texts two'
    Set-Content (Join-Path $published 'external_flash_texts.txt') 'tampered'
    Assert (-not (Get-AirFiles $configDir)) 'A tampered file was accepted'
    Assert ($script:AirError -like '*external_flash_texts.txt*checksum*') "Reason: $script:AirError"
    Assert ((Get-Content $textsFile -Raw).Trim() -eq 'texts one') 'A failed download replaced the texts'
    # A new setup stops without texts; one that has them keeps them; an update goes on without the AIR client.
    Remove-Item (Join-Path $published 'latest.json')
    Assert ((Get-AirTexts $emulator *>&1 | Out-String) -like '*keeps the texts it had*') 'The old texts were not kept'
    Remove-Item (Join-Path $configDir 'air') -Recurse
    $failed = $null
    try { Get-AirTexts $emulator *> $null } catch { $failed = "$_" }
    Assert ($failed -like "*$AirManifestUrl*internet connection*") "New setup: $failed"
    Assert (-not (Get-AirTexts $emulator -Update 6> $null)) 'An update without texts set up the AIR client'
    Publish '38-1' 'texts one'
    $null = Get-AirFiles $configDir

    # The handshake key is made once: players' clients carry its modulus.
    Write-Utf8 $config '{"Encryption":{"RsaPrivateKeyFile":""}}'
    New-AirKey $emulator
    $keyFile = Join-Path $configDir 'rsa-private.pem'
    $key = Get-Content $keyFile -Raw
    New-AirKey $emulator
    Assert ((Get-Content $keyFile -Raw) -eq $key) 'The handshake key was replaced'
    Assert (@($script:Calls | Where-Object { $_ -like '*--generate-rsa-key*' }).Count -eq 1) "Calls: $($script:Calls -join '; ')"
    # A key the owner set up is kept, also in another file.
    Set-Content (Join-Path $configDir 'mine.pem') 'my own key'
    Write-Utf8 $config '{"Encryption":{"RsaPrivateKeyFile":"mine.pem"}}'
    New-AirKey $emulator
    Assert ((Get-Content (Join-Path $configDir 'mine.pem') -Raw).Trim() -eq 'my own key') 'The owner''s key was replaced'
    Assert (@($script:Calls | Where-Object { $_ -like '*--generate-rsa-key*' }).Count -eq 1) 'A second key was made'

    # The emulator settings: the AIR client's values, and every other setting stays.
    $json = @'
{"Database":{"Password":"secret"},"Flash":{"Hostname":"127.0.0.1","Port":1232,"Name":"Default Flash Server"},"Encryption":{"RsaPrivateKeyFile":""},
 "AirClient":{"UrlPrefix":"","ExternalVariablesFiles":[],"ExternalTextsFiles":["my-texts.txt"],"ProductDataFile":"","Variables":{"my.variable":"mine"},
 "Environment":"en","GameHost":"","GamePorts":"30000","ClientVersion":"","ClientUrl":"","TicketLifetimeSeconds":60},"Camera":{"Bearer":"camera-password"}}
'@ | ConvertFrom-Json
    Set-AirSettings $json
    $written = $json | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $gamedata = Join-Path (Join-Path $HotelRoot 'hotel-files') 'gamedata'
    Assert ($written.Flash.Hostname -eq '0.0.0.0' -and $written.Flash.Port -eq 30000 -and $written.Flash.Name -eq 'Default Flash Server') "Flash: $($written.Flash | ConvertTo-Json -Compress)"
    Assert ($written.Encryption.RsaPrivateKeyFile -eq 'rsa-private.pem') 'No key file setting'
    Assert ($written.AirClient.UrlPrefix -eq 'https://example.com') "Prefix: $($written.AirClient.UrlPrefix)"
    Assert ((@($written.AirClient.ExternalVariablesFiles) -join ',') -eq 'air/external_variables.txt') "Variables files: $($written.AirClient.ExternalVariablesFiles)"
    Assert ((@($written.AirClient.ExternalTextsFiles) -join ',') -eq "air/external_flash_texts.txt,$(Join-Path $gamedata 'ExternalTexts.json'),my-texts.txt") "Texts files: $($written.AirClient.ExternalTextsFiles)"
    Assert ($written.AirClient.ProductDataFile -eq (Join-Path $gamedata 'ProductData.json')) "Product data: $($written.AirClient.ProductDataFile)"
    Assert ($written.AirClient.Variables.'external.texts.txt' -eq 'https://example.com/gamedata/external_flash_texts/1') 'external.texts.txt'
    Assert ($written.AirClient.Variables.'external.override.texts.txt' -eq 'https://example.com/gamedata/external_flash_texts/1') 'external.override.texts.txt'
    Assert ($written.AirClient.Variables.'badge.image.path' -eq 'https://example.com/hotel-files/c_images/album1584') 'badge.image.path'
    Assert ($written.AirClient.Variables.'image.library.catalogue.url' -eq 'https://example.com/hotel-files/c_images/catalogue/') 'image.library.catalogue.url'
    Assert ($written.AirClient.Variables.'my.variable' -eq 'mine') 'The owner''s variable was removed'
    Assert ($written.AirClient.GameHost -eq '192.0.2.10' -and $written.AirClient.GamePorts -eq '30000') "Game: $($written.AirClient.GameHost)"
    Assert ($written.AirClient.ClientVersion -eq '38-1' -and $written.AirClient.ClientUrl -like '*/38-1/HabboWin.zip') "Client: $($written.AirClient.ClientUrl)"
    Assert ($written.Database.Password -eq 'secret' -and $written.Camera.Bearer -eq 'camera-password' -and $written.AirClient.TicketLifetimeSeconds -eq 60) 'Other settings changed'
    $before = $json | ConvertTo-Json -Depth 20
    Set-AirSettings $json
    Assert (($json | ConvertTo-Json -Depth 20) -eq $before) 'A second run changed the settings'
    # Without a new client list the client stays; game.<domain> wins once Cloudflare has it; a local hotel stays on this PC.
    $script:AirVersion = ''; $script:AirClientUrl = ''
    $state.AirGameHost = 'game.example.com'
    Set-AirSettings $json
    Assert ($json.AirClient.ClientVersion -eq '38-1' -and $json.AirClient.GameHost -eq 'game.example.com') "Kept client: $($json.AirClient | ConvertTo-Json -Compress)"
    $state.Local = $true
    $state.Domain = 'localhost'
    Set-AirSettings $json
    Assert ($json.Flash.Hostname -eq '127.0.0.1' -and $json.AirClient.GameHost -eq '127.0.0.1' -and $json.AirClient.UrlPrefix -eq 'http://localhost') 'Local settings'
    $state.Local = $false; $state.Domain = 'example.com'; $state.AirGameHost = ''

    # IIS keeps its rules and allowed server variables; the rule is added once.
    $script:Rules = [Collections.Generic.List[string]]::new()
    $script:ServerVariables = [Collections.Generic.List[string]]::new()
    $script:IisConfig = [Collections.Generic.List[string]]::new()
    function Import-Module { }
    function Get-WebConfiguration($PSPath, $Filter) {
        if ($Filter -match "rule\[@name='([^']+)'\]$" -and $script:Rules -contains $Matches[1]) { return $Matches[1] }
        if ($Filter -match "allowedServerVariables/add\[@name='([^']+)'\]$" -and $script:ServerVariables -contains $Matches[1]) { return $Matches[1] }
    }
    function Clear-WebConfiguration($PSPath, $Filter) { if ($Filter -match "rule\[@name='([^']+)'\]$") { $null = $script:Rules.Remove($Matches[1]) } }
    function Format-Value($Value) { if ($Value -is [hashtable]) { return (($Value.Keys | Sort-Object | ForEach-Object { "$_=$($Value[$_])" }) -join ';') } return "$Value" }
    function Add-WebConfigurationProperty($PSPath, $Filter, $Name, $Value) {
        if ($Filter -eq 'system.webServer/rewrite/globalRules') { $script:Rules.Add($Value.name) }
        elseif ($Filter -eq 'system.webServer/rewrite/allowedServerVariables') { $script:ServerVariables.Add($Value.name) }
        else { $script:IisConfig.Add("$Filter|$(Format-Value $Value)") }
    }
    function Set-WebConfigurationProperty($PSPath, $Filter, $Name, $Value) { $script:IisConfig.Add("$Filter|$Name|$Value") }
    Set-AirWebsite
    Set-AirWebsite
    Assert (@($script:Rules | Where-Object { $_ -eq 'PlusEMU AIR client' }).Count -eq 1) "Rules: $($script:Rules -join ', ')"
    Assert (@($script:ServerVariables | Where-Object { $_ -eq 'HTTP_X_FORWARDED_PROTO' }).Count -eq 1) "Server variables: $($script:ServerVariables -join ', ')"
    $rule = "system.webServer/rewrite/globalRules/rule[@name='PlusEMU AIR client']"
    Assert ($script:IisConfig -contains "$rule/match|url|^(api/client/(air\.json|air-ticket|air-launcher-token)|gamedata/(hashes|(external_flash_texts|external_variables|furnidata_xml|productdata)/[^/]+))$") "Config: $($script:IisConfig -join "`n")"
    Assert ($script:IisConfig -contains "$rule/serverVariables|name=HTTP_X_FORWARDED_PROTO;value=https") 'X-Forwarded-Proto is not https'
    Assert ($script:IisConfig -contains "$rule/conditions|input={HTTP_HOST};pattern=^example\.com$") 'The rule is not limited to the hotel domain'
    Assert ($script:IisConfig -contains "$rule/action|url|http://127.0.0.1:8080/{R:1}") 'The rule does not go to the emulator'
    foreach ($path in 'api/client/air.json', 'api/client/air-ticket', 'api/client/air-launcher-token', 'gamedata/hashes', 'gamedata/productdata/abc', 'gamedata/external_flash_texts/1') {
        Assert ($path -match '^(api/client/(air\.json|air-ticket|air-launcher-token)|gamedata/(hashes|(external_flash_texts|external_variables|furnidata_xml|productdata)/[^/]+))$') "Not routed: $path"
    }
    Assert ('api/client/other' -notmatch '^(api/client/(air\.json|air-ticket|air-launcher-token)|gamedata/(hashes|(external_flash_texts|external_variables|furnidata_xml|productdata)/[^/]+))$') 'Other paths are routed'

    # The firewall rule is added once, with netsh.
    $script:Calls.Clear()
    Set-AirFirewall
    Set-AirFirewall
    Assert (@($script:Calls | Where-Object { $_ -like 'netsh.exe advfirewall firewall add rule name=plusemu-air-30000 dir=in action=allow protocol=TCP localport=30000' }).Count -eq 1) "Calls: $($script:Calls -join '; ')"

    # The website button is turned on once, with a fresh configuration cache.
    $envFile = Join-Path (Join-Path $HotelRoot 'cms') '.env'
    Set-Content $envFile @('APP_URL="https://example.com"', 'AIR_CLIENT_ENABLED=false')
    $script:Calls.Clear()
    Set-AirCms
    Assert (@(Get-Content $envFile) -contains 'AIR_CLIENT_ENABLED="true"') "Env: $(Get-Content $envFile -Raw)"
    Assert (@(Get-Content $envFile) -contains 'APP_URL="https://example.com"') 'APP_URL was lost'
    Assert ($script:Calls -match 'php\.exe artisan optimize$') "Calls: $($script:Calls -join '; ')"
    $script:Calls.Clear()
    Set-AirCms
    Assert (-not ($script:Calls -match 'php')) 'The cache was rebuilt without a change'

    # game.<domain> gets an A record that Cloudflare does not proxy.
    $script:Records = @()
    $script:CloudflareCalls = [Collections.Generic.List[string]]::new()
    $CloudflareZone = 'zone1'
    function Invoke-Cloudflare($Method, $Path, $Body = $null) {
        $script:CloudflareCalls.Add("$Method $Path $(if ($Body) { $Body | ConvertTo-Json -Compress })")
        return [pscustomobject]@{ success = $true; result = $script:Records }
    }
    Set-CloudflareGameDns 6> $null
    Assert ($script:CloudflareCalls -match '^POST /zones/zone1/dns_records .*"proxied":false') "Calls: $($script:CloudflareCalls -join '; ')"
    Assert ((Get-Content $StateFile -Raw | ConvertFrom-Json).AirGameHost -eq 'game.example.com') 'The game address was not saved'
    $script:Records = @([pscustomobject]@{ id = 'r1'; type = 'A'; content = '192.0.2.10'; proxied = $true })
    $script:CloudflareCalls.Clear()
    Set-CloudflareGameDns 6> $null
    Assert ($script:CloudflareCalls -match '^PATCH /zones/zone1/dns_records/r1 .*"proxied":false') "Calls: $($script:CloudflareCalls -join '; ')"
    $state.AirGameHost = ''

    # The health check has the AIR client checks only when it is on.
    $checks = @(Get-HealthChecks | ForEach-Object { $_.Name })
    Assert ($checks -contains 'AirLauncher' -and $checks -contains 'AirGamedata' -and $checks -contains 'AirPort') "Checks: $($checks -join ',')"
    $state.Air = $false
    Assert (-not (@(Get-HealthChecks | ForEach-Object { $_.Name }) -match '^Air')) 'A hotel without the AIR client checks it'
    $state.Air = $true
    function Get-ProbeResult([string[]]$Arguments) {
        if ($Arguments[-1] -like '*air.json') { return @{ Code = 0; Output = '{"game":{"host":"192.0.2.10"},"rsa":{"modulus":"abc"},"client":{"url":"https://x"}}' } }
        return @{ Code = 0; Output = '200' }
    }
    function Test-PortAnswers($Port) { return $Port -eq 30000 }
    Assert (-not (Test-AirClient)) "Check: $(Test-AirClient)"
    function Start-Sleep { }
    function Test-PortAnswers($Port) { return $false }
    Assert ((Test-AirClient) -eq 'Nothing answers on port 30000.') "Check: $(Test-AirClient)"
    function Test-PortAnswers($Port) { return $Port -eq 30000 }

    # An update keeps the AIR client on: the staged emulator gets the newest texts and client, and keeps the key.
    $newEmulator = Join-Path $testDir 'new-emulator'
    New-Item -ItemType Directory -Force -Path (Join-Path $newEmulator 'Config') | Out-Null
    Write-Utf8 (Join-Path (Join-Path $newEmulator 'Config') 'config.json') '{"Database":{"Password":""},"Flash":{"Hostname":"127.0.0.1","Port":1232},"Encryption":{"RsaPrivateKeyFile":""},"AirClient":{"GameHost":"","GamePorts":"30000"}}'
    Write-Utf8 $config (@{ Database = @{ Password = 'secret' }; Custom = 'kept'; Encryption = @{ RsaPrivateKeyFile = 'rsa-private.pem' }; AirClient = @{ GameHost = 'game.example.com' } } | ConvertTo-Json -Depth 5)
    Set-Content $textsFile 'old texts'
    $state.AirGameHost = 'game.example.com'
    function Set-CameraSettings($Json) { }
    Copy-EmulatorSettings $emulator $newEmulator
    Publish '40-1' 'texts forty'
    Update-AirSettings $newEmulator 6> $null
    Assert $script:AirReady 'The update did not set up the AIR client'
    $staged = Get-Content (Join-Path (Join-Path $newEmulator 'Config') 'config.json') -Raw | ConvertFrom-Json
    Assert ($staged.Custom -eq 'kept' -and $staged.Database.Password -eq 'secret') 'The update lost the hotel''s settings'
    Assert ($staged.AirClient.ClientVersion -eq '40-1' -and $staged.AirClient.GameHost -eq 'game.example.com' -and $staged.Flash.Port -eq 30000) "Staged: $($staged.AirClient | ConvertTo-Json -Compress)"
    Assert ((Get-Content (Join-Path (Join-Path $newEmulator 'Config') 'rsa-private.pem') -Raw) -eq $key) 'The update replaced the handshake key'
    Assert ((Get-Content (Join-Path (Join-Path (Join-Path $newEmulator 'Config') 'air') 'external_flash_texts.txt') -Raw).Trim() -eq 'texts forty') 'The update kept old texts'
    $state.AirGameHost = ''

    # -Update -WithAir turns it on for an installed hotel, saves the choice, and restarts the emulator only for a change.
    Set-Content (Join-Path $emulator 'Plus Emulator.exe') 'emulator'
    $script:state = [pscustomobject]@{ Domain = 'example.com'; Local = $false; HotelName = 'Example' }
    $state | ConvertTo-Json | Set-Content $StateFile
    function Assert-Administrator { }
    function Get-Derived { $script:ServerIp = '192.0.2.10' }
    function Wait-Emulator { return $true }
    function Restart-Service($Name) { $script:Calls.Add("Restart-Service $Name") }
    function Write-HealthCommand { $script:Calls.Add('Write-HealthCommand') }
    Set-Content $envFile @('APP_URL="https://example.com"', 'AIR_CLIENT_ENABLED=false')
    $script:FirewallRules.Clear()
    Write-Utf8 $config '{"Flash":{"Hostname":"127.0.0.1","Port":1232}}'
    $failed = $null
    try { Invoke-InstallAir *> $null } catch { $failed = "$_" }
    Assert ($failed -like '*no AIR client yet*saved as on*') "Old emulator: $failed"
    Assert ((Get-Content $StateFile -Raw | ConvertFrom-Json).Air -eq $true) 'The choice was not saved'
    Write-Utf8 $config '{"Database":{"Password":"secret"},"Flash":{"Hostname":"127.0.0.1","Port":1232},"Encryption":{"RsaPrivateKeyFile":""},"AirClient":{"GameHost":""}}'
    $script:Calls.Clear()
    $output = Invoke-InstallAir 6>&1 | Out-String
    $installed = Get-Content $config -Raw | ConvertFrom-Json
    Assert ($installed.Database.Password -eq 'secret' -and $installed.Flash.Hostname -eq '0.0.0.0' -and $installed.AirClient.GameHost -eq '192.0.2.10') "Config: $($installed | ConvertTo-Json -Compress)"
    Assert ($script:Calls -contains 'Restart-Service PlusEMU') "Calls: $($script:Calls -join '; ')"
    Assert ($script:Calls -contains 'Write-HealthCommand') 'The health check does not know the AIR client'
    Assert ($script:FirewallRules.Count -eq 1) "Firewall rules: $($script:FirewallRules -join ', ')"
    Assert (@(Get-Content $envFile) -contains 'AIR_CLIENT_ENABLED="true"') 'The website button is off'
    Assert ($output -like '*HabboCustomLauncher/releases*' -and $output -like '*Open AIR client*') "Output: $output"
    $script:Calls.Clear()
    Invoke-InstallAir *> $null
    Assert ($script:Calls -notcontains 'Restart-Service PlusEMU') 'The emulator restarted without a change'
    Assert ($script:FirewallRules.Count -eq 1) 'The firewall rule was added twice'
    Write-Host 'PowerShell AIR client checks passed'
} finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
