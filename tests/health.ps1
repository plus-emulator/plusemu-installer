# Exercise the webhook question and the health check against fake services and a fake Discord.
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

# What Invoke-RestMethod throws for an HTTP error.
class FakeHttpException : Exception {
    $Response
    FakeHttpException([string]$Message, [int]$Status) : base($Message) { $this.Response = [pscustomobject]@{ StatusCode = $Status } }
}

$Webhook = 'https://discord.com/api/webhooks/1234567890/secret-webhook-token_42'
$OtherWebhook = 'https://discordapp.com/api/webhooks/987/other-token'
$testDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $testDir | Out-Null
try {
    $HotelRoot = Join-Path $testDir 'hotel'
    $StateDir = Join-Path $testDir 'state'
    $StateFile = Join-Path $StateDir 'hotel.json'
    $NightlyRoot = Join-Path $StateDir 'nightly'
    $BackupScript = Join-Path $StateDir 'plusemu-backup.ps1'
    $BackupLog = Join-Path $StateDir 'backup.log'
    $CloudflareLog = Join-Path $StateDir 'cloudflare-ips.log'
    $LockFile = Join-Path $StateDir 'update.lock'
    $HealthScript = Join-Path $StateDir 'plusemu-health.ps1'
    $HealthLog = Join-Path $StateDir 'health.log'
    $HealthState = Join-Path $StateDir 'health.json'
    $InstallLog = Join-Path $StateDir 'install.log'
    $script:Log = $InstallLog
    $script:Step = 0; $TotalSteps = 12
    New-Item -ItemType Directory -Force -Path $StateDir, $HotelRoot, $NightlyRoot | Out-Null

    # ---------------------------------------------------------------- the webhook question

    $script:Answers = New-Object Collections.Queue
    $script:Prompts = ''
    function Read-Host($Prompt) {
        $script:Prompts += "$Prompt`n"
        if ($script:Answers.Count) { return $script:Answers.Dequeue() }
        throw "No answer for: $Prompt"
    }
    function Invoke-Answers([string[]]$Answers = @(), [hashtable]$Environment = @{}) {
        $script:Answers = New-Object Collections.Queue
        foreach ($answer in $Answers) { $script:Answers.Enqueue($answer) }
        $script:Prompts = ''
        foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $Environment[$name]) }
        try { $script:Output = Read-Answers 6>&1 | Out-String }
        finally { foreach ($name in $Environment.Keys) { [Environment]::SetEnvironmentVariable($name, $null) } }
        $script:state = Get-Content $StateFile -Raw | ConvertFrom-Json
    }
    $env:PLUSEMU_DOMAIN = 'example.com'; $env:PLUSEMU_WS_URL = 'wss://example.com/ws'
    $env:PLUSEMU_HOTEL_NAME = 'Example'; $env:PLUSEMU_ADMIN_USER = 'admin'
    $env:PLUSEMU_ADMIN_EMAIL = 'admin@example.com'; $env:PLUSEMU_YES = '1'

    # Unattended without a webhook: no question, alerts stay off.
    Invoke-Answers
    Assert ($null -ne $state.PSObject.Properties['DiscordWebhook'] -and -not $state.DiscordWebhook) 'A skipped webhook was not saved as empty'
    Assert (-not $Prompts) "Asked: $Prompts"
    Assert ($Output.Contains('Health alerts: log only')) "Summary: $Output"
    Remove-Item $StateFile

    # A preset webhook is checked and saved; a rerun reuses it and says where to change it.
    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = $Webhook }
    Assert ($state.DiscordWebhook -eq $Webhook -and $script:DiscordWebhookNew) 'A preset webhook was not saved as new'
    Assert ($Output.Contains('Health alerts: Discord')) "Summary: $Output"
    $initial = $state.AdminPassword
    Invoke-Answers
    Assert ($state.DiscordWebhook -eq $Webhook -and -not $script:DiscordWebhookNew -and $state.AdminPassword -ceq $initial) 'A rerun changed the webhook or the passwords'
    Assert ($Output.Contains('Health alerts are on') -and $Output.Contains('PLUSEMU_DISCORD_WEBHOOK')) "Rerun: $Output"
    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = $OtherWebhook }
    Assert ($state.DiscordWebhook -eq $OtherWebhook -and $script:DiscordWebhookNew) 'A new webhook did not replace the old one'
    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = 'off' }
    Assert (-not $state.DiscordWebhook) 'off did not remove the webhook'

    # A preset that is not a Discord webhook stops an unattended run and changes nothing.
    $before = Get-Content $StateFile -Raw
    foreach ($wrong in 'https://example.com/api/webhooks/1/x', 'http://discord.com/api/webhooks/1/x', "https://discord.com/api/webhooks/1/x'y", 'https://discord.com.example.net/api/webhooks/1/x') {
        $rejected = $false
        try { Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = $wrong } } catch { $rejected = $true }
        Assert $rejected "Accepted a wrong webhook: $wrong"
    }
    Assert ((Get-Content $StateFile -Raw) -ceq $before) 'A wrong webhook changed the saved settings'

    # In a console, a wrong answer asks again; a state file from before the question asks it once.
    Remove-Item Env:\PLUSEMU_YES
    Remove-Item $StateFile
    Invoke-Answers -Answers @('not a webhook', $Webhook, 'y')
    Assert ($state.DiscordWebhook -eq $Webhook) 'The second answer was not saved'
    Assert ($Prompts.Contains('Discord webhook URL for alerts when something is wrong with your hotel (optional, press Enter to skip)')) "Asked: $Prompts"
    Assert ($Output.Contains('That is not a Discord webhook URL')) "Output: $Output"
    $state.PSObject.Properties.Remove('DiscordWebhook')
    $state | ConvertTo-Json | Set-Content $StateFile
    Invoke-Answers -Answers @('')
    Assert ($Prompts.Contains('Discord webhook URL')) 'An older state file did not ask the question'
    Assert ($null -ne $state.PSObject.Properties['DiscordWebhook'] -and -not $state.DiscordWebhook) 'Enter did not keep alerts off'
    Invoke-Answers
    Assert (-not $Prompts) "Asked twice: $Prompts"
    $env:PLUSEMU_YES = '1'

    # CrowdSec is Linux-only: the advanced guide says so, the simple guide says nothing.
    Assert (-not $Output.Contains('CrowdSec')) 'The simple guide mentioned CrowdSec'
    Invoke-Answers -Environment @{ PLUSEMU_GUIDE_MODE = 'advanced' }
    Assert ($Output.Contains('CrowdSec: the Windows installer does not install it.')) "Advanced: $Output"
    Assert ($null -eq $state.PSObject.Properties['CrowdSec']) 'Windows saved a CrowdSec choice'
    Invoke-Answers -Environment @{ PLUSEMU_GUIDE_MODE = 'simple' }

    # ---------------------------------------------------------------- fake services and Discord

    $Fake = @{ Down = New-Object Collections.Generic.HashSet[string]; Website = '200'; FreeMb = 40000; DiscordStatus = 0; Messages = New-Object Collections.ArrayList; Uris = New-Object Collections.ArrayList }
    function Get-Service($Name) { if ($Fake.Down.Contains($Name)) { return [pscustomobject]@{ Status = 'Stopped' } } else { return [pscustomobject]@{ Status = 'Running' } } }
    function Test-PortAnswers($Port) { return -not $Fake.Down.Contains("$Port") }
    function curl.exe {
        $global:LASTEXITCODE = 0
        Assert ($args -contains '--resolve' -and $args -contains 'example.com:80:127.0.0.1') "Website probe: $args"
        return $Fake.Website
    }
    function Sql([string]$Query) { if ($Fake.Down.Contains('MariaDB')) { throw 'A database command failed' }; Assert ($Query -eq 'SELECT 1') "Query: $Query"; return '1' }
    function Get-FreeMegabytes($Path) { return $Fake.FreeMb }
    $script:Certificate = [pscustomobject]@{ NotAfter = (Get-Date).AddYears(10) }
    function Get-HotelCertificate { return $script:Certificate }
    function Invoke-RestMethod($Method, $Uri, $ContentType, $Body, $TimeoutSec) {
        [void]$Fake.Uris.Add($Uri)
        if ($Fake.DiscordStatus) { throw [FakeHttpException]::new('Discord error', $Fake.DiscordStatus) }
        [void]$Fake.Messages.Add(([Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json))
    }
    function New-ScheduledTaskAction { return "action $args" }
    function New-ScheduledTaskTrigger { return "trigger $args" }
    function Register-ScheduledTask { $script:Registered = $args -join ' ' }

    function Last-Message { return $Fake.Messages[$Fake.Messages.Count - 1].content }
    function Invoke-Health { $script:Passed = Invoke-HealthCheck 6> $null; return $script:Passed }
    function Assert-Ok { $passed = Invoke-Health; Assert $passed "A check failed: $($script:HealthProblems -join '; ')" }
    function Assert-Problem($Text) {
        $passed = Invoke-Health
        Assert (-not $passed) "Expected a failed check: $Text"
        Assert (($script:HealthProblems -join "`n").Contains($Text)) "Expected the problem: $Text`nGot: $($script:HealthProblems -join '; ')"
    }
    function Get-SavedFailures { return @(Get-Content $HealthState -Raw | ConvertFrom-Json) -join ',' }

    New-Item -ItemType Directory (Join-Path $NightlyRoot '20261023-040000-000') | Out-Null
    Set-Content $CloudflareLog "$(Get-Date -Format s) The website accepts only Cloudflare's 22 address ranges."
    Set-Content $BackupScript '# backup'

    # ---------------------------------------------------------------- the installed command

    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = $Webhook }
    $output = Write-HealthCommand 6>&1 | Out-String
    $command = Get-Content $HealthScript -Raw
    $null = [scriptblock]::Create($command)
    foreach ($name in 'Invoke-HealthCheck', 'Send-Discord', 'Get-HealthChecks', 'Test-HealthEmulator', 'Test-HealthCloudflare', 'Sql', 'Get-HotelCertificate', 'Write-Log', 'Write-Utf8') {
        Assert ($command -match "(?m)^function $name \{") "The health command misses $name"
    }
    Assert ($command.Contains("`$HealthState = '$HealthState'")) 'The health command misses its state file'
    Assert (-not $command.Contains($Webhook)) 'The health command holds the webhook'
    Assert ($command -cmatch '^[\x00-\x7F]*$') 'The health command is not plain ASCII, which Windows PowerShell 5.1 misreads'
    Assert ($script:Registered -like '*PlusEMU health check*') 'The health task was not registered'
    Assert ($output.Contains('Discord alerts are on')) "Output: $output"
    # The webhook was just saved: one message tells the owner that alerts work.
    Assert ($Fake.Messages.Count -eq 1 -and (Last-Message).Contains('Health alerts for **Example** are on')) "Messages: $($Fake.Messages.Count)"
    Assert ($Fake.Uris[0] -eq $Webhook) "Sent to $($Fake.Uris[0])"
    Invoke-Answers
    Write-HealthCommand *> $null
    Assert ($Fake.Messages.Count -eq 1) 'A rerun sent the first message again'

    # Everything works: no message, a log line.
    Assert-Ok
    Assert ((Get-Content $HealthLog -Raw).Contains('OK: all 10 checks passed.')) 'The health log misses the result'
    Assert ($Fake.Messages.Count -eq 1) 'A healthy run sent a message'
    Assert ((Get-SavedFailures) -eq '') "Saved: $(Get-SavedFailures)"

    # One failure sends one message, and a repeat of the same failure sends nothing.
    [void]$Fake.Down.Add('PlusEMU')
    Assert-Problem 'The emulator service: The PlusEMU service is not running.'
    Assert ($Fake.Messages.Count -eq 2) "Messages: $($Fake.Messages.Count)"
    Assert ((Last-Message).Contains("The emulator service does not work. The PlusEMU service is not running. Look at it with: ``Get-Content")) "Message: $(Last-Message)"
    Assert ((Get-SavedFailures) -eq 'Emulator') "Saved: $(Get-SavedFailures)"
    Assert-Problem 'The emulator service'
    Assert-Problem 'The emulator service'
    Assert ($Fake.Messages.Count -eq 2) 'A repeated failure sent another message'

    # The recovery sends one more message, then nothing.
    [void]$Fake.Down.Remove('PlusEMU')
    Assert-Ok
    Assert ($Fake.Messages.Count -eq 3 -and (Last-Message).Contains('The emulator service works again.')) "Recovery: $(Last-Message)"
    Assert-Ok
    Assert ($Fake.Messages.Count -eq 3) 'A healthy run after the recovery sent a message'

    # Two failures in one run share one message.
    [void]$Fake.Down.Add('2096'); [void]$Fake.Down.Add('MariaDB')
    Assert-Problem 'Nothing answers on port 2096.'
    Assert (($script:HealthProblems -join "`n").Contains('The database (MariaDB): MariaDB does not answer.')) 'The database failure was not found'
    Assert ($Fake.Messages.Count -eq 4 -and (Last-Message) -match '(?s)port 2096\) does not work.*MariaDB\) does not work') "Message: $(Last-Message)"
    [void]$Fake.Down.Remove('2096'); [void]$Fake.Down.Remove('MariaDB')
    Assert-Ok
    Assert ($Fake.Messages.Count -eq 5) "Messages: $($Fake.Messages.Count)"

    # Many failures at once still fit in one Discord message.
    foreach ($name in 'PlusEMU', '2096', '8080', 'W3SVC', 'MariaDB') { [void]$Fake.Down.Add($name) }
    $Fake.Website = '000'; $Fake.FreeMb = 100
    Move-Item $CloudflareLog "$CloudflareLog.saved"
    Assert-Problem 'The website'
    Assert ($Fake.Messages.Count -eq 6 -and (Last-Message).Length -lt 2000) "Long message: $((Last-Message).Length)"
    foreach ($label in 'The emulator service', 'The game connection (port 2096)', 'The emulator API (port 8080)', 'The web server (IIS)', 'The website', 'The database (MariaDB)', 'Free disk space', 'The Cloudflare address refresh') {
        Assert ((Last-Message).Contains("$label does not work.")) "The message misses: $label"
    }
    $Fake.Down.Clear(); $Fake.Website = '200'; $Fake.FreeMb = 40000
    Move-Item "$CloudflareLog.saved" $CloudflareLog
    Assert-Ok
    Assert ($Fake.Messages.Count -eq 7) "Messages: $($Fake.Messages.Count)"

    # Discord does not take the message: the next run sends it, once.
    $Fake.DiscordStatus = 500
    [void]$Fake.Down.Add('W3SVC')
    Assert-Problem 'The web server (IIS)'
    Assert ((Get-Content $HealthLog -Raw).Contains('Could not tell Discord what changed: Discord answered with HTTP status 500')) 'The failed message was not logged'
    Assert ((Get-SavedFailures) -eq '') 'The state changed although Discord did not take the message'
    $Fake.DiscordStatus = 0
    Assert-Problem 'The web server (IIS)'
    Assert ($Fake.Messages.Count -eq 8 -and (Last-Message).Contains('The web server (IIS) does not work')) "Message: $(Last-Message)"
    Assert-Problem 'The web server (IIS)'
    Assert ($Fake.Messages.Count -eq 8) 'The retried message was sent twice'
    [void]$Fake.Down.Remove('W3SVC')
    Assert-Ok

    # Each check finds its own problem.
    [void]$Fake.Down.Add('8080')
    Assert-Problem 'The emulator API (port 8080): Nothing answers on port 8080.'
    [void]$Fake.Down.Remove('8080')
    $Fake.Website = '502'
    Assert-Problem 'The website: https://example.com answers with error 502 on this server.'
    $Fake.Website = '000'
    Assert-Problem 'https://example.com does not answer on this server.'
    $Fake.Website = '302'
    Assert-Ok
    $Fake.FreeMb = 1500
    Assert-Problem 'Only 1500 MB is free'
    $Fake.FreeMb = 40000
    $script:Certificate = [pscustomobject]@{ NotAfter = (Get-Date).AddDays(10) }
    Assert-Problem 'The HTTPS certificate: The certificate on the HTTPS binding of example.com expires within 30 days'
    $script:Certificate = $null
    Assert-Problem 'The HTTPS certificate'
    $script:Certificate = [pscustomobject]@{ NotAfter = (Get-Date).AddYears(10) }
    Assert-Ok

    # The newest backup must be younger than 36 hours; a new hotel waits for its first night.
    $backup = Get-Item (Join-Path $NightlyRoot '20261023-040000-000')
    $backup.LastWriteTime = (Get-Date).AddHours(-37)
    Assert-Problem 'The nightly backup: The newest nightly backup'
    New-Item -ItemType Directory (Join-Path $NightlyRoot '20261024-040000-000.partial') | Out-Null
    Assert-Problem 'The nightly backup'
    New-Item -ItemType Directory (Join-Path $NightlyRoot '20261024-040000-001') | Out-Null
    Assert-Ok
    Get-ChildItem $NightlyRoot | Remove-Item -Recurse -Force
    Assert-Ok
    (Get-Item $BackupScript).LastWriteTime = (Get-Date).AddHours(-37)
    Assert-Problem 'The nightly backup'
    New-Item -ItemType Directory (Join-Path $NightlyRoot '20261024-040000-001') | Out-Null
    Assert-Ok

    # The last Cloudflare refresh must have worked within 8 days.
    Add-Content $CloudflareLog "$(Get-Date -Format s) Cloudflare's addresses were not updated, so the firewall was left as it is: offline"
    Assert-Problem "The Cloudflare address refresh: The last refresh did not work: "
    Add-Content $CloudflareLog "$(Get-Date -Format s) The website accepts only Cloudflare's 22 address ranges."
    Assert-Ok
    (Get-Item $CloudflareLog).LastWriteTime = (Get-Date).AddDays(-9)
    Assert-Problem 'older than 8 days'
    Remove-Item $CloudflareLog
    Assert-Problem 'The refresh never ran.'
    Set-Content $CloudflareLog "$(Get-Date -Format s) The website accepts only Cloudflare's 22 address ranges."
    Assert-Ok

    # An update holds the lock: the run is skipped and remembers nothing.
    [void]$Fake.Down.Add('PlusEMU')
    $before = $Fake.Messages.Count
    $update = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert-Ok } finally { $update.Dispose() }
    Assert ((Get-Content $HealthLog -Tail 1).Contains('Skipped: an update')) 'A locked run was not skipped'
    Assert ($Fake.Messages.Count -eq $before -and (Get-SavedFailures) -eq '') 'A skipped run sent or saved something'
    [void]$Fake.Down.Remove('PlusEMU')

    # The messages and the logs hold no passwords, and the webhook is in no log.
    foreach ($secret in $state.AdminPassword, $state.DbPassword, $state.DbRootPassword) {
        Assert (-not (($Fake.Messages | ConvertTo-Json -Depth 5).Contains($secret))) 'A message holds a password'
        Assert (-not (Get-Content $HealthLog -Raw).Contains($secret)) 'The health log holds a password'
    }
    foreach ($log in $InstallLog, $HealthLog) {
        Assert (-not ((Get-Content $log -Raw).Contains($Webhook))) "The webhook is in $log"
    }
    Assert (@($Fake.Messages[-1].allowed_mentions.parse).Count -eq 0 -and $Fake.Messages[-1].username -eq 'PlusEMU') 'Messages may mention people'

    # ---------------------------------------------------------------- without a webhook

    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = 'off' }
    $output = Write-HealthCommand 6>&1 | Out-String
    Assert ($output.Contains('Discord alerts are off')) "Output: $output"
    $before = $Fake.Messages.Count
    [void]$Fake.Down.Add('PlusEMU')
    Assert-Problem 'The emulator service'
    Assert ((Get-Content $HealthLog -Raw).Contains('PROBLEM: The emulator service')) 'The problem was not logged'
    Assert ((Get-SavedFailures) -eq 'Emulator') 'The failure was not remembered'
    [void]$Fake.Down.Remove('PlusEMU')
    Assert-Ok
    Assert ($Fake.Messages.Count -eq $before) 'A hotel without a webhook sent a message'

    # The first message fails: the installer warns and goes on.
    $Fake.DiscordStatus = 404
    Invoke-Answers -Environment @{ PLUSEMU_DISCORD_WEBHOOK = $Webhook }
    $output = Write-HealthCommand 6>&1 | Out-String
    Assert ($output.Contains('Could not send the first message to Discord: Discord answered with HTTP status 404')) "Output: $output"
    $Fake.DiscordStatus = 0

    # The installer runs the check once at the end and lists what does not work.
    [void]$Fake.Down.Add('PlusEMU')
    $output = Invoke-InstallHealthCheck 6>&1 | Out-String
    Assert ($output.Contains('Health check: something does not work yet:') -and $output.Contains('The emulator service: The PlusEMU service is not running.')) "Output: $output"
    Write-Host 'PowerShell health check checks passed'
} finally {
    foreach ($name in 'PLUSEMU_DOMAIN', 'PLUSEMU_WS_URL', 'PLUSEMU_HOTEL_NAME', 'PLUSEMU_ADMIN_USER', 'PLUSEMU_ADMIN_EMAIL', 'PLUSEMU_YES', 'PLUSEMU_GUIDE_MODE', 'PLUSEMU_DISCORD_WEBHOOK') {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    Remove-Item $testDir -Recurse -Force
}
