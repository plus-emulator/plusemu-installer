# Exercise the Cloudflare API setup against a fake Cloudflare API, certificate store and IIS.
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

# What Invoke-RestMethod throws for an HTTP error: the status on the response, Cloudflare's JSON in ErrorDetails.
class FakeHttpException : Exception {
    $Response
    FakeHttpException([string]$Message, [int]$Status) : base($Message) { $this.Response = [pscustomobject]@{ StatusCode = $Status } }
}

$Token = 'cf-test-token-6f1d0c9e'
$X509 = 'Security.Cryptography.X509Certificates'
function New-TestRoot($Subject) { # a certificate authority with its private key
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = New-Object "$X509.CertificateRequest" $Subject, $key, 'SHA256', ([Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $request.CertificateExtensions.Add((New-Object "$X509.X509BasicConstraintsExtension" $true, $false, 0, $true))
    $request.CertificateExtensions.Add((New-Object "$X509.X509KeyUsageExtension" ([Security.Cryptography.X509Certificates.X509KeyUsageFlags]'KeyCertSign, CrlSign'), $true))
    return $request.CreateSelfSigned((Get-Date).AddDays(-1), (Get-Date).AddYears(20))
}
$OriginRoot = New-TestRoot 'CN=CloudFlare Origin SSL Certificate Authority, O="CloudFlare, Inc."'

function New-TestCertificate([string[]]$Names, $Days = 5475, $Issuer = $OriginRoot) { # a certificate with its private key, signed by $Issuer
    $key = [Security.Cryptography.RSA]::Create(2048)
    $request = New-Object "$X509.CertificateRequest" "CN=$($Names[0])", $key, 'SHA256', ([Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $san = New-Object "$X509.SubjectAlternativeNameBuilder"
    foreach ($name in $Names) { $san.AddDnsName($name) }
    $request.CertificateExtensions.Add($san.Build())
    $serial = [byte[]](1..8 | ForEach-Object { Get-Random -Maximum 256 })
    $certificate = $request.Create($Issuer, (Get-Date).AddDays(-1), (Get-Date).AddDays($Days), $serial)
    return [Security.Cryptography.X509Certificates.RSACertificateExtensions]::CopyWithPrivateKey($certificate, $key)
}

$testDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $testDir | Out-Null
try {
    $Templates = Join-Path $root 'templates'
    $HotelRoot = Join-Path $testDir 'hotel'
    $StateDir = Join-Path $testDir 'state'
    $StateFile = Join-Path $StateDir 'hotel.json'
    $NightlyRoot = Join-Path $StateDir 'nightly'
    $script:Log = Join-Path $StateDir 'install.log'
    $script:Step = 0; $TotalSteps = 12
    $CloudflareApi = 'https://api.cloudflare.test/client/v4'
    $ServerIp = '192.0.2.10'
    $Guide = Join-Path (Join-Path $HotelRoot 'setup-guide') 'index.html'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    function New-State {
        $script:state = [pscustomobject]@{ Domain = 'example.com'; WsUrl = 'wss://example.com/ws'; HotelName = 'Example'; AdminUser = 'admin'
            AdminEmail = 'admin@example.com'; GuideMode = 'simple'; AdminPassword = 'initial-admin-password'; DbPassword = 'database-password'; DbRootPassword = 'root-password' }
        $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        Set-WsUrl 'wss://example.com/ws'
    }
    function Set-WsUrl($Url) {
        $state.WsUrl = $Url
        $rest = $Url.Substring(6)
        $script:WsHost = $rest.Split('/')[0]
        $script:WsPath = if ($rest.Contains('/')) { $rest.Substring($rest.IndexOf('/') + 1) } else { '' }
    }

    # ---------------------------------------------------------------- fakes

    function New-Cloudflare { # an empty Cloudflare account with the site added
        $script:Cf = @{
            Token = $Token; Zone = $true; ZoneLater = $false; Deny = ''; Calls = [Collections.ArrayList]@(); Bodies = [Collections.ArrayList]@()
            Dns = [Collections.ArrayList]@(); Settings = @{}; Rulesets = @{}; IisRejects = $false
        }
        $script:Bound = $null
    }
    function Reply($Result) { return (@{ success = $true; errors = @(); result = $Result } | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
    function Fail($Status, $Message) {
        $record = [Management.Automation.ErrorRecord]::new([FakeHttpException]::new("Response status code does not indicate success: $Status", $Status), 'WebCmdletWebResponseException', 'InvalidOperation', $null)
        $record.ErrorDetails = [Management.Automation.ErrorDetails]::new((@{ success = $false; errors = @(@{ code = 10000; message = $Message }) } | ConvertTo-Json -Depth 5))
        throw $record
    }
    function Invoke-RestMethod($Method, $Uri, $Headers, $ContentType, $TimeoutSec, $Body) {
        $path = $Uri.Substring($CloudflareApi.Length)
        [void]$Cf.Calls.Add("$Method $path")
        $data = $null
        if ($Body) { [void]$Cf.Bodies.Add("$Method $path $Body"); $data = $Body | ConvertFrom-Json }
        if ($Headers.Authorization -cne "Bearer $($Cf.Token)") { Fail 401 'Invalid API Token' }
        if ($Cf.Deny -and "$Method $path" -like $Cf.Deny) { Fail 403 'Authentication error' }
        switch -Wildcard ("$Method $path") {
            'GET /user/tokens/verify' { return Reply @{ status = 'active' } }
            'GET /zones?name=example.com' {
                if ($Cf.Zone) { return Reply @(@{ id = 'zone1'; name = 'example.com'; status = 'active' }) }
                # The owner adds the site while the installer waits.
                if ($Cf.ZoneLater) { $Cf.Zone = $true }
                return Reply @()
            }
            'GET /zones/zone1/dns_records?name=*' {
                $name = ($path -replace '^.*name=', '') -replace '&.*$', ''
                return Reply @($Cf.Dns | Where-Object { $_.name -eq $name })
            }
            'POST /zones/zone1/dns_records' {
                $record = [pscustomobject]@{ id = "record$($Cf.Dns.Count)"; type = $data.type; name = $data.name; content = $data.content; proxied = $data.proxied; ttl = $data.ttl }
                [void]$Cf.Dns.Add($record)
                return Reply $record
            }
            'PATCH /zones/zone1/dns_records/*' {
                $record = $Cf.Dns | Where-Object { $_.id -eq ($path -split '/')[-1] }
                $record.content = $data.content; $record.proxied = $data.proxied
                return Reply $record
            }
            'POST /certificates' {
                Assert ($data.requested_validity -eq 5475 -and $data.request_type -eq 'origin-rsa' -and $data.csr -eq 'CSR') "Unexpected certificate request: $Body"
                $script:Issued = New-TestCertificate @($data.hostnames)
                return Reply @{ id = '1'; certificate = 'PEM' }
            }
            'GET /zones/zone1/settings/security_level' {
                $value = if ($Cf.Settings.security_level) { $Cf.Settings.security_level } else { 'medium' }
                return Reply @{ id = 'security_level'; value = $value }
            }
            'PATCH /zones/zone1/settings/*' {
                $Cf.Settings[($path -split '/')[-1]] = $data.value
                return Reply @{ id = ($path -split '/')[-1]; value = $data.value }
            }
            'PUT /zones/zone1/bot_management' { $Cf.Settings.bot_management = $data; return Reply $data }
            'GET /zones/zone1/rulesets/phases/*/entrypoint' {
                $phase = ($path -split '/')[-2]
                if (-not $Cf.Rulesets[$phase]) { Fail 404 "could not find entrypoint ruleset in the $phase phase" }
                return Reply $Cf.Rulesets[$phase]
            }
            'PUT /zones/zone1/rulesets/phases/*/entrypoint' {
                $phase = ($path -split '/')[-2]
                $rules = [Collections.ArrayList]@()
                foreach ($rule in @($data.rules)) { $rule | Add-Member id "rule$($rules.Count)"; [void]$rules.Add($rule) }
                $Cf.Rulesets[$phase] = @{ id = "rs-$phase"; phase = $phase; rules = $rules }
                return Reply $Cf.Rulesets[$phase]
            }
            'POST /zones/zone1/rulesets/rs-*/rules' {
                $set = $Cf.Rulesets[(($path -split '/')[-2]).Substring(3)]
                $data | Add-Member id "rule$($set.rules.Count)"
                [void]$set.rules.Add($data)
                return Reply $set
            }
            'PATCH /zones/zone1/rulesets/rs-*/rules/*' {
                $set = $Cf.Rulesets[(($path -split '/')[-3]).Substring(3)]
                $id = ($path -split '/')[-1]
                $index = [array]::FindIndex([object[]]$set.rules, [Predicate[object]] { param($r) $r.id -eq $id })
                $data | Add-Member id $id
                $set.rules[$index] = $data
                return Reply $set
            }
        }
        Fail 404 "fake Cloudflare has no $Method $path"
    }
    # The certificate store, certreq and IIS exist only on Windows.
    function Get-OriginRoot { return $OriginRoot }
    function Get-HotelCertificate { return $script:Bound }
    function New-OriginRequest { [void]$Cf.Calls.Add('certreq -new'); return 'CSR' }
    function Install-OriginCertificate($Pem, $Root) {
        [void]$Cf.Calls.Add('certreq -accept')
        Assert ($Pem -eq 'PEM' -and $Root -eq $OriginRoot) 'The certificate was installed without the Origin CA root'
        if ($Cf.IisRejects) { Stop-Cloudflare 'IIS did not accept the new certificate (test), so the previous one is back.' }
        $script:Bound = $script:Issued
        return $script:Issued
    }
    function Start-Process($FilePath) { [void]$Cf.Calls.Add("open $FilePath") }
    function Copy-Item { }
    $script:Answers = [Collections.Queue]@()
    function Read-Host($Prompt, [switch]$AsSecureString) {
        Assert $AsSecureString "The question is not hidden: $Prompt"
        $script:Prompts += "$Prompt`n"
        $answer = if ($script:Answers.Count) { $script:Answers.Dequeue() } else { throw "No answer for: $Prompt" }
        $secure = New-Object Security.SecureString
        foreach ($character in "$answer".ToCharArray()) { $secure.AppendChar($character) }
        return $secure
    }

    function Invoke-Step([string[]]$Answers = @(), [hashtable]$Environment = @{}) { # one Cloudflare step, as the installer runs it
        $Cf.Calls.Clear(); $Cf.Bodies.Clear()
        $script:Answers = New-Object Collections.Queue
        foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
        $script:Prompts = ''
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
        try { $script:Output = Connect-Cloudflare 6>&1 | Out-String }
        finally { foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $null) } }
        $script:state = Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    function Get-Calls { return (@($Cf.Calls | Where-Object { $_ -notlike 'open *' }) -join "`n") }
    function Assert-Calls($Expected) { Assert ((Get-Calls) -eq $Expected) "Expected calls:`n$Expected`nGot:`n$(Get-Calls)" }
    function Assert-Output($Text) { Assert ($Output.Contains($Text)) "Expected on the console: $Text`nGot:`n$Output" }
    function Assert-Guide($Text, [switch]$Not) {
        $found = (Get-Content $Guide -Raw).Contains($Text)
        Assert ($found -ne [bool]$Not) "$(if ($Not) { 'Unexpected' } else { 'Expected' }) in the guide: $Text"
    }
    function Assert-TokenNowhere {
        $files = Get-ChildItem $testDir -Recurse -File | Where-Object { (Get-Content $_.FullName -Raw) -match [regex]::Escape($Token) }
        Assert (-not $files) "The token was written to $($files.FullName -join ', ')"
        Assert (-not $Output.Contains($Token)) 'The token was shown on the console'
        Assert (-not $env:PLUSEMU_CLOUDFLARE_TOKEN -and -not $script:CloudflareToken) 'The token was kept after the step'
    }
    function Get-Dns { return (@($Cf.Dns | ForEach-Object { "$($_.type) $($_.name) $($_.content) $($_.proxied)" } | Sort-Object) -join "`n") }

    $success = @'
GET /user/tokens/verify
GET /zones?name=example.com
GET /zones/zone1/dns_records?name=example.com&per_page=100
POST /zones/zone1/dns_records
GET /zones/zone1/dns_records?name=www.example.com&per_page=100
POST /zones/zone1/dns_records
certreq -new
POST /certificates
certreq -accept
PATCH /zones/zone1/settings/ssl
PATCH /zones/zone1/settings/always_use_https
PATCH /zones/zone1/settings/websockets
PATCH /zones/zone1/settings/min_tls_version
PATCH /zones/zone1/settings/browser_check
GET /zones/zone1/settings/security_level
PATCH /zones/zone1/settings/security_level
PUT /zones/zone1/bot_management
GET /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
PUT /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
GET /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint
PUT /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint
'@.Trim() -replace "`r", ''

    # ---------------------------------------------------------------- certificate checks

    New-State
    Set-WsUrl 'wss://ws.example.com'
    Assert (Test-OriginCertificate (New-TestCertificate @('example.com', '*.example.com')) $OriginRoot) 'A valid origin certificate was refused'
    Assert (-not (Test-OriginCertificate (New-TestCertificate @('example.com', 'www.example.com')) $OriginRoot)) 'A certificate without the game address was accepted'
    Assert (-not (Test-OriginCertificate (New-TestCertificate @('example.com', '*.example.com') 10) $OriginRoot)) 'A certificate that expires in 10 days was accepted'
    $other = New-TestRoot 'CN=Someone else'
    Assert (-not (Test-OriginCertificate (New-TestCertificate @('example.com', '*.example.com') 5475 $other) $OriginRoot)) 'A certificate from another root was accepted'
    $withoutKey = New-Object "$X509.X509Certificate2" (, (New-TestCertificate @('example.com', '*.example.com')).RawData)
    Assert (-not (Test-OriginCertificate $withoutKey $OriginRoot)) 'A certificate without its private key was accepted'
    Assert (-not (Test-OriginCertificate $null $OriginRoot)) 'A missing certificate was accepted'

    # ---------------------------------------------------------------- skipped

    New-State
    New-Cloudflare
    Write-GuideFile
    Invoke-Step -Environment @{ PLUSEMU_YES = '1' }
    Assert-Calls ''
    Assert-Output 'Skipped. Follow the manual steps in the guide.'
    Assert-Output 'Connect Cloudflare automatically'
    Assert-Guide 'id="connect-cloudflare-automatically"'
    Assert-Guide 'class="card connected"' -Not
    Assert-Guide '{{' -Not
    Assert-Guide 'Now connect <b>example.com</b> through Cloudflare and install its origin certificate.'
    # The game connection uses the website's own address, so the guide names no separate game address.
    Assert-Guide 'the <b>A</b> records for <code>example.com</code> and <code>www.example.com</code>, pointing to'
    Assert-Guide 'the game address' -Not
    Assert (-not ($Cf.Calls -like 'open *')) 'An unattended run opened the browser'

    # Enter at the question skips as well; the guide opens in the browser first.
    Invoke-Step -Answers @('')
    Assert-Calls ''
    Assert ($Cf.Calls[0] -eq "open $Guide") "The guide did not open first: $($Cf.Calls -join ', ')"
    Assert ($Prompts.Contains('Paste your Cloudflare API token, or press Enter to skip and follow the manual steps in the guide')) "Asked: $Prompts"

    # ---------------------------------------------------------------- the site is missing

    $Cf.Zone = $false
    Invoke-Step -Answers @('skip') -Environment @{ PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert-Calls "GET /user/tokens/verify`nGET /zones?name=example.com"
    Assert-Output 'Cloudflare has no site example.com that this token can use'
    Assert ($Prompts.Contains('press Enter to try again, paste a new token, or type skip')) "Asked: $Prompts"
    Assert-Guide 'The installer could not finish the Cloudflare setup.'
    Assert-Guide 'Cloudflare has no site example.com that this token can use'
    Assert (-not $state.CloudflareSetup) 'A missing site was saved as done'
    Assert-TokenNowhere

    # A wrong token is named as such.
    $Cf.Token = 'another-token'
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert-Calls 'GET /user/tokens/verify'
    Assert-Output 'Cloudflare did not accept the token'
    Assert-Output 'Invalid API Token'
    $Cf.Token = $Token

    # ---------------------------------------------------------------- success

    # The owner pastes the token, adds the site while the installer waits, presses Enter, and every step runs.
    $Cf.ZoneLater = $true
    Invoke-Step -Answers @($Token, '')
    Assert-Output 'Cloudflare has no site example.com'
    Assert-Calls "GET /user/tokens/verify`nGET /zones?name=example.com`n$success"
    Assert-Output 'Cloudflare is connected.'
    Assert ((Get-Dns) -eq "A example.com 192.0.2.10 True`nA www.example.com 192.0.2.10 True") "DNS: $(Get-Dns)"
    foreach ($setting in @(@('ssl', 'strict'), @('always_use_https', 'on'), @('websockets', 'on'), @('min_tls_version', '1.2'), @('browser_check', 'on'), @('security_level', 'medium'))) {
        Assert ($Cf.Settings[$setting[0]] -eq $setting[1]) "$($setting[0]) is $($Cf.Settings[$setting[0]])"
    }
    Assert ($Cf.Settings.bot_management.fight_mode -eq $true) 'Bot Fight Mode is off'
    Assert (($Cf.Bodies -match '^POST /certificates ') -match '"hostnames":\["example.com","\*.example.com"\]') "Certificate names: $($Cf.Bodies -match 'certificates')"
    Assert ($script:Bound -eq $script:Issued) 'The new certificate is not on the HTTPS bindings'
    $limit = $Cf.Rulesets.http_ratelimit.rules[0]
    Assert ($limit.description -eq 'PlusEMU: limit sign-in and registration' -and $limit.action -eq 'block') 'Rate limit rule'
    Assert ((($limit.ratelimit.characteristics) -join ',') -eq 'cf.colo.id,ip.src' -and $limit.ratelimit.period -eq 10 -and $limit.ratelimit.requests_per_period -eq 10 -and $limit.ratelimit.mitigation_timeout -eq 10) 'Rate limit numbers'
    foreach ($page in '"/login"', '"/register"', '"/forgot-password"', '"/two-factor-challenge"', '"/housekeeping/login"', '"/reset-password/*"') {
        Assert ($limit.expression.Contains($page)) "The rate limit misses $page"
    }
    $custom = $Cf.Rulesets.http_request_firewall_custom.rules
    Assert ($custom[0].expression -eq '(http.host eq "example.com" and http.request.uri.path eq "/ws" and not any(http.request.headers["origin"][*] eq "https://example.com"))' -and $custom[0].action -eq 'block') "Game rule: $($custom[0].expression)"
    Assert ($custom[1].action -eq 'managed_challenge' -and $custom[1].expression.Contains('"/housekeeping"') -and $custom[1].expression.Contains('"/housekeeping/*"')) 'Housekeeping rule'
    # Only the result is saved, never the token.
    Assert ($state.CloudflareSetup -eq 'done') 'The setup was not saved as done'
    Assert ($state.CloudflareCertExpires -eq $script:Issued.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd')) "Saved expiry: $($state.CloudflareCertExpires)"
    Assert-Guide 'class="card connected"'
    Assert-Guide "valid until <b>$($state.CloudflareCertExpires)</b>"
    Assert-Guide '<details class="card manual"><summary>If you need to do this by hand</summary>'
    Assert-Guide 'could not finish' -Not
    Assert-Guide '{{' -Not
    Assert-Guide 'Cloudflare is connected. Check your hotel below.'
    Assert-Guide 'Now connect' -Not
    Assert-Guide '<b>DNS:</b> <code>example.com</code> and <code>www.example.com</code> point to'
    Assert-Guide 'the game address' -Not
    Assert-TokenNowhere
    $summary = Complete-Install 6>&1 | Out-String
    Assert ($summary.Contains('Cloudflare is connected. Open https://example.com')) "Summary: $summary"

    # ---------------------------------------------------------------- reruns

    # A rerun asks only whether to keep the setup; Enter keeps it without calling Cloudflare.
    Invoke-Step -Answers @('')
    Assert-Calls ''
    Assert-Output 'Cloudflare is already connected.'
    Assert ($Prompts.Contains('Press Enter to keep it, or paste a token to run it again')) "Asked: $Prompts"
    Assert-Guide 'class="card connected"'

    # Running it again updates the installer's own records and rules and keeps the valid certificate.
    $dns = Get-Dns
    $certificate = $script:Bound
    Invoke-Step -Answers @($Token)
    Assert-Calls @'
GET /user/tokens/verify
GET /zones?name=example.com
GET /zones/zone1/dns_records?name=example.com&per_page=100
GET /zones/zone1/dns_records?name=www.example.com&per_page=100
PATCH /zones/zone1/settings/ssl
PATCH /zones/zone1/settings/always_use_https
PATCH /zones/zone1/settings/websockets
PATCH /zones/zone1/settings/min_tls_version
PATCH /zones/zone1/settings/browser_check
GET /zones/zone1/settings/security_level
PATCH /zones/zone1/settings/security_level
PUT /zones/zone1/bot_management
GET /zones/zone1/rulesets/phases/http_ratelimit/entrypoint
PATCH /zones/zone1/rulesets/rs-http_ratelimit/rules/rule0
GET /zones/zone1/rulesets/phases/http_request_firewall_custom/entrypoint
PATCH /zones/zone1/rulesets/rs-http_request_firewall_custom/rules/rule0
PATCH /zones/zone1/rulesets/rs-http_request_firewall_custom/rules/rule1
'@.Trim().Replace("`r", '')
    Assert ((Get-Dns) -eq $dns) 'A rerun changed the DNS records'
    Assert ($script:Bound -eq $certificate) 'A rerun replaced a valid certificate'
    Assert ($Cf.Rulesets.http_ratelimit.rules.Count -eq 1 -and $Cf.Rulesets.http_request_firewall_custom.rules.Count -eq 2) 'A rerun added copies of the rules'
    Assert-Output 'Origin certificate: already installed'

    # The owner's own rules stay, and Under Attack mode stays on.
    [void]$Cf.Rulesets.http_request_firewall_custom.rules.Add([pscustomobject]@{ id = 'owner'; description = 'My own rule'; expression = 'true'; action = 'block' })
    $Cf.Settings.security_level = 'under_attack'
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert ($Cf.Rulesets.http_request_firewall_custom.rules.Count -eq 3 -and $Cf.Rulesets.http_request_firewall_custom.rules[2].description -eq 'My own rule') "The owner's rule was changed"
    Assert ($Cf.Settings.security_level -eq 'under_attack') 'Under Attack mode was turned off'
    Assert-TokenNowhere

    # ---------------------------------------------------------------- failures

    # A token without one permission stops at that step, names the permission and keeps the manual guide.
    New-State
    New-Cloudflare
    $Cf.Deny = 'PUT /zones/zone1/bot_management'
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert-Calls (($success -split "`n" | Select-Object -First 17) -join "`n")
    Assert-Output 'The Bot Fight Mode step failed: the token lacks the permission Zone / Bot Management / Edit.'
    Assert-Output 'Authentication error'
    Assert-Output 'The installer did not finish the Cloudflare setup.'
    Assert-Guide 'the token lacks the permission Zone / Bot Management / Edit'
    Assert-Guide 'class="card connected"' -Not
    Assert (-not $state.CloudflareSetup) 'A failed setup was saved as done'
    Assert-TokenNowhere

    # IIS refuses the new certificate: the previous one stays and Full (strict) stays off.
    New-Cloudflare
    $Cf.IisRejects = $true
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert (-not $script:Bound) 'The refused certificate was bound'
    Assert (-not ($Cf.Calls -match 'settings/ssl$')) 'Full (strict) was turned on without a working certificate'
    Assert-Output 'The origin certificate step failed: IIS did not accept the new certificate (test), so the previous one is back.'

    # DNS: a wrong or grey record is corrected, a CNAME stops the setup, and other records stay.
    New-Cloudflare
    [void]$Cf.Dns.Add([pscustomobject]@{ id = 'a1'; type = 'A'; name = 'example.com'; content = '198.51.100.7'; proxied = $false })
    [void]$Cf.Dns.Add([pscustomobject]@{ id = 'm1'; type = 'MX'; name = 'example.com'; content = 'mail.example.com'; proxied = $null })
    [void]$Cf.Dns.Add([pscustomobject]@{ id = 'c1'; type = 'CNAME'; name = 'www.example.com'; content = 'elsewhere.example.net'; proxied = $false })
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert ((Get-Dns) -eq "A example.com 192.0.2.10 True`nCNAME www.example.com elsewhere.example.net False`nMX example.com mail.example.com ") "DNS: $(Get-Dns)"
    Assert-Output 'www.example.com has a CNAME record. Delete it in Cloudflare (DNS > Records)'
    Assert (-not ($Cf.Calls -contains 'POST /certificates')) 'Continued after a DNS failure'

    # A separate game address gets its own record, certificate name check and firewall rule.
    New-Cloudflare
    Set-WsUrl 'wss://ws.example.com'
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert ((Get-Dns) -eq "A example.com 192.0.2.10 True`nA ws.example.com 192.0.2.10 True`nA www.example.com 192.0.2.10 True") "DNS: $(Get-Dns)"
    Assert ($Cf.Rulesets.http_request_firewall_custom.rules[0].expression.StartsWith('(http.host eq "ws.example.com" and http.request.uri.path eq "/" and')) 'Game rule for a separate address'
    Assert ($state.CloudflareSetup -eq 'done') 'A separate game address was not set up'
    Assert-Guide '<b>DNS:</b> <code>example.com</code>, the game address <code>ws.example.com</code> and <code>www.example.com</code> point to'
    Assert-Guide 'the <b>A</b> records for <code>example.com</code>, the game address <code>ws.example.com</code> and <code>www.example.com</code>, pointing to'

    # A game address on another domain is left to the manual steps before anything changes.
    New-State
    New-Cloudflare
    Set-WsUrl 'wss://game.example.net/ws'
    Invoke-Step -Environment @{ PLUSEMU_YES = '1'; PLUSEMU_CLOUDFLARE_TOKEN = $Token }
    Assert-Calls ''
    Assert-Output 'The game connection uses another domain (game.example.net)'
    Assert-TokenNowhere
    Write-Host 'PowerShell Cloudflare checks passed'
} finally {
    Remove-Item Env:\PLUSEMU_CLOUDFLARE_TOKEN, Env:\PLUSEMU_YES -ErrorAction SilentlyContinue
    Remove-Item $testDir -Recurse -Force
}
