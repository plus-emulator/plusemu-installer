# PlusEMU hotel installer for Windows Server 2019/2022/2025 (IIS).
#
#   Open PowerShell as Administrator and run:
#   irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
#
# To try the hotel on your own Windows 10/11 PC only, at http://localhost: .\install.ps1 -Local
# (or $env:PLUSEMU_LOCAL = '1'). A local install asks no domain and leaves the PC's own settings alone.
#
# Installs and wires together: PlusEMU (emulator, as a Windows service) and Volt
# (client) from their latest GitHub releases, Atom CMS (website), MariaDB, PHP,
# IIS and the hotel files. Everything is self-hosted on this server; Cloudflare
# sits in front. Safe to run again: settings are reused and finished steps are kept.
#
# Unattended runs can preset the answers: PLUSEMU_DOMAIN, PLUSEMU_WS_URL,
# PLUSEMU_HOTEL_NAME, PLUSEMU_ADMIN_USER, PLUSEMU_ADMIN_EMAIL, PLUSEMU_YES=1.
# PLUSEMU_GUIDE_MODE=simple|advanced selects the final instructions only.
# PLUSEMU_CLOUDFLARE_TOKEN sets up Cloudflare with that API token; it is never saved.
# PLUSEMU_DISCORD_WEBHOOK sends health alerts to that Discord webhook ("off" turns them off).
#
# Update an installed hotel (PlusEMU, the Volt client and the hotel files) later with:
#   plusemu-update [-Check] [-Yes] [-Assets] [-Rollback]
# or, when that command is missing, with the installer itself:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1))) -Update
# -WithAssets is accepted for older instructions and ignored: the hotel files are always part of an update.

param([string]$GuideMode, [switch]$Local, [switch]$Update, [switch]$Check, [switch]$Yes, [switch]$Rollback, [switch]$Assets, [switch]$WithAssets)

function Get-Setting($Name, $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value } else { return $Default }
}

function Resolve-GuideMode($SavedMode = 'simple') {
    $choice = if ($GuideMode) { $GuideMode } else { Get-Setting 'PLUSEMU_GUIDE_MODE' $SavedMode }
    if (-not $choice) { $choice = 'simple' }
    if ($choice -notin 'simple', 'advanced') {
        throw 'Guide mode must be simple or advanced (this selects instructions only).'
    }
    return $choice.ToLowerInvariant()
}

$null = Resolve-GuideMode

$InstallerRepo   = Get-Setting 'INSTALLER_REPO' 'plus-emulator/plusemu-installer'
$InstallerRef    = Get-Setting 'INSTALLER_REF' 'main'
$AssetPackUrl    = Get-Setting 'ASSET_PACK_URL' 'https://github.com/plus-emulator/plusemu-installer/releases/download/hotel-files/hotel-files.tar.gz'
$EmulatorRepo    = 'plus-emulator/PlusEMU'
$ClientRepo      = 'plus-emulator/Volt'
# Set to install a build from another place instead of the latest release (recorded as version "custom").
$EmulatorUrl     = Get-Setting 'EMULATOR_URL' ''
$ClientUrl       = Get-Setting 'CLIENT_URL' ''
$AtomRepo        = Get-Setting 'ATOM_REPO' 'https://github.com/atom-projects/atom-cms.git'
# "auto" picks the Atom CMS that matches the downloaded emulator's database (see Get-Releases).
$AtomRef         = Get-Setting 'ATOM_REF' 'auto'

$HotelRoot  = 'C:\Hotel'
$StateDir   = 'C:\ProgramData\PlusEMU'
$StateFile  = "$StateDir\hotel.json"
$VersionsFile  = Join-Path $StateDir 'versions.json'
$BackupRoot    = Join-Path $StateDir 'backups'
$UpdateCommand = Join-Path $StateDir 'plusemu-update.ps1'
$CleanupScript = Join-Path $StateDir 'plusemu-cleanup.ps1'
$NightlyRoot   = Join-Path $BackupRoot 'nightly'
$BackupScript  = Join-Path $StateDir 'plusemu-backup.ps1'
$BackupLog     = Join-Path $StateDir 'backup.log'
$KeepNightly   = 7
$BackupLockWait = 3600
$CloudflareScript = Join-Path $StateDir 'plusemu-cloudflare-ips.ps1'
$CloudflareLog  = Join-Path $StateDir 'cloudflare-ips.log'
$HealthScript   = Join-Path $StateDir 'plusemu-health.ps1'
$HealthLog      = Join-Path $StateDir 'health.log'
$HealthState    = Join-Path $StateDir 'health.json'
$CloudflareApi  = 'https://api.cloudflare.com/client/v4'
$OriginCaRootUrl = 'https://developers.cloudflare.com/ssl/static/origin_ca_rsa_root.pem'
$UpdateLog     = Join-Path $StateDir 'update.log'
$LockFile      = Join-Path $StateDir 'update.lock'
$KeepBackups   = 3
$Downloads  = Join-Path $env:TEMP 'plusemu-downloads'
$script:Log        = "$StateDir\install.log"
$PhpDir     = 'C:\PHP'
$NodeMajor  = 22
$MariaDbSeries = '11.4'
$script:TotalSteps = 12
$script:Step = 0

# `irm | iex` runs in the user's own session, so these are restored at the end.
$SessionPreferences = @{ ErrorAction = $ErrorActionPreference; Progress = $ProgressPreference }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with its progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- output

function Write-Log($Text) { Add-Content -Path $script:Log -Value $Text -Encoding UTF8 }
function Say($Text, $Color = 'Gray') { Write-Host $Text -ForegroundColor $Color; Write-Log $Text }
function Step($Text) {
    $script:Step++
    Write-Host ''
    Write-Host "[$script:Step/$script:TotalSteps] " -ForegroundColor Cyan -NoNewline
    Write-Host $Text -ForegroundColor White
    Write-Log "`n[$script:Step/$script:TotalSteps] $Text"
}
function Ok($Text) { Say "      + $Text" 'Green' }

function Ask($Question, $Default) {
    if ((Get-Setting 'PLUSEMU_YES' '0') -eq '1') {   # unattended: take the default
        if (-not $Default) { throw "No answer for `"$Question`". Preset the PLUSEMU_* answers for an unattended run." }
        return $Default
    }
    $prompt = "  $Question"
    if ($Default) { $prompt += " [$Default]" }
    $answer = Read-Host $prompt
    if ($answer) { return $answer.Trim() } else { return $Default }
}

# Runs a program, sends its output to the log and stops the installer when it fails.
function Run {
    param([string]$Exe, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Write-Log "> $Exe $($Arguments -join ' ')"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # native stderr is not an error by itself
    & $Exe @Arguments 2>&1 | ForEach-Object { Add-Content -Path $script:Log -Value "$_" -Encoding UTF8 }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "'$Exe $($Arguments -join ' ')' failed with exit code $code" }
}

# Runs curl.exe and returns its exit code and standard output (for -w values).
function Invoke-Curl([string[]]$Arguments) {
    Write-Log "> curl.exe $($Arguments -join ' ')"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # the progress bar is written to stderr
    $output = & curl.exe @Arguments
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return @{ Code = $code; Output = (@($output) -join '') }
}

# Runs tar.exe, logs its output and returns its exit code.
function Invoke-Tar([string[]]$Arguments) {
    Write-Log "> tar.exe $($Arguments -join ' ')"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & tar.exe @Arguments 2>&1 | ForEach-Object { Add-Content -Path $script:Log -Value "$_" -Encoding UTF8 }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return $code
}

function Download($Url, $File) {
    if ((Invoke-Curl @('-fsSL', '--retry', '3', '-o', $File, $Url)).Code -ne 0) { throw "Download failed: $Url" }
}

function Install-Msi($File, [string[]]$Properties = @()) {
    $arguments = @('/i', "`"$File`"", '/qn', '/norestart') + $Properties
    $process = Start-Process msiexec.exe -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -notin 0, 1638, 3010) { throw "Installing $File failed with exit code $($process.ExitCode)" }
}

function Update-Path {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($script:LocalNode) { $env:Path = "$script:LocalNode;$env:Path" }
}

function Add-MachinePath($Dir) {
    $path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($path -split ';') -notcontains $Dir) { [Environment]::SetEnvironmentVariable('Path', "$path;$Dir", 'Machine') }
    Update-Path
}

function New-Secret($Length) {
    $chars = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] $Length
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Atom requires at least 12 characters, mixed case, a number and a symbol.
# Keep the 16 random characters; database passwords remain alphanumeric.
function New-AdminPassword { return (New-Secret 16) + 'Aa1!' }

function Repair-AdminPassword {
    # Only called while CMS setup is incomplete; never rotate an installed login.
    $password = $state.AdminPassword
    if ($password.Length -lt 12 -or $password -cnotmatch '[A-Z]' -or
        $password -cnotmatch '[a-z]' -or $password -notmatch '[0-9]' -or
        $password -notmatch '[^a-zA-Z0-9\s]') {
        $state.AdminPassword = New-AdminPassword
        $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        Say "  Replaced the saved admin password to meet Atom's requirements. Saved in $StateFile."
    }
}

function Write-Utf8($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false)) }

function Render($Template, $Output, $Values, $CertificateTemplate = $null) {
    $content = [IO.File]::ReadAllText($Template)
    $certificateSteps = if ($CertificateTemplate) { [IO.File]::ReadAllText($CertificateTemplate) } else { '' }
    $content = $content.Replace('{{CERTIFICATE_STEPS}}', $certificateSteps)
    foreach ($key in $Values.Keys) { $content = $content.Replace("{{$key}}", [string]$Values[$key]) }
    Write-Utf8 $Output $content
}

function Set-EnvValue($File, $Key, $Value) {
    $line = "$Key=`"$($Value.Replace('\', '\\').Replace('"', '\"'))`""
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($File))
    $index = $lines.FindIndex([Predicate[string]] { param($l) $l.StartsWith("$Key=") })
    if ($index -ge 0) { $lines[$index] = $line } else { $lines.Add($line) }
    [IO.File]::WriteAllLines($File, $lines, (New-Object Text.UTF8Encoding $false))
}

function Clone($Repo, $Ref, $Dir) {
    # Shallow checkout of exactly that branch or commit.
    if (-not (Test-Path "$Dir\.git")) {
        if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
        Run git init -q $Dir
        Run git -C $Dir remote add origin $Repo
    }
    Run git -C $Dir fetch --depth 1 origin $Ref
    Run git -C $Dir reset -q --hard FETCH_HEAD
}

function Find-MariaDb {
    return Get-ChildItem "$env:ProgramFiles\MariaDB*\bin\mariadb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}

function Get-MariaDb {
    if (-not $script:MariaDb) { $script:MariaDb = Find-MariaDb }
    if (-not $script:MariaDb) { throw 'MariaDB was not found. Run the installer first.' }
    return $script:MariaDb
}

function Sql([string]$Query, [string]$Database = '') {
    # Local connections skip TLS: MariaDB 11.4 verifies the certificate it generated for itself, which expires.
    $arguments = @('-uroot', '--skip-ssl', '-N', '-e', $Query)
    if ($Database) { $arguments += $Database }
    $mariadb = Get-MariaDb
    $env:MYSQL_PWD = $state.DbRootPassword
    $ErrorActionPreference = 'Continue'   # native stderr is not an error by itself
    $result = & $mariadb @arguments 2>> $script:Log
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Remove-Item Env:\MYSQL_PWD
    if ($code -ne 0) { throw "A database command failed (exit code $code). See $script:Log" }
    return $result
}

function Import-Database($File) {
    $env:MYSQL_PWD = $state.DbRootPassword
    & cmd.exe /c "`"$(Get-MariaDb)`" -uroot --skip-ssl plus < `"$File`" 2>> `"$script:Log`""
    $code = $LASTEXITCODE
    Remove-Item Env:\MYSQL_PWD
    if ($code -ne 0) { throw "Importing the database failed (exit code $code). See $script:Log" }
}

function Read-Versions {
    $script:Versions = [ordered]@{ EmulatorVersion = 'unknown'; ClientVersion = 'unknown'; AssetsVersion = 'unknown' }
    if (-not (Test-Path $VersionsFile)) { return }
    $saved = Get-Content $VersionsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @($script:Versions.Keys)) {
        if ($saved.$name) { $script:Versions[$name] = [string]$saved.$name }
    }
}

function Save-Versions {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Write-Utf8 $VersionsFile ([pscustomobject]$script:Versions | ConvertTo-Json)
}

# The tag of the newest release, read from where the "latest" page redirects to.
function Get-ReleaseVersion($Repo, $CustomUrl) {
    if ($CustomUrl) { return 'custom' }
    $headers = Join-Path $Downloads 'latest.tmp'
    $result = Invoke-Curl @('-fsSI', '--retry', '3', '-o', $headers, '-w', '%{redirect_url}', "https://github.com/$Repo/releases/latest")
    Remove-Item $headers -ErrorAction SilentlyContinue
    $marker = '/releases/tag/'
    if ($result.Code -ne 0 -or $result.Output -notlike "*$marker*") { return $null }
    return $result.Output.Substring($result.Output.LastIndexOf($marker) + $marker.Length)
}

function Get-PublishedHash($SumsFile, $Asset) {
    foreach ($line in Get-Content $SumsFile) {
        if ($line -match '^([0-9A-Fa-f]{64})\s+\*?(.+)$' -and $Matches[2] -eq $Asset) { return $Matches[1] }
    }
    return $null
}

# Downloads $Base/$Asset and checks it against the SHA256SUMS next to it, when there is one.
# Returns $false when the asset is not there, and stops on a wrong checksum.
function Get-CheckedDownload($Base, $Asset, $File) {
    $options = @('-fsSL', '--retry', '3')
    if ($Asset -eq (Get-PackLocation).Name) { $options = @('-fL', '--retry', '3', '--progress-bar') }
    if ((Invoke-Curl ($options + @('-o', $File, "$Base/$Asset"))).Code -ne 0) { return $false }
    $sums = "$File.sums"
    $status = (Invoke-Curl @('-sSL', '--retry', '3', '-o', $sums, '-w', '%{http_code}', "$Base/SHA256SUMS")).Output
    $expected = $null
    if ($status -eq '200') { $expected = Get-PublishedHash $sums $Asset }
    Remove-Item $sums -ErrorAction SilentlyContinue
    if ($status -eq '404') { return $true }   # older releases publish no checksums
    if ($status -ne '200') { throw "Could not download the checksums for $Asset. Nothing was changed. Try again later." }
    if (-not $expected -or (Get-FileHash $File -Algorithm SHA256).Hash -ne $expected.ToUpper()) {
        throw "The download of $Asset does not match its published checksum. Nothing was changed. Try again later."
    }
    return $true
}

function Get-PackLocation {
    $cut = $AssetPackUrl.LastIndexOf('/')
    return @{ Base = $AssetPackUrl.Substring(0, $cut); Name = $AssetPackUrl.Substring($cut + 1) }
}

# The start of the hotel files pack's published checksum, "custom" when it has none, or $null when it cannot be read.
function Get-PackVersion {
    $pack = Get-PackLocation
    $sums = Join-Path $Downloads 'pack.sums'
    $status = (Invoke-Curl @('-sSL', '--retry', '3', '-o', $sums, '-w', '%{http_code}', "$($pack.Base)/SHA256SUMS")).Output
    $version = $null
    if ($status -eq '200') {
        $hash = Get-PublishedHash $sums $pack.Name
        if ($hash) { $version = $hash.Substring(0, 12).ToLower() }
    } elseif ($status -eq '404') {
        $version = 'custom'
    }
    Remove-Item $sums -ErrorAction SilentlyContinue
    return $version
}

function Expand-EmulatorRelease($Version, $Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $file = Join-Path $Downloads 'plusemu.zip'
    if ($EmulatorUrl) {
        Download $EmulatorUrl $file
    } elseif (-not (Get-CheckedDownload "https://github.com/$EmulatorRepo/releases/download/$Version" 'plusemu-win-x64.zip' $file)) {
        throw "Could not download PlusEMU $Version. Nothing was changed. Try again later."
    }
    Expand-Archive $file $Dir -Force
    Remove-Item $file
    if (-not (Test-Path (Join-Path $Dir 'Plus Emulator.exe'))) { throw "The PlusEMU $Version download is incomplete. Nothing was changed. Try again later." }
}

function Expand-ClientRelease($Version, $Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $file = Join-Path $Downloads 'volt-client.zip'
    $base = "https://github.com/$ClientRepo/releases/download/$Version"
    if ($ClientUrl) {
        Download $ClientUrl $file
    } elseif (-not ((Get-CheckedDownload $base 'volt-client.zip' $file) -or (Get-CheckedDownload $base 'octane-client.zip' $file))) {
        # Client releases made before the Volt rename ship the same build as octane-client.zip.
        throw "Could not download Volt $Version. Nothing was changed. Try again later."
    }
    Expand-Archive $file $Dir -Force
    Remove-Item $file
    if (-not (Test-Path (Join-Path $Dir 'index.html'))) { throw "The Volt $Version download is incomplete. Nothing was changed. Try again later." }
}

function Write-UpdateCommand {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Write-Utf8 $UpdateCommand @"
# Installed by the PlusEMU installer. Updates PlusEMU, the Volt client and the hotel files with the newest installer:
#   plusemu-update [-Check] [-Yes] [-Assets] [-Rollback]
# When this file is missing, run the update once from the installer itself (Administrator PowerShell):
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1))) -Update
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$script = Invoke-RestMethod 'https://raw.githubusercontent.com/$InstallerRepo/$InstallerRef/install.ps1'
& ([scriptblock]::Create(`$script)) -Update @args
"@
    Add-MachinePath $StateDir
}

# ---------------------------------------------------------------- steps

function Assert-Administrator {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Please run PowerShell as Administrator (right-click PowerShell > Run as administrator).' }
}

function Test-Prerequisites {
    Assert-Administrator
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is required.' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) { throw 'Windows Server 2019 or newer is required (Windows 10 version 1809 or newer, or Windows 11, for a local install).' }
    $free = (Get-PSDrive C).Free / 1GB
    if ($free -lt 15) { throw "Not enough disk space on C: ($([int]$free) GB free, at least 15 GB needed)." }
    New-Item -ItemType Directory -Force -Path $StateDir, $HotelRoot, $Downloads | Out-Null
    # Only administrators may read the passwords and the log.
    & icacls.exe $StateDir /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not protect $StateDir." }
    Set-Content -Path $script:Log -Value "PlusEMU installer log $(Get-Date -Format s)" -Encoding UTF8
}

function Get-InstallerFiles {
    # Templates ship next to this script. When run through `irm | iex` there is
    # no script folder, so the matching installer release is downloaded.
    if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\templates\setup-guide.html")) {
        $script:Templates = "$PSScriptRoot\templates"
        return
    }
    $tmp = Join-Path $env:TEMP "plusemu-installer"
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Download "https://codeload.github.com/$InstallerRepo/zip/$InstallerRef" "$tmp\installer.zip"
    Expand-Archive "$tmp\installer.zip" $tmp
    $script:Templates = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName + '\templates'
}

function Test-DiscordWebhook($Url) { return "$Url" -cmatch '^https://(discord|discordapp)\.com/api/webhooks/[A-Za-z0-9._~/?=&-]+$' }

# Reruns keep the saved webhook unless PLUSEMU_DISCORD_WEBHOOK changes it; "off" removes it.
function Select-DiscordWebhook($Saved, [bool]$Asked) {
    $url = Get-Setting 'PLUSEMU_DISCORD_WEBHOOK' ''
    if ($url -eq 'off') { return '' }
    if (-not $url -and $Asked) { return "$Saved" }
    $unattended = (Get-Setting 'PLUSEMU_YES' '0') -eq '1'
    while ($true) {
        if (-not $url -and -not $unattended) {
            $url = "$(Read-Host '  Discord webhook URL for alerts when something is wrong with your hotel (optional, press Enter to skip)')" -replace '\s', ''
        }
        if (-not $url -or (Test-DiscordWebhook $url)) { return "$url" }
        Write-Host '  That is not a Discord webhook URL. It starts with https://discord.com/api/webhooks/' -ForegroundColor Yellow
        if ($unattended) { throw 'PLUSEMU_DISCORD_WEBHOOK is not a Discord webhook URL. Copy it again in Discord, or set it to off.' }
        $url = ''
    }
}

# CrowdSec reads the visitor's address from the web server log. IIS logs Cloudflare's address instead,
# so CrowdSec on Windows would block Cloudflare and cut off every player.
function Write-CrowdSecNote($Mode) {
    if ($Mode -eq 'advanced' -or (Get-Setting 'PLUSEMU_CROWDSEC' '') -eq '1') {
        Say '  CrowdSec: the Windows installer does not install it. IIS logs show Cloudflare''s address instead of the visitor''s, so CrowdSec would block Cloudflare instead of attackers. The Linux installer can install it.'
    }
}

# A saved hotel keeps its choice. Switching it would leave half a server on a PC, or a server without its protection.
function Resolve-Local($Saved = $null) {
    $requested = if ($Local) { '1' } else { Get-Setting 'PLUSEMU_LOCAL' '' }
    $choice = switch ($requested) {
        '1' { $true }
        '0' { $false }
        '' { [bool]$Saved }
        default { throw 'PLUSEMU_LOCAL must be 1 (install on this PC only) or 0 (install a server).' }
    }
    if ($null -ne $Saved -and $choice -ne [bool]$Saved) {
        if ($Saved) { throw 'This PC has a local hotel at http://localhost, and the installer cannot turn it into a server install. Nothing was changed. For a public hotel, run the installer without -Local on your server.' }
        throw "This server has a hotel for $($state.Domain), and the installer cannot turn it into a local install. Nothing was changed. Run the installer with -Local on another PC."
    }
    return $choice
}

function Read-ServerAddresses {
    $domain = Get-Setting 'PLUSEMU_DOMAIN' ''
    while ($true) {
        if (-not $domain) { $domain = Ask "Your hotel's domain name (for example myhotel.com)" '' }
        $domain = ($domain.ToLower() -replace '^[a-z]+://', '' -replace '/.*$', '' -replace '^www\.', '')
        if ($domain -match '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$') { break }
        Write-Host "  That doesn't look like a domain name. Type it like: myhotel.com" -ForegroundColor Yellow
        $domain = ''
    }

    Write-Host ''
    Write-Host '  The game connects through a WebSocket. Press Enter to use the recommended'
    Write-Host '  address on your own domain (no extra Cloudflare setup), or type your own,'
    Write-Host "  for example ws.$domain."
    $ws = Get-Setting 'PLUSEMU_WS_URL' ''
    while ($true) {
        if (-not $ws) { $ws = Ask 'WebSocket address' "wss://$domain/ws" }
        $ws = 'wss://' + ($ws -replace '^[a-zA-Z]+://', '')
        if ($ws -match '^wss://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[A-Za-z0-9._/-]*)?$') { break }
        Write-Host "  Type it like wss://$domain/ws or ws.$domain (no port)." -ForegroundColor Yellow
        $ws = ''
    }
    return $domain, $ws
}

function Read-Answers {
    $selectedMode = Resolve-GuideMode
    Write-Host ''
    Write-Host 'Welcome to the PlusEMU hotel installer!' -ForegroundColor White
    Write-Host 'This sets up your emulator, client and website on this server in about 10 minutes.'
    Write-Host ''

    if (Test-Path $StateFile) {
        $script:state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $isLocal = Resolve-Local ([bool]$state.Local)
        $selectedMode = Resolve-GuideMode $state.GuideMode
        if ($isLocal) {
            Say 'Found the settings of an earlier run on this PC (http://localhost); continuing that installation.'
            $script:DiscordWebhookNew = $false
            return
        }
        Say "Found the settings of an earlier run for $($state.Domain); continuing that installation."
        Say "  Setup guide: $selectedMode. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
        Write-CrowdSecNote $selectedMode
        $previous = "$($state.DiscordWebhook)"
        # An older state file has no answer for this, so the question is asked once.
        $webhook = Select-DiscordWebhook $state.DiscordWebhook ($null -ne $state.PSObject.Properties['DiscordWebhook'])
        $script:DiscordWebhookNew = [bool]($webhook -and $webhook -ne $previous)
        $state | Add-Member -MemberType NoteProperty -Name GuideMode -Value $selectedMode -Force
        $state | Add-Member -MemberType NoteProperty -Name DiscordWebhook -Value $webhook -Force
        $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        if ($webhook) {
            Say '  Health alerts are on: they go to your Discord webhook. To change it, run the installer again with $env:PLUSEMU_DISCORD_WEBHOOK set to the new URL, or to off to turn alerts off.'
        }
        return
    }

    $isLocal = Resolve-Local
    # The game connects through the same IIS site as the website, so the browser sees one origin.
    if ($isLocal) { $domain = 'localhost'; $ws = 'ws://localhost/ws' } else { $domain, $ws = Read-ServerAddresses }

    $suggested = if ($isLocal) { 'PlusEMU' } else { (Get-Culture).TextInfo.ToTitleCase($domain.Split('.')[0]) }
    $mailDomain = if ($isLocal) { 'localhost.test' } else { $domain }
    $name = Get-Setting 'PLUSEMU_HOTEL_NAME' ''
    if (-not $name) { $name = Ask 'Hotel name' $suggested }
    $name = $name -replace '[<>"`$\\'']', ''

    $user = Get-Setting 'PLUSEMU_ADMIN_USER' ''
    while ($true) {
        if (-not $user) { $user = Ask 'Username for your admin account' 'admin' }
        if ($user -match '^[A-Za-z0-9._-]{3,25}$') { break }
        Write-Host '  Use 3-25 letters, numbers, dots, dashes or underscores.' -ForegroundColor Yellow
        $user = ''
    }
    $mail = Get-Setting 'PLUSEMU_ADMIN_EMAIL' ''
    while ($true) {
        if (-not $mail) { $mail = Ask 'Email for your admin account' "admin@$mailDomain" }
        if ($mail -match '^[^@\s'']+@[^@\s'']+\.[^@\s'']+$') { break }
        Write-Host "  That doesn't look like an email address." -ForegroundColor Yellow
        $mail = ''
    }
    $webhook = if ($isLocal) { '' } else { Select-DiscordWebhook '' $false }
    $script:DiscordWebhookNew = [bool]$webhook

    Write-Host ''
    Write-Host "  Website:    $(if ($isLocal) { 'http://localhost' } else { "https://$domain" })"
    Write-Host "  WebSocket:  $ws"
    Write-Host "  Hotel name: $name"
    Write-Host "  Admin:      $user ($mail)"
    if ($isLocal) {
        Write-Host '  Local install: only this PC can open the hotel. There is no HTTPS and no Cloudflare.'
        Write-Host '  The firewall, Windows Update and the account settings of this PC stay as they are.'
    } else {
        Write-Host "  Setup guide: $selectedMode. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
        Write-Host "  Health alerts: $(if ($webhook) { 'Discord' } else { 'log only (no Discord webhook)' })"
        Write-CrowdSecNote $selectedMode
    }
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') {
        $go = Ask 'Start the installation? (y/n)' 'y'
        if ($go -notmatch '^[Yy]') { throw 'Installation cancelled. Nothing was changed.' }
    }

    $script:state = [pscustomobject]@{
        Domain = $domain; WsUrl = $ws; HotelName = $name; AdminUser = $user; AdminEmail = $mail
        GuideMode = $selectedMode; DiscordWebhook = $webhook; Local = $isLocal
        AdminPassword = New-AdminPassword; DbPassword = New-Secret 32; DbRootPassword = New-Secret 32
    }
    $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

# The program that listens on a port is the one the installer puts there. IIS listens through Windows itself (process 4).
function Test-HotelListener($Port, $Process) {
    if (-not $Process) { return $false }
    $path = "$($Process.Path)"
    switch ($Port) {
        80 { return $Process.Id -eq 4 }
        3306 { $mariadb = Find-MariaDb; return [bool]($mariadb -and $path -and $path.StartsWith($mariadb.Substring(0, $mariadb.Length - 'mariadb.exe'.Length), [StringComparison]::OrdinalIgnoreCase)) }
        default { return [bool]($path -and $path.StartsWith((Join-Path $HotelRoot 'emulator'), [StringComparison]::OrdinalIgnoreCase)) }
    }
}

# A PC often runs other web servers or databases. The hotel needs their ports, so the install stops before it changes anything.
function Assert-FreePorts {
    $busy = @()
    foreach ($port in 80, 3306, 2096, 8080, 30001) {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $listener) { continue }
        $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
        if (Test-HotelListener $port $process) { continue }
        $busy += "port $port is used by $(if ($process) { $process.ProcessName } else { 'another program' }) (process $($listener.OwningProcess))"
    }
    if ($busy) { throw "The hotel needs ports that another program uses: $($busy -join '; '). Stop that program (for example in Services or Task Manager), then run the installer again. Nothing was changed." }
}

function Get-Derived {
    $rest = $state.WsUrl.Substring($state.WsUrl.IndexOf('://') + 3)
    $script:WsHost = $rest.Split('/')[0]
    $script:WsPath = if ($rest.Contains('/')) { $rest.Substring($rest.IndexOf('/') + 1) } else { '' }
    if ($state.Local) { $script:ServerIp = '127.0.0.1'; return }
    try { $script:ServerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim() }
    catch { $script:ServerIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' } | Select-Object -First 1).IPAddress }
}

function Install-WebServer {
    Step 'Installing IIS with URL Rewrite, reverse proxy and WebSockets'
    # Windows 10 and 11 (product type 1) have no server roles; they offer IIS as optional features.
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
        $features = 'IIS-WebServerRole', 'IIS-WebServer', 'IIS-StaticContent', 'IIS-DefaultDocument', 'IIS-HttpErrors', 'IIS-HttpLogging',
                    'IIS-HttpCompressionStatic', 'IIS-HttpCompressionDynamic', 'IIS-RequestFiltering', 'IIS-CGI', 'IIS-WebSockets',
                    'IIS-ManagementConsole', 'IIS-ManagementScriptingTools'
        # The per-visitor limits need IP Security; a local install has no limits.
        if (-not $state.Local) { $features += 'IIS-IPSecurity' }
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $features -All -NoRestart
        if ($result.RestartNeeded) { Say '      Windows wants a restart to finish IIS. If a later step fails, restart the PC and run the installer again.' 'Yellow' }
    } else {
        $features = 'Web-Server', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Http-Logging',
                    'Web-Stat-Compression', 'Web-Dyn-Compression', 'Web-Filtering', 'Web-IP-Security', 'Web-CGI', 'Web-WebSockets', 'Web-Mgmt-Console'
        $result = Install-WindowsFeature -Name $features
        if (-not $result.Success) { throw 'Installing IIS failed.' }
    }
    Import-Module WebAdministration
    if (-not (Test-Path "$env:windir\System32\inetsrv\rewrite.dll")) {
        Download 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi' "$Downloads\rewrite.msi"
        Install-Msi "$Downloads\rewrite.msi"
    }
    if (-not (Test-Path "$env:ProgramFiles\IIS\Application Request Routing")) {
        Download 'https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi' "$Downloads\arr.msi"
        Install-Msi "$Downloads\arr.msi"
    }
    # The game's WebSocket is handed to the emulator through IIS's reverse proxy.
    # The emulator reads the last X-Forwarded-For entry as an address, so it carries no port.
    foreach ($setting in @(@('enabled', 'True'), @('xForwardedForHeaderName', 'X-Forwarded-For'), @('includePortInXForwardedFor', 'False'))) {
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name $setting[0] -Value $setting[1]
    }
    Ok 'IIS, URL Rewrite, Application Request Routing and WebSockets'
}

function Install-Toolchains {
    Step "Installing Git, Node.js $NodeMajor, PHP 8.5 and Composer (for the website)"
    Update-Path

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $release = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        $asset = $release.assets | Where-Object { $_.name -match '^Git-[\d.]+-64-bit\.exe$' } | Select-Object -First 1
        Download $asset.browser_download_url "$Downloads\git.exe"
        $process = Start-Process "$Downloads\git.exe" -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru
        if ($process.ExitCode -ne 0) { throw 'Installing Git failed.' }
        Update-Path
    }
    Ok "$(& git --version)"

    Install-NodeJs

    if (-not (Test-Path "$PhpDir\php-cgi.exe")) {
        # PHP needs the Visual C++ runtime.
        Download 'https://aka.ms/vs/17/release/vc_redist.x64.exe' "$Downloads\vc_redist.x64.exe"
        $process = Start-Process "$Downloads\vc_redist.x64.exe" -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
        if ($process.ExitCode -notin 0, 1638, 3010) { throw 'Installing the Visual C++ runtime failed.' }
        $releases = Invoke-RestMethod 'https://downloads.php.net/~windows/releases/releases.json'
        $build = $releases.'8.5'.'nts-vs17-x64'.zip
        Download "https://downloads.php.net/~windows/releases/$($build.path)" "$Downloads\php.zip"
        if ((Get-FileHash "$Downloads\php.zip" -Algorithm SHA256).Hash -ne $build.sha256.ToUpper()) { throw 'The PHP download is damaged. Run the installer again.' }
        Expand-Archive "$Downloads\php.zip" $PhpDir -Force
    }
    $ini = Get-Content "$PhpDir\php.ini-production" -Raw
    foreach ($extension in 'curl', 'fileinfo', 'gd', 'intl', 'mbstring', 'openssl', 'pdo_mysql', 'sockets', 'zip', 'sodium') {
        $ini = $ini -replace ";extension=$extension\b", "extension=$extension"
    }
    New-Item -ItemType Directory -Force -Path "$PhpDir\extras\ssl" | Out-Null
    if (-not (Test-Path "$PhpDir\extras\ssl\cacert.pem")) { Download 'https://curl.se/ca/cacert.pem' "$PhpDir\extras\ssl\cacert.pem" }
    $ini = $ini -replace ';extension_dir = "ext"', 'extension_dir = "ext"'
    $ini += "`r`n[PlusEMU]`r`nmemory_limit = 512M`r`nupload_max_filesize = 20M`r`npost_max_size = 20M`r`nopcache.enable = 1`r`nexpose_php = Off`r`n" +
            "curl.cainfo = `"$PhpDir\extras\ssl\cacert.pem`"`r`nopenssl.cafile = `"$PhpDir\extras\ssl\cacert.pem`"`r`n"
    Set-Content "$PhpDir\php.ini" $ini -Encoding ASCII
    Add-MachinePath $PhpDir
    Ok "PHP $(& "$PhpDir\php.exe" -r 'echo PHP_VERSION;')"

    if (-not (Test-Path "$PhpDir\composer.phar")) {
        Download 'https://getcomposer.org/download/latest-stable/composer.phar' "$PhpDir\composer.phar"
        $expected = ((Invoke-WebRequest 'https://getcomposer.org/download/latest-stable/composer.phar.sha256' -UseBasicParsing).Content -split '\s')[0]
        if ((Get-FileHash "$PhpDir\composer.phar" -Algorithm SHA256).Hash -ne $expected.ToUpper()) { Remove-Item "$PhpDir\composer.phar"; throw 'The Composer download is damaged. Run the installer again.' }
    }
    # Another PHP earlier on the PATH, as on many PCs, would run Composer without the hotel's extensions.
    Set-Content "$PhpDir\composer.bat" "@`"%~dp0php.exe`" `"%~dp0composer.phar`" %*" -Encoding ASCII
    Ok 'Composer'
}

function Install-NodeJs {
    if ($state.Local) {
        # The PC's own node and npm stay as they are: this copy is only on the installer's PATH.
        $script:LocalNode = Join-Path $StateDir 'node'
        Update-Path
    }
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -or -not ((& node --version) -like "v$NodeMajor.*")) {
        $base = "https://nodejs.org/dist/latest-v$NodeMajor.x"
        $sums = (Invoke-WebRequest "$base/SHASUMS256.txt" -UseBasicParsing).Content -split "`n"
        $package = if ($state.Local) { 'node-v[\d.]+-win-x64\.zip$' } else { 'node-v[\d.]+-x64\.msi$' }
        $line = $sums | Where-Object { $_ -match $package } | Select-Object -First 1
        $hash, $file = $line -split '\s+'
        Download "$base/$file" "$Downloads\$file"
        if ((Get-FileHash "$Downloads\$file" -Algorithm SHA256).Hash -ne $hash.ToUpper()) { throw 'The Node.js download is damaged. Run the installer again.' }
        if ($state.Local) {
            # Unpacked next to its final folder, because Windows moves a folder only within one drive.
            $unpacked = Join-Path $StateDir 'node-download'
            if (Test-Path $unpacked) { Remove-Item $unpacked -Recurse -Force }
            Expand-Archive "$Downloads\$file" $unpacked
            if (Test-Path $script:LocalNode) { Remove-Item $script:LocalNode -Recurse -Force }
            # The archive holds one folder, node-v<version>-win-x64.
            Move-Item ([IO.Directory]::GetDirectories($unpacked)[0]) $script:LocalNode
            Remove-Item $unpacked -Recurse -Force
        } else {
            Install-Msi "$Downloads\$file"
        }
        Update-Path
    }
    Ok "Node.js $(& node --version)"
}

function Install-Database {
    Step "Installing MariaDB $MariaDbSeries"
    $script:MariaDb = Find-MariaDb
    if (-not $MariaDb) {
        $latest = Invoke-RestMethod "https://downloads.mariadb.org/rest-api/mariadb/$MariaDbSeries/latest/"
        $release = $latest.releases.PSObject.Properties | Select-Object -First 1
        $msi = $release.Value.files | Where-Object { $_.file_name -match 'winx64\.msi$' } | Select-Object -First 1
        Download ($msi.file_download_url -replace '^http:', 'https:') "$Downloads\mariadb.msi"
        if ($msi.checksum.sha256sum -and (Get-FileHash "$Downloads\mariadb.msi" -Algorithm SHA256).Hash -ne $msi.checksum.sha256sum.ToUpper()) { throw 'The MariaDB download is damaged. Run the installer again.' }
        Install-Msi "$Downloads\mariadb.msi" @("PASSWORD=$($state.DbRootPassword)", 'SERVICENAME=MariaDB', 'PORT=3306', 'UTF8=1')
        $script:MariaDb = Find-MariaDb
        if (-not $MariaDb) { throw 'Installing MariaDB failed.' }
        # Only programs on this server may reach the database.
        $ini = Join-Path (Split-Path (Split-Path $MariaDb)) 'data\my.ini'
        $content = Get-Content $ini -Raw
        if ($content -notmatch 'bind-address') {
            Set-Content $ini ($content -replace '\[mysqld\]', "[mysqld]`r`nbind-address=127.0.0.1`r`nmax_allowed_packet=64M") -Encoding ASCII
            Restart-Service MariaDB
        }
    }
    Ok "MariaDB ($(Split-Path (Split-Path (Split-Path $MariaDb)) -Leaf))"
}

function Get-Releases {
    Step 'Downloading PlusEMU, the Volt client and Atom CMS'
    # A re-run repairs and keeps the installed releases; plusemu-update updates them.
    Read-Versions
    $out = Join-Path $HotelRoot 'emulator'
    if (Test-Path (Join-Path $out 'Plus Emulator.exe')) {
        Ok 'PlusEMU (already installed)'
    } else {
        $version = Get-ReleaseVersion $EmulatorRepo $EmulatorUrl
        if (-not $version) { throw "Could not find the latest PlusEMU release. Check the server's internet connection." }
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        Expand-EmulatorRelease $version $out
        $script:Versions.EmulatorVersion = $version
        Save-Versions
        Ok "PlusEMU $version"
    }

    $client = Join-Path $HotelRoot 'client'
    if (Test-Path (Join-Path $client 'index.html')) {
        Ok 'Volt client (already installed)'
    } else {
        $version = Get-ReleaseVersion $ClientRepo $ClientUrl
        if (-not $version) { throw "Could not find the latest Volt release. Check the server's internet connection." }
        $staged = "$client.new"
        if (Test-Path $staged) { Remove-Item $staged -Recurse -Force }
        Expand-ClientRelease $version $staged
        if (Test-Path $client) { Remove-Item $client -Recurse -Force }
        Move-Item $staged $client
        $script:Versions.ClientVersion = $version
        Save-Versions
        Ok "Volt client $version"
    }

    $atom = $AtomRef
    if ($atom -eq 'auto') {
        # Atom's dev branch reads user_currencies (PlusEMU migration 59); older emulator
        # releases need the last Atom commit before that.
        $atom = 'e9918ed69d4f255511623d69a47e9b2f8e200a28'
        if (Select-String -Path "$out\Database\FreshInstall.sql" -Pattern 'CREATE TABLE `user_currencies`' -SimpleMatch -Quiet) { $atom = 'dev' }
    }
    Clone $AtomRepo $atom "$HotelRoot\cms"
    Ok "Atom CMS ($($atom.Substring(0, [Math]::Min(12, $atom.Length))))"
}

# The address of the website, which the client, the game connection and the website itself are built from.
function Get-SiteUrl { if ($state.Local) { return 'http://localhost' } return "https://$($state.Domain)" }

function Write-ClientConfig($Dir = (Join-Path (Join-Path $HotelRoot 'client') 'configuration')) {
    # Newer emulators build FurnitureData.json from the furniture table; older ones need the static file.
    $furnidata = '${gamedata.url}/FurnitureData.json?t=%timestamp%'
    try {
        Invoke-WebRequest 'http://127.0.0.1:8080/api/gamedata/furnidata' -UseBasicParsing -TimeoutSec 30 | Out-Null
        $furnidata = "$(Get-SiteUrl)/api/gamedata/furnidata"
    } catch { }
    $values = @{ DOMAIN = $state.Domain; SITE_URL = Get-SiteUrl; SOCKET_URL = $state.WsUrl; FURNIDATA_URL = $furnidata }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    foreach ($file in 'renderer-config.json', 'ui-config.json', 'client-mode.json') {
        Render (Join-Path $Templates $file) (Join-Path $Dir $file) $values
    }
}

function Initialize-HotelDatabase {
    Step 'Creating the hotel database'
    $password = $state.DbPassword
    Sql "CREATE DATABASE IF NOT EXISTS plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER IF NOT EXISTS 'hotel'@'localhost' IDENTIFIED BY '$password'; ALTER USER 'hotel'@'localhost' IDENTIFIED BY '$password'; GRANT ALL PRIVILEGES ON plus.* TO 'hotel'@'localhost'; FLUSH PRIVILEGES;" | Out-Null
    # The import ends by filling server_status, so a missing or empty one means it never finished.
    $imported = '0'
    if ("$(Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'plus' AND table_name = 'server_status'")".Trim() -eq '1') {
        $imported = "$(Sql 'SELECT COUNT(*) FROM server_status' 'plus')".Trim()
    }
    if ($imported -eq '0') {
        Sql 'DROP DATABASE plus; CREATE DATABASE plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' | Out-Null
        Import-Database "$HotelRoot\emulator\Database\FreshInstall.sql"
        Ok "Imported the PlusEMU database ($("$(Sql 'SELECT COUNT(*) FROM furniture' 'plus')".Trim()) furniture types)"
    } else {
        Ok 'The database already exists; kept it as it is'
    }
}

function Get-HotelFiles {
    Step 'Downloading the hotel files (furniture, clothes, badges, texts; about 550 MB)'
    $files = Join-Path $HotelRoot 'hotel-files'
    Read-Versions
    $latest = Get-PackVersion
    if ($latest -and (Test-Path $files) -and $script:Versions.AssetsVersion -eq $latest) { Ok "Already downloaded (version $latest)"; return }
    if (-not $latest) { $latest = 'unknown' }
    New-Item -ItemType Directory -Force -Path $files | Out-Null
    $archive = Join-Path $Downloads 'hotel-files.tar.gz'
    $pack = Get-PackLocation
    if (-not (Get-CheckedDownload $pack.Base $pack.Name $archive)) { throw "Downloading the hotel files failed: $AssetPackUrl" }
    # Unpacked over the installed files, so files the owner added stay.
    if ((Invoke-Tar @('-xzf', $archive, '-C', $files)) -ne 0) { throw 'Unpacking the hotel files failed.' }
    Remove-Item $archive
    $script:Versions.AssetsVersion = $latest
    Save-Versions
    Ok 'Hotel files ready'
}

function Start-Emulator {
    Step 'Starting the emulator'
    $out = "$HotelRoot\emulator"
    $config = "$out\Config\config.json"
    $json = Get-Content $config -Raw -Encoding UTF8 | ConvertFrom-Json
    $json.Database.Hostname = '127.0.0.1'; $json.Database.Port = 3306; $json.Database.Username = 'hotel'
    $json.Database.Password = $state.DbPassword; $json.Database.Name = 'plus'
    $json.Flash.Hostname = '127.0.0.1'
    $json.Nitro.Hostname = '127.0.0.1'; $json.Nitro.Port = 2096; $json.Nitro.Name = 'Volt'
    $json.Rcon.Hostname = '127.0.0.1'; $json.Rcon.Port = 30001; $json.Rcon.AllowedAddresses = @('127.0.0.1', 'localhost')
    Write-Utf8 $config ($json | ConvertTo-Json -Depth 20)
    # Every packet is logged at Trace level by default, which floods the log.
    $nlog = "$out\Config\nlog.config"
    Write-Utf8 $nlog ((Get-Content $nlog -Raw) -replace 'minlevel="Trace"', 'minlevel="Info"')

    # Shawl runs the emulator as a Windows service: it starts with the server, restarts after a
    # crash, and on stop sends Ctrl+C so the emulator saves rooms and inventories before exiting.
    $shawl = "$out\service\shawl.exe"
    if (-not (Test-Path $shawl)) {
        Download 'https://github.com/mtkennerly/shawl/releases/download/v1.9.0/shawl-v1.9.0-win64.zip' "$Downloads\shawl.zip"
        Expand-Archive "$Downloads\shawl.zip" "$out\service" -Force
    }
    if (-not (Get-Service PlusEMU -ErrorAction SilentlyContinue)) {
        Run $shawl add --name PlusEMU --cwd $out --stop-timeout 30000 '--' "$out\Plus Emulator.exe"
        Run sc.exe config PlusEMU start= auto depend= MariaDB DisplayName= 'PlusEMU hotel emulator'
    }
    Restart-Service PlusEMU
    if (Wait-Emulator) { Ok 'The emulator is running (service: PlusEMU)'; return }
    throw "The emulator didn't start. See $out\service\shawl_for_PlusEMU_rCURRENT.log"
}

function Wait-Emulator {
    # Any HTTP answer from the emulator's web server means it has started; releases differ in their routes.
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-WebRequest 'http://127.0.0.1:8080/api/gamedata/furnidata/version' -UseBasicParsing -TimeoutSec 2 | Out-Null; $up = $true } catch { $up = $null -ne $_.Exception.Response }
        if ($up) { return $true }
        Start-Sleep 2
    }
    return $false
}

function Get-EmulatorProcesses {
    $folder = (Join-Path $HotelRoot 'emulator') + '\'
    return @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($folder, [StringComparison]::OrdinalIgnoreCase) })
}

function Stop-EmulatorService {
    Stop-Service PlusEMU
    # The service can report "stopped" while shawl or the emulator is still closing.
    for ($i = 0; $i -lt 30 -and (Get-EmulatorProcesses).Count; $i++) { Start-Sleep 2 }
    # Shawl only starts and stops the emulator. A shawl.exe left after the service stopped holds its own file, so it is ended.
    foreach ($process in Get-EmulatorProcesses | Where-Object Name -eq 'shawl.exe') {
        Write-Log "Ending shawl.exe (process $($process.ProcessId)), which still ran after the PlusEMU service stopped"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $process.ProcessId -Timeout 10 -ErrorAction SilentlyContinue
    }
    $running = Get-EmulatorProcesses
    if ($running.Count) {
        $names = ($running | ForEach-Object { "$($_.Name) (process $($_.ProcessId))" }) -join ', '
        throw "These programs still run from $(Join-Path $HotelRoot 'emulator') after the PlusEMU service stopped: $names. Close them (for example an emulator you started by hand), then run plusemu-update again."
    }
}

# Windows does not allow moving a folder while a program uses a file in it.
# A program that is still closing or a virus scanner can hold a file for a few seconds.
function Move-Folder($From, $To) {
    for ($i = 1; ; $i++) {
        try { Move-Item -LiteralPath $From $To; return }
        catch {
            Write-Log "Moving $From failed (try $i): $_"
            if ($i -ge 10) {
                throw "Windows did not allow moving $From, because a program still uses a file in it. Close every program and window that has this folder open (for example File Explorer, or a PowerShell window that is in this folder or follows the emulator log), then run plusemu-update again."
            }
            Start-Sleep 3
        }
    }
}

function Start-EmulatorService { Start-Service PlusEMU }

function Install-Cms {
    Step 'Installing the Atom CMS website'
    $cms = Join-Path $HotelRoot 'cms'
    $envFile = Join-Path $cms '.env'
    $site = Get-SiteUrl
    Push-Location $cms
    if (-not (Test-Path $envFile)) { Copy-Item .env.example $envFile }
    # Laravel trusts the visitor address Cloudflare forwards, but only from Cloudflare itself.
    $proxies = if ($state.Local) { @('127.0.0.1') } else {
        try { Get-CloudflareRanges }
        catch {
            @('173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20',
              '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13',
              '131.0.72.0/22', '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32', '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32')
        }
    }
    # http://localhost has no HTTPS, so Atom must not send visitors there or keep its cookies for HTTPS only.
    $https = if ($state.Local) { 'false' } else { 'true' }
    $settings = [ordered]@{
        APP_NAME = $state.HotelName; APP_ENV = 'production'; APP_DEBUG = 'false'; APP_URL = $site; LOG_LEVEL = 'warning'
        DB_CONNECTION = 'mariadb'; DB_HOST = '127.0.0.1'; DB_PORT = '3306'; DB_DATABASE = 'plus'; DB_USERNAME = 'hotel'; DB_PASSWORD = $state.DbPassword
        EMULATOR_DRIVER = 'plus'; CLIENT_NITRO_ENABLED = 'true'; NITRO_CLIENT_PATH = "$site/client"
        RCON_HOST = '127.0.0.1'; RCON_PORT = '30001'; FORCE_HTTPS = $https; SESSION_SECURE_COOKIE = $https
        TRUSTED_PROXIES = ($proxies -join ',')
    }
    foreach ($key in $settings.Keys) { Set-EnvValue $envFile $key $settings[$key] }

    $env:COMPOSER_ALLOW_SUPERUSER = '1'; $env:COMPOSER_NO_INTERACTION = '1'
    Run "$PhpDir\composer.bat" install --no-dev --optimize-autoloader
    Run npm.cmd ci --no-audit --no-fund
    Run "$PhpDir\php.exe" artisan atom:install --emulator=plus --theme=dusk --no-interaction

    $done = Sql 'SELECT COUNT(*) FROM website_installation WHERE completed = 1' 'plus'
    if ("$done".Trim() -ne '1') {
        Repair-AdminPassword
        $settingsFile = Join-Path $env:TEMP 'atom-settings.json'
        Write-Utf8 $settingsFile (@{ hotel_name = $state.HotelName } | ConvertTo-Json)
        $env:ATOM_ADMIN_EMAIL = $state.AdminEmail; $env:ATOM_ADMIN_PASSWORD = $state.AdminPassword
        Run "$PhpDir\php.exe" artisan atom:setup --complete "--settings=$settingsFile" "--admin=$($state.AdminUser)" --no-interaction
        Remove-Item $settingsFile
        # Atom seeds a placeholder "Admin" with a random password, and --admin=admin
        # only promotes it, so set the admin's name, email and password explicitly.
        $env:ADMIN_USER = $state.AdminUser; $env:ADMIN_EMAIL = $state.AdminEmail; $env:ADMIN_PASSWORD = $state.AdminPassword
        $script = Join-Path $env:TEMP 'atom-admin.php'
        Write-Utf8 $script @'
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$user = App\Models\User::where('username', getenv('ADMIN_USER'))->firstOrFail();
$user->forceFill(['username' => getenv('ADMIN_USER'), 'mail' => getenv('ADMIN_EMAIL'), 'password' => getenv('ADMIN_PASSWORD')])->save();
'@
        Run "$PhpDir\php.exe" $script
        Remove-Item $script, Env:\ATOM_ADMIN_PASSWORD, Env:\ADMIN_PASSWORD
    }
    $values = @{
        nitro_path = "$site/client"; rcon_ip = '127.0.0.1'; rcon_port = '30001'
        badges_path = "$site/hotel-files/c_images/album1584"; furniture_icons_path = "$site/hotel-files/c_images/hof_furni/icons"
    }
    foreach ($key in $values.Keys) { Sql "UPDATE website_settings SET value = '$($values[$key])' WHERE ``key`` = '$key'" 'plus' | Out-Null }
    Run "$PhpDir\php.exe" artisan optimize:clear
    Run "$PhpDir\php.exe" artisan optimize
    Pop-Location

    $task = Get-ScheduledTask -TaskName 'Atom CMS scheduler' -ErrorAction SilentlyContinue
    if (-not $task) {
        $action = New-ScheduledTaskAction -Execute "$PhpDir\php.exe" -Argument 'artisan schedule:run' -WorkingDirectory $cms
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName 'Atom CMS scheduler' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest | Out-Null
    }
    Ok "Website installed (admin: $($state.AdminUser))"
}

function Set-IisSite {
    $isLocal = [bool]$state.Local
    if ($isLocal) { Step 'Configuring the IIS website for http://localhost' } else { Step 'Configuring the IIS website, HTTPS and the firewall' }
    Import-Module WebAdministration
    $domain = $state.Domain
    $site = 'Hotel'
    $pool = 'Hotel'
    $apphost = 'MACHINE/WEBROOT/APPHOST'

    # PHP through FastCGI.
    $cgi = "$PhpDir\php-cgi.exe"
    if (-not (Get-WebConfiguration -PSPath $apphost -Filter "system.webServer/fastCgi/application[@fullPath='$cgi']")) {
        Add-WebConfiguration -PSPath $apphost -Filter 'system.webServer/fastCgi' -Value @{ fullPath = $cgi; maxInstances = 0; instanceMaxRequests = 10000; activityTimeout = 600; requestTimeout = 600 }
    }
    if (-not (Get-WebConfiguration -PSPath $apphost -Filter "system.webServer/handlers/add[@name='PHP_via_FastCGI']")) {
        Add-WebConfiguration -PSPath $apphost -Filter 'system.webServer/handlers' -AtIndex 0 -Value @{ name = 'PHP_via_FastCGI'; path = '*.php'; verb = '*'; modules = 'FastCgiModule'; scriptProcessor = $cgi; resourceType = 'Either' }
    }
    foreach ($type in @(@('.hab', 'application/octet-stream'), @('.nitro', 'application/octet-stream'), @('.jsonc', 'application/json'), @('.wasm', 'application/wasm'),
                        @('.ogg', 'audio/ogg'), @('.webp', 'image/webp'), @('.json', 'application/json'))) {
        if (-not (Get-WebConfiguration -PSPath $apphost -Filter "system.webServer/staticContent/mimeMap[@fileExtension='$($type[0])']")) {
            Add-WebConfiguration -PSPath $apphost -Filter 'system.webServer/staticContent' -Value @{ fileExtension = $type[0]; mimeType = $type[1] }
        }
    }
    if (Get-WebConfiguration -PSPath $apphost -Filter "system.webServer/httpProtocol/customHeaders/add[@name='X-Powered-By']") {
        Remove-WebConfigurationProperty -PSPath $apphost -Filter 'system.webServer/httpProtocol/customHeaders' -Name 'collection' -AtElement @{ name = 'X-Powered-By' }
    }

    # Without a site for bare IP requests, IIS answers them with an error instead of a page.
    # On a PC, IIS's own welcome site would answer every address on the network. A site the owner changed stays.
    $default = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    if ($default -and (-not $isLocal -or (Test-StockIisSite $default))) { Remove-Website -Name 'Default Web Site' }

    if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        if ($isLocal) { New-Website -Name $site -PhysicalPath "$HotelRoot\cms\public" -ApplicationPool $pool -IPAddress '127.0.0.1' -HostHeader $domain -Port 80 | Out-Null }
        else { New-Website -Name $site -PhysicalPath "$HotelRoot\cms\public" -ApplicationPool $pool -HostHeader $domain -Port 80 | Out-Null }
    }
    if (-not (Get-WebConfiguration -PSPath $apphost -Location $site -Filter "system.webServer/defaultDocument/files/add[@value='index.php']")) {
        Add-WebConfigurationProperty -PSPath $apphost -Location $site -Filter 'system.webServer/defaultDocument/files' -Name '.' -Value @{ value = 'index.php' } -AtIndex 0
    }
    if ($isLocal) {
        # Only this PC: browsers try ::1 for localhost before 127.0.0.1.
        foreach ($binding in '127.0.0.1:80:localhost', '[::1]:80:localhost') {
            if (-not (Get-WebBinding -Name $site | Where-Object { $_.bindingInformation -eq $binding })) {
                New-ItemProperty "IIS:\Sites\$site" -Name bindings -Value @{ protocol = 'http'; bindingInformation = $binding } | Out-Null
            }
        }
    } else {
        $hosts = @($domain, "www.$domain")
        if ($WsHost -ne $domain) { $hosts += $WsHost }
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=$domain" } | Select-Object -First 1
        if (-not $cert) {
            $cert = New-SelfSignedCertificate -DnsName $domain, "*.$domain" -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(10)
        }
        foreach ($name in $hosts) {
            if (-not (Get-WebBinding -Name $site -Protocol http -HostHeader $name -Port 80)) { New-WebBinding -Name $site -Protocol http -Port 80 -HostHeader $name }
            if (-not (Get-WebBinding -Name $site -Protocol https -HostHeader $name -Port 443)) {
                New-WebBinding -Name $site -Protocol https -Port 443 -HostHeader $name -SslFlags 1
                (Get-WebBinding -Name $site -Protocol https -HostHeader $name -Port 443).AddSslCertificate($cert.Thumbprint, 'My')
            }
        }
    }
    foreach ($dir in @(@('client', "$HotelRoot\client"), @('hotel-files', "$HotelRoot\hotel-files"))) {
        if (-not (Get-WebVirtualDirectory -Site $site -Name $dir[0])) { New-WebVirtualDirectory -Site $site -Name $dir[0] -PhysicalPath $dir[1] | Out-Null }
    }
    Write-Utf8 "$HotelRoot\hotel-files\web.config" @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <staticContent><clientCache cacheControlMode="UseMaxAge" cacheControlMaxAge="7.00:00:00" /></staticContent>
  </system.webServer>
</configuration>
'@
    Write-Utf8 "$HotelRoot\client\web.config" @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <defaultDocument><files><clear /><add value="index.html" /></files></defaultDocument>
    <staticContent><clientCache cacheControlMode="DisableCache" /></staticContent>
  </system.webServer>
  <location path="assets"><system.webServer><staticContent><clientCache cacheControlMode="UseMaxAge" cacheControlMaxAge="365.00:00:00" /></staticContent></system.webServer></location>
  <location path="src/assets"><system.webServer><staticContent><clientCache cacheControlMode="UseMaxAge" cacheControlMaxAge="365.00:00:00" /></staticContent></system.webServer></location>
</configuration>
'@

    # Global rules run before Atom's own web.config rules: send www to the main
    # domain, and hand the game's WebSocket and the emulator's two web endpoints
    # (furnidata built from the furniture table, badge rarity) to the emulator.
    $rules = 'system.webServer/rewrite/globalRules'
    foreach ($name in 'PlusEMU www', 'PlusEMU websocket', 'PlusEMU endpoints') {
        if (Get-WebConfiguration -PSPath $apphost -Filter "$rules/rule[@name='$name']") { Clear-WebConfiguration -PSPath $apphost -Filter "$rules/rule[@name='$name']" }
    }
    if (-not $isLocal) {
        Add-WebConfigurationProperty -PSPath $apphost -Filter $rules -Name '.' -Value @{ name = 'PlusEMU www'; stopProcessing = 'True' }
        Set-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU www']/match" -Name 'url' -Value '(.*)'
        Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU www']/conditions" -Name '.' -Value @{ input = '{HTTP_HOST}'; pattern = "^www\.$([regex]::Escape($domain))$" }
        $action = "$rules/rule[@name='PlusEMU www']/action"
        Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'type' -Value 'Redirect'
        Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'url' -Value "https://$domain/{R:1}"
        Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'redirectType' -Value 'Permanent'
    }

    Add-WebConfigurationProperty -PSPath $apphost -Filter $rules -Name '.' -Value @{ name = 'PlusEMU websocket'; stopProcessing = 'True' }
    Set-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/match" -Name 'url' -Value "^$([regex]::Escape($WsPath))$"
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/conditions" -Name '.' -Value @{ input = '{HTTP_HOST}'; pattern = "^$([regex]::Escape($WsHost))$" }
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/conditions" -Name '.' -Value @{ input = '{HTTP_ORIGIN}'; pattern = "^$([regex]::Escape((Get-SiteUrl)))$" }
    $action = "$rules/rule[@name='PlusEMU websocket']/action"
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'type' -Value 'Rewrite'
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'url' -Value 'http://127.0.0.1:2096/'
    # The emulator sees IIS as the peer, so it reads the visitor's address from X-Real-IP. Cloudflare sends it as CF-Connecting-IP.
    $variables = 'system.webServer/rewrite/allowedServerVariables'
    if (-not (Get-WebConfiguration -PSPath $apphost -Filter "$variables/add[@name='HTTP_X_REAL_IP']")) {
        Add-WebConfigurationProperty -PSPath $apphost -Filter $variables -Name '.' -Value @{ name = 'HTTP_X_REAL_IP' }
    }
    $visitor = if ($isLocal) { '{REMOTE_ADDR}' } else { '{HTTP_CF_CONNECTING_IP}' }
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/serverVariables" -Name '.' -Value @{ name = 'HTTP_X_REAL_IP'; value = $visitor }

    Add-WebConfigurationProperty -PSPath $apphost -Filter $rules -Name '.' -Value @{ name = 'PlusEMU endpoints'; stopProcessing = 'True' }
    Set-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU endpoints']/match" -Name 'url' -Value '^api/(gamedata/furnidata|badges/leaderboard)$'
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU endpoints']/conditions" -Name '.' -Value @{ input = '{HTTP_HOST}'; pattern = "^$([regex]::Escape($domain))$" }
    $action = "$rules/rule[@name='PlusEMU endpoints']/action"
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'type' -Value 'Rewrite'
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'url' -Value 'http://127.0.0.1:8080/api/{R:1}'

    # IIS needs to read the website, and write Atom's storage and cache.
    Run icacls.exe "$HotelRoot\cms" /grant 'IIS_IUSRS:(OI)(CI)RX' 'IUSR:(OI)(CI)RX' /Q
    Set-HotelPermissions
    foreach ($dir in "$HotelRoot\cms\storage", "$HotelRoot\cms\bootstrap\cache") { Run icacls.exe $dir /grant "IIS AppPool\$($pool):(OI)(CI)M" /T /Q }
    Run icacls.exe "$HotelRoot\cms\.env" /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "IIS AppPool\$($pool):R"
    Set-IisLimits $site $isLocal
    Start-Website -Name $site -ErrorAction SilentlyContinue
    if ((Get-WebAppPoolState -Name $pool).Value -eq 'Started') { Restart-WebAppPool -Name $pool } else { Start-WebAppPool -Name $pool }
    Ok "IIS serves $(Get-SiteUrl)"
    # A local install opens no port in the firewall and leaves its rules as they are.
    if ($isLocal) { return }

    # A new rule lets every address in until Update-CloudflareFirewall has limited it to Cloudflare.
    foreach ($port in 80, 443) {
        if (-not (Get-NetFirewallRule -Name "PlusEMU-$port" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name "PlusEMU-$port" -DisplayName "Hotel website (TCP $port)" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
        }
    }
    Ok 'Firewall allows HTTP and HTTPS (the database and emulator stay private)'
    Write-CloudflareCommand
    # The health check reads the result from the Cloudflare log.
    $installLog = $script:Log
    $script:Log = $CloudflareLog
    try {
        try { Update-CloudflareFirewall } finally { $script:Log = $installLog }
        Ok "HTTP and HTTPS are accepted only from Cloudflare's addresses, refreshed every Sunday at 03:00 (task: PlusEMU Cloudflare addresses)"
    } catch {
        Write-Log "$_"
        Say "      Could not download Cloudflare's addresses, so the website firewall was left as it is. Try again later: Start-ScheduledTask 'PlusEMU Cloudflare addresses'" 'Yellow'
    }
}

# Cloudflare's published address ranges. Throws unless both lists download and every entry is a range of the right kind.
function Get-CloudflareRanges {
    $ranges = @()
    foreach ($version in 4, 6) {
        $text = (Invoke-WebRequest "https://www.cloudflare.com/ips-v$version" -UseBasicParsing -TimeoutSec 20).Content
        $list = @("$text" -split '\s+' | Where-Object { $_ })
        if (-not $list) { throw "Cloudflare's IPv$version list is empty." }
        $shape = if ($version -eq 4) { '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$' } else { '^[0-9a-fA-F:]*:[0-9a-fA-F:]*/\d{1,3}$' }
        $bits = if ($version -eq 4) { 32 } else { 128 }
        foreach ($range in $list) {
            $address = $null
            $parts = $range -split '/'
            if ($range -notmatch $shape -or -not [Net.IPAddress]::TryParse($parts[0], [ref]$address) -or [int]$parts[1] -gt $bits) {
                throw "Cloudflare's IPv$version list has an entry that is not an address range: $range"
            }
        }
        $ranges += $list
    }
    return $ranges
}

# Lets only Cloudflare reach the website. Nothing changes unless both lists downloaded and passed the checks.
function Update-CloudflareFirewall {
    $ranges = Get-CloudflareRanges
    foreach ($port in 80, 443) { Set-NetFirewallRule -Name "PlusEMU-$port" -RemoteAddress $ranges -ErrorAction Stop }
    # IIS adds its own rules that let every address in, and any one allow rule is enough for Windows.
    Disable-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP', 'IIS-WebServerRole-HTTPS-In-TCP' -ErrorAction SilentlyContinue
    Write-Log "$(Get-Date -Format s) The website accepts only Cloudflare's $($ranges.Count) address ranges."
}

# Writes plusemu-cloudflare-ips.ps1 from the installer's own functions and runs it every Sunday at 03:00.
function Write-CloudflareCommand {
    $text = "# Installed by the PlusEMU installer. The `"PlusEMU Cloudflare addresses`" task runs this every Sunday at 03:00.`r`n"
    $text += "`$ErrorActionPreference = 'Stop'`r`n"
    $text += "`$ProgressPreference = 'SilentlyContinue'`r`n"
    $text += "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`r`n"
    $text += "`$script:Log = '$CloudflareLog'`r`n"
    foreach ($name in 'Write-Log', 'Get-CloudflareRanges', 'Update-CloudflareFirewall') {
        $text += "function $name {$((Get-Item "function:$name").Definition)}`r`n"
    }
    $text += "try { Update-CloudflareFirewall } catch { Write-Log `"`$(Get-Date -Format s) Cloudflare's addresses were not updated, so the firewall was left as it is: `$_`"; exit 1 }`r`n"
    Write-Utf8 $CloudflareScript $text
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CloudflareScript`""
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '03:00'
    Register-ScheduledTask -TaskName 'PlusEMU Cloudflare addresses' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}

function Test-StockIisSite($Site) {
    $bindings = @($Site.bindings.Collection | ForEach-Object { "$($_.protocol) $($_.bindingInformation)" }) -join ';'
    return $Site.physicalPath -eq '%SystemDrive%\inetpub\wwwroot' -and $bindings -eq 'http *:80:'
}

# Per-visitor limits and security headers for the hotel site.
function Set-IisLimits($Site, [bool]$IsLocal = $false) {
    $apphost = 'MACHINE/WEBROOT/APPHOST'
    $requestLimits = 'system.webServer/security/requestFiltering/requestLimits'
    Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $requestLimits -Name 'maxAllowedContentLength' -Value 20971520
    Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $requestLimits -Name 'maxUrl' -Value 4096
    Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $requestLimits -Name 'maxQueryString' -Value 2048
    $headers = 'system.webServer/httpProtocol/customHeaders'
    $added = @(, @('Permissions-Policy', 'camera=(), microphone=(), geolocation=(), usb=()'))
    # Every local visitor is 127.0.0.1, so per-visitor limits would only lock out the owner and their test clients.
    # The header timeout is a setting of the whole PC, and HSTS on localhost would send the browser to https:// for every other project.
    if (-not $IsLocal) {
        # Visitors arrive through Cloudflare, so the visitor's address is read from X-Forwarded-For.
        # The game client loads hundreds of hotel files at once, so the request rate stays high.
        $dynamic = 'system.webServer/security/dynamicIpSecurity'
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $dynamic -Name 'enableProxyMode' -Value 'True'
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $dynamic -Name 'denyAction' -Value 'Forbidden'
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter "$dynamic/denyByConcurrentRequests" -Name 'enabled' -Value 'True'
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter "$dynamic/denyByConcurrentRequests" -Name 'maxConcurrentRequests' -Value 50
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter "$dynamic/denyByRequestRate" -Name 'enabled' -Value 'True'
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter "$dynamic/denyByRequestRate" -Name 'maxRequests' -Value 1500
        Set-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter "$dynamic/denyByRequestRate" -Name 'requestIntervalInMilliseconds' -Value 10000
        # Slow clients that never finish sending their request headers are dropped after 10 seconds.
        & cmd.exe /c 'netsh http delete timeout timeouttype=headerwaittimeout >nul 2>&1'
        try { Run netsh.exe http add timeout timeouttype=headerwaittimeout value=10 }
        catch { Say "      Could not set the 10 second header timeout ($_). The website works without it." 'Yellow' }
        $added = @(, @('Strict-Transport-Security', 'max-age=31536000')) + $added
    }

    foreach ($header in $added) {
        if (Get-WebConfiguration -PSPath $apphost -Location $Site -Filter "$headers/add[@name='$($header[0])']") {
            Remove-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $headers -Name 'collection' -AtElement @{ name = $header[0] }
        }
        Add-WebConfigurationProperty -PSPath $apphost -Location $Site -Filter $headers -Name '.' -Value @{ name = $header[0]; value = $header[1] }
    }
}

function Set-HotelPermissions {
    # IIS needs to read the client and the hotel files; only administrators may read the emulator's passwords.
    foreach ($dir in 'client', 'hotel-files') {
        $path = Join-Path $HotelRoot $dir
        if (Test-Path $path) { Run icacls.exe $path /grant 'IIS_IUSRS:(OI)(CI)RX' 'IUSR:(OI)(CI)RX' /Q }
    }
    Run icacls.exe (Join-Path (Join-Path $HotelRoot 'emulator') 'Config') /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F'
}

# Windows Update policy: install every day at 05:00 and restart only when an update needs it.
# Windows ships security fixes inside cumulative updates, so they cannot be installed alone.
function Set-WindowsUpdates {
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = "$policy\AU"
    # New-Item -Force on an existing registry key would remove its other values.
    if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }
    $values = [ordered]@{
        NoAutoUpdate = 0; AUOptions = 4; ScheduledInstallDay = 0; ScheduledInstallTime = 5
        AlwaysAutoRebootAtScheduledTime = 1; AlwaysAutoRebootAtScheduledTimeMinutes = 15
    }
    foreach ($name in $values.Keys) { New-ItemProperty -Path $au -Name $name -Value $values[$name] -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $policy -Name ExcludeWUDriversInQualityUpdate -Value 1 -PropertyType DWord -Force | Out-Null
    Ok 'Windows updates install every day at 05:00; the server restarts only when an update needs it'
}

# The emulator's service log, the website log and the IIS logs are removed after 14 days.
function Set-LogCleanup {
    # A PC may serve other IIS sites, so a local install cleans up the hotel site's logs only.
    $iisLogs = if ($state.Local) { "W3SVC$((Get-Website -Name 'Hotel').id)" } else { '*' }
    Write-Utf8 $CleanupScript @"
# Installed by the PlusEMU installer. The "PlusEMU log cleanup" task runs this every day.
`$limit = (Get-Date).AddDays(-14)
foreach (`$pattern in '$HotelRoot\emulator\service\*.log', '$HotelRoot\cms\storage\logs\*.log', "`$env:SystemDrive\inetpub\logs\LogFiles\$iisLogs\*.log") {
    Get-ChildItem `$pattern -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt `$limit | Remove-Item -Force -ErrorAction SilentlyContinue
}
"@
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScript`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '03:30'
    Register-ScheduledTask -TaskName 'PlusEMU log cleanup' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Ok 'Logs older than 14 days are removed every day at 03:30 (task: PlusEMU log cleanup)'
}

# Saves what a download cannot bring back: the database, the settings, the website's uploads and the hotel's texts.
function Invoke-NightlyBackup {
    $nightly = $NightlyRoot
    New-Item -ItemType Directory -Force -Path $nightly | Out-Null
    # plusemu-update holds this lock while it changes the hotel.
    $deadline = (Get-Date).AddSeconds([int]$BackupLockWait)
    $lock = $null
    while (-not $lock) {
        try { $lock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch {
            if ((Get-Date) -ge $deadline) { throw 'An update is still running; no backup was made.' }
            Start-Sleep 1
        }
    }
    try {
        $script:state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $databaseMb = [int]"$(Sql "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema = 'plus'")".Trim()
        $freeMb = [int]((New-Object IO.DriveInfo $nightly).AvailableFreeSpace / 1MB)
        if ($freeMb -lt $databaseMb + 2048) { throw "Only $freeMb MB free for $nightly; no backup was made." }
        $target = Join-Path $nightly (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
        $partial = "$target.partial"
        New-Item -ItemType Directory -Force -Path $partial | Out-Null
        $sql = Join-Path $partial 'database.sql'
        Invoke-DatabaseDump $sql
        $in = [IO.File]::OpenRead($sql)
        $out = [IO.File]::Create("$sql.gz")
        $zip = New-Object IO.Compression.GZipStream($out, [IO.Compression.CompressionMode]::Compress)
        try { $in.CopyTo($zip) } finally { $zip.Dispose(); $out.Dispose(); $in.Dispose() }
        Remove-Item $sql
        $files = @('emulator/Config', 'client/configuration', 'cms/.env', 'cms/storage/app', 'hotel-files/gamedata') | Where-Object { Test-Path (Join-Path $HotelRoot $_) }
        # Exit code 1 only means a file changed while it was read.
        $code = Invoke-Tar (@('-C', $HotelRoot, '-czf', (Join-Path $partial 'hotel.tar.gz')) + $files)
        if ($code -notin 0, 1) { throw "Backing up the hotel files failed (tar exit code $code)." }
        $settings = @('hotel.json', 'versions.json') | Where-Object { Test-Path (Join-Path $StateDir $_) }
        if ((Invoke-Tar (@('-C', $StateDir, '-czf', (Join-Path $partial 'settings.tar.gz')) + $settings)) -ne 0) { throw 'Backing up the settings failed.' }
        Move-Item $partial $target
        Get-ChildItem $nightly -Directory -Filter '*.partial' | Remove-Item -Recurse -Force
        $backups = @(Get-ChildItem $nightly -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' } | Sort-Object Name)
        if ($backups.Count -gt [int]$KeepNightly) { $backups[0..($backups.Count - [int]$KeepNightly - 1)] | Remove-Item -Recurse -Force }
        Write-Log "$(Get-Date -Format s) Backup saved in $target"
    } finally {
        $lock.Dispose()
    }
}

# Writes plusemu-backup.ps1 from the installer's own functions and runs it every night at 04:00.
function Write-BackupCommand {
    $text = "# Installed by the PlusEMU installer. The `"PlusEMU nightly backup`" task runs this every night at 04:00.`r`n"
    $text += "`$ErrorActionPreference = 'Stop'`r`n"
    foreach ($name in 'HotelRoot', 'StateDir', 'StateFile', 'NightlyRoot', 'LockFile', 'KeepNightly', 'BackupLockWait') {
        $text += "`$$name = '$((Get-Variable $name).Value)'`r`n"
    }
    $text += "`$script:Log = '$BackupLog'`r`n"
    foreach ($name in 'Write-Log', 'Find-MariaDb', 'Get-MariaDb', 'Sql', 'Invoke-DatabaseDump', 'Invoke-Tar', 'Invoke-NightlyBackup') {
        $text += "function $name {$((Get-Item "function:$name").Definition)}`r`n"
    }
    $text += "try { Invoke-NightlyBackup } catch { Write-Log `"`$(Get-Date -Format s) Backup failed: `$_`"; exit 1 }`r`n"
    Write-Utf8 $BackupScript $text
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BackupScript`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '04:00'
    Register-ScheduledTask -TaskName 'PlusEMU nightly backup' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Ok "Nightly backups at 04:00 in $NightlyRoot (the newest $KeepNightly are kept)"
}

function Protect-Server {
    # A local install changes nothing on the PC outside the hotel: no account lockout and no Windows Update policy.
    if ($state.Local) {
        Step "Setting up the hotel's log cleanup, backups and health checks"
        Set-LogCleanup
        Write-BackupCommand
        Write-HealthCommand
        return
    }
    Step 'Securing the server (failed logins, Windows updates, logs, backups and health checks)'
    # A domain controller would apply this to the whole domain, so its own policy is left alone.
    if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
        Say '      This server is a domain controller: the account lockout policy was left as it is.' 'Yellow'
    } else {
        # Windows refuses a counting window longer than the lockout, so the window shrinks first
        # when it can, and the lockout is set before the window when it cannot.
        Run net.exe accounts /lockoutthreshold:10
        & net.exe accounts /lockoutwindow:10 *> $null
        Run net.exe accounts /lockoutduration:10
        Run net.exe accounts /lockoutwindow:10
        Ok 'An account locks for 10 minutes after 10 wrong passwords in 10 minutes (RDP and SSH were not opened or changed)'
    }
    Set-WindowsUpdates
    Set-LogCleanup
    Write-BackupCommand
    Write-HealthCommand
}

# ---------------------------------------------------------------- health check

# Each check: its name (the function Test-Health<Name>), what it checks, the command that shows more,
# and Server when only a server install has the thing it checks.
function Get-HealthChecks {
    return @(
        @{ Name = 'Emulator'; Label = 'The emulator service'; Look = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 100" }
        @{ Name = 'GamePort'; Label = 'The game connection (port 2096)'; Look = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 100" }
        @{ Name = 'ApiPort'; Label = 'The emulator API (port 8080)'; Look = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 100" }
        @{ Name = 'WebServer'; Label = 'The web server (IIS)'; Look = 'Get-Service W3SVC' }
        @{ Name = 'Website'; Label = 'The website'; Look = "Get-ChildItem $env:SystemDrive\inetpub\logs\LogFiles -Recurse | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 50" }
        @{ Name = 'Database'; Label = 'The database (MariaDB)'; Look = 'Get-Service MariaDB' }
        @{ Name = 'Disk'; Label = 'Free disk space'; Look = 'Get-PSDrive C' }
        @{ Name = 'Backup'; Label = 'The nightly backup'; Look = "Get-Content $BackupLog -Tail 20" }
        @{ Name = 'Certificate'; Label = 'The HTTPS certificate'; Look = "Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, NotAfter"; Server = $true }
        @{ Name = 'Cloudflare'; Label = 'The Cloudflare address refresh'; Look = "Get-Content $CloudflareLog -Tail 20"; Server = $true }
    ) | Where-Object { -not ($state.Local -and $_.Server) }
}

# Runs curl.exe without logging and returns its exit code and output.
function Get-ProbeResult([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & curl.exe @Arguments 2> $null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    return @{ Code = $code; Output = (@($output) -join '') }
}

# A program on this server accepts connections on the port.
function Test-PortAnswers($Port) {
    $client = New-Object Net.Sockets.TcpClient
    try { return $client.ConnectAsync('127.0.0.1', $Port).Wait(5000) } catch { return $false } finally { $client.Dispose() }
}

function Get-FreeMegabytes($Path) { return [int64]((New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Path))).AvailableFreeSpace / 1MB) }

function Test-HealthEmulator { if ((Get-Service PlusEMU -ErrorAction SilentlyContinue).Status -ne 'Running') { return 'The PlusEMU service is not running.' } }
function Test-HealthGamePort { if (-not (Test-PortAnswers 2096)) { return 'Nothing answers on port 2096.' } }
function Test-HealthApiPort { if (-not (Test-PortAnswers 8080)) { return 'Nothing answers on port 8080.' } }
function Test-HealthWebServer { if ((Get-Service W3SVC -ErrorAction SilentlyContinue).Status -ne 'Running') { return 'The IIS service (W3SVC) is not running.' } }

function Test-HealthWebsite {
    $domain = $state.Domain
    $code = (Get-ProbeResult @('-s', '-o', 'NUL', '-w', '%{http_code}', '--max-time', '10', '--resolve', "$($domain):80:127.0.0.1", "http://$domain/")).Output
    if ($code -match '^[234]\d\d$') { return }
    if (-not $code -or $code -eq '000') { return "$(Get-SiteUrl) does not answer on this server." }
    return "$(Get-SiteUrl) answers with error $code on this server."
}

function Test-HealthDatabase {
    try { if ("$(Sql 'SELECT 1')".Trim() -eq '1') { return } } catch { }
    return 'MariaDB does not answer.'
}

function Test-HealthDisk {
    $free = Get-FreeMegabytes $HotelRoot
    if ($free -le 2048) { return "Only $free MB is free on the disk of $HotelRoot. Keep more than 2048 MB free." }
}

function Test-HealthBackup {
    $backups = @(Get-ChildItem $NightlyRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' })
    $limit = (Get-Date).AddHours(-36)
    if ($backups | Where-Object { $_.LastWriteTime -gt $limit }) { return }
    # A new hotel has no backup before its first night.
    if (-not $backups -and (Test-Path $BackupScript) -and (Get-Item $BackupScript).LastWriteTime -gt $limit) { return }
    return "The newest nightly backup in $NightlyRoot is older than 36 hours."
}

function Test-HealthCertificate {
    $certificate = Get-HotelCertificate
    if (-not $certificate -or $certificate.NotAfter -lt (Get-Date).AddDays(30)) {
        return "The certificate on the HTTPS binding of $($state.Domain) expires within 30 days, or is missing."
    }
}

function Test-HealthCloudflare {
    $line = $null
    if (Test-Path $CloudflareLog) { $line = Get-Content $CloudflareLog | Where-Object { "$_".Trim() } | Select-Object -Last 1 }
    if (-not $line) { return 'The refresh never ran.' }
    if ("$line" -notmatch "The website accepts only Cloudflare's") { return "The last refresh did not work: $line" }
    if ((Get-Item $CloudflareLog).LastWriteTime -lt (Get-Date).AddDays(-8)) { return 'The last refresh that worked is older than 8 days.' }
}

# Returns $null when Discord took the message, or the reason when it did not.
function Send-Discord($Webhook, $Text) {
    $body = @{ username = 'PlusEMU'; content = $Text; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Compress
    try {
        $null = Invoke-RestMethod -Method Post -Uri $Webhook -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15
        return $null
    } catch {
        if ($_.Exception.Response) { return "Discord answered with HTTP status $([int]$_.Exception.Response.StatusCode). Check that the webhook still exists." }
        return "Discord could not be reached ($($_.Exception.Message))."
    }
}

function Write-HealthLine($Text) { Write-Host $Text; Add-Content -Path $HealthLog -Value $Text -Encoding UTF8 }

# The plusemu-health.ps1 command. Discord hears about every check that starts or stops failing, once.
# Returns $true when every check passed; $script:HealthProblems lists the others.
function Invoke-HealthCheck {
    $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $script:HealthProblems = @()
    $script:state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ((Test-Path $HealthLog) -and (Get-Item $HealthLog).Length -gt 5MB) {
        $keep = Get-Content $HealthLog -Tail 20000
        Set-Content $HealthLog $keep -Encoding UTF8
    }
    # An update stops the emulator for a while, and an installer run restarts services.
    try { ([IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')).Dispose() }
    catch { Write-HealthLine "$now Skipped: an update, a backup or the installer is running."; return $true }
    $was = @()
    if (Test-Path $HealthState) { $was = @(Get-Content $HealthState -Raw | ConvertFrom-Json) }
    $failed = @()
    $changes = ''
    $short = ''
    $checks = @(Get-HealthChecks)
    foreach ($check in $checks) {
        $reason = & "Test-Health$($check.Name)"
        if (-not $reason) {
            if ($was -contains $check.Name) {
                $changes += "$([char]::ConvertFromUtf32(0x2705)) $($check.Label) works again.`n"
                $short += "$([char]::ConvertFromUtf32(0x2705)) $($check.Label) works again.`n"
            }
            continue
        }
        $failed += $check.Name
        $script:HealthProblems += "$($check.Label): $reason Look at it with: $($check.Look)"
        Write-HealthLine "$now PROBLEM: $($check.Label): $reason Look at it with: $($check.Look)"
        if ($was -notcontains $check.Name) {
            $changes += "$([char]::ConvertFromUtf32(0x274C)) $($check.Label) does not work. $reason Look at it with: ``$($check.Look)```n"
            $short += "$([char]::ConvertFromUtf32(0x274C)) $($check.Label) does not work.`n"
        }
    }
    if ($failed.Count -eq 0) { Write-HealthLine "$now OK: all $($checks.Count) checks passed." }
    else { Write-HealthLine "$now $($failed.Count) of $($checks.Count) checks failed." }
    # Discord takes at most 2000 characters, so a long list names the checks only.
    if ($changes.Length -gt 1800) { $changes = "$short`nRun $HealthScript on the server to see why." }
    $sent = $true
    if ($changes -and $state.DiscordWebhook) {
        $reason = Send-Discord $state.DiscordWebhook "**$($state.HotelName)** health check`n$changes"
        if ($reason) {
            $sent = $false
            Write-HealthLine "$now Could not tell Discord what changed: $reason The next run tries again."
        } else {
            Write-HealthLine "$now Told Discord what changed."
        }
    }
    # After a failed message, the old state stays, so the next run sends the same changes.
    if ($sent) { Write-Utf8 $HealthState (ConvertTo-Json -InputObject @($failed) -Compress) }
    return ($failed.Count -eq 0)
}

# Writes plusemu-health.ps1 from the installer's own functions and runs it every 5 minutes.
function Write-HealthCommand {
    $text = "# Installed by the PlusEMU installer. The `"PlusEMU health check`" task runs this every 5 minutes. Run it by hand in Administrator PowerShell: & '$HealthScript'`r`n"
    $text += "`$ErrorActionPreference = 'Stop'`r`n"
    $text += "`$ProgressPreference = 'SilentlyContinue'`r`n"
    $text += "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`r`n"
    foreach ($name in 'HotelRoot', 'StateFile', 'NightlyRoot', 'BackupScript', 'BackupLog', 'CloudflareLog', 'LockFile', 'HealthScript', 'HealthLog', 'HealthState') {
        $text += "`$$name = '$((Get-Variable $name).Value)'`r`n"
    }
    $text += "`$script:Log = '$HealthLog'`r`n"
    $text += "Import-Module WebAdministration -ErrorAction SilentlyContinue`r`n"
    $functions = @('Write-Log', 'Write-Utf8', 'Find-MariaDb', 'Get-MariaDb', 'Sql', 'Get-SiteUrl', 'Get-HotelCertificate', 'Get-ProbeResult', 'Test-PortAnswers', 'Get-FreeMegabytes',
                   'Get-HealthChecks', 'Send-Discord', 'Write-HealthLine', 'Invoke-HealthCheck') + @(Get-HealthChecks | ForEach-Object { "Test-Health$($_.Name)" })
    foreach ($name in $functions) {
        $text += "function $name {$((Get-Item "function:$name").Definition)}`r`n"
    }
    $text += "if (-not (Invoke-HealthCheck)) { exit 1 }`r`n"
    Write-Utf8 $HealthScript $text
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$HealthScript`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName 'PlusEMU health check' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Ok "Health check every 5 minutes (task: PlusEMU health check, log: $HealthLog)"
    if ($state.Local) { return }
    if (-not $state.DiscordWebhook) {
        Say '      Discord alerts are off. To turn them on, run the installer again with $env:PLUSEMU_DISCORD_WEBHOOK set to the webhook URL.'
        return
    }
    if ($script:DiscordWebhookNew) {
        $reason = Send-Discord $state.DiscordWebhook "$([char]::ConvertFromUtf32(0x2705)) Health alerts for **$($state.HotelName)** are on. You get a message here when something is wrong with your hotel, and when it works again."
        if ($reason) { Say "      Could not send the first message to Discord: $reason The health check still runs. Check the webhook, then run the installer again." 'Yellow' }
        else { $script:DiscordWebhookNew = $false }
    }
    Ok 'Discord alerts are on. To change the webhook, run the installer again with $env:PLUSEMU_DISCORD_WEBHOOK set to the new URL (or off)'
}

# ---------------------------------------------------------------- Cloudflare API setup

# Calls the Cloudflare API with the token. On failure it throws Cloudflare's own message and sets CloudflareStatus.
function Invoke-Cloudflare($Method, $Path, $Body = $null) {
    $script:CloudflareStatus = 0
    # The token stays a SecureString until it goes into the request, so a trace never shows it.
    $request = @{
        Method = $Method; Uri = "$CloudflareApi$Path"; ContentType = 'application/json'; TimeoutSec = 30
        Headers = @{ Authorization = 'Bearer ' + ([Net.NetworkCredential]::new('', $script:CloudflareToken).Password).Trim() }
    }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress }
    try {
        $response = Invoke-RestMethod @request
    } catch {
        if ($_.Exception.Response) { $script:CloudflareStatus = [int]$_.Exception.Response.StatusCode }
        $message = try { (@(($_.ErrorDetails.Message | ConvertFrom-Json).errors) | ForEach-Object { $_.message }) -join ' ' } catch { '' }
        if (-not $message) { $message = $_.Exception.Message }
        Write-Log "Cloudflare: $Method $Path -> $script:CloudflareStatus"
        throw $message
    }
    $script:CloudflareStatus = 200
    Write-Log "Cloudflare: $Method $Path -> 200"
    if (-not $response.success) { throw ((@($response.errors) | ForEach-Object { $_.message }) -join ' ') }
    return $response
}

# A failure on this server, not in Cloudflare.
function Stop-Cloudflare($Message) { $script:CloudflareStatus = 'local'; throw $Message }

function Set-CloudflareDns {
    $domain = $state.Domain
    $names = @($domain, "www.$domain")
    if ($WsHost -notin $names) { $names += $WsHost }
    foreach ($name in $names) {
        $records = @((Invoke-Cloudflare GET "/zones/$CloudflareZone/dns_records?name=$name&per_page=100").result | Where-Object { $_ })
        if ($records | Where-Object { $_.type -eq 'CNAME' }) { Stop-Cloudflare "$name has a CNAME record. Delete it in Cloudflare (DNS > Records) and run the installer again." }
        if ($records | Where-Object { $_.type -eq 'AAAA' }) {
            Say "      $name also has an AAAA (IPv6) record. If it does not point to this server, delete it in Cloudflare (DNS > Records)." 'Yellow'
        }
        $a = @($records | Where-Object { $_.type -eq 'A' })
        if ($a.Count -eq 0) {
            $null = Invoke-Cloudflare POST "/zones/$CloudflareZone/dns_records" @{ type = 'A'; name = $name; content = $ServerIp; proxied = $true; ttl = 1 }
        } elseif ($a.Count -gt 1) {
            Stop-Cloudflare "$name has more than one A record. Keep only one in Cloudflare (DNS > Records) and run the installer again."
        } elseif ($a[0].content -ne $ServerIp -or -not $a[0].proxied) {
            $null = Invoke-Cloudflare PATCH "/zones/$CloudflareZone/dns_records/$($a[0].id)" @{ content = $ServerIp; proxied = $true }
        }
    }
    Ok "DNS: $($names -join ' ') point to $ServerIp through Cloudflare (proxied)"
}

# Cloudflare's Origin CA root, which signs every origin certificate.
function Get-OriginRoot {
    $file = Join-Path $Downloads 'origin_ca_rsa_root.pem'
    try {
        Invoke-WebRequest $OriginCaRootUrl -OutFile $file -UseBasicParsing -TimeoutSec 20
        $root = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [IO.File]::ReadAllBytes($file))
    } catch { Stop-Cloudflare "Could not download Cloudflare's Origin CA root certificate. Try again later." }
    if ($root.Subject -ne $root.Issuer -or $root.Subject -notmatch 'CloudFlare') { Stop-Cloudflare "The download of Cloudflare's Origin CA root certificate is not that certificate." }
    return $root
}

# The DNS names in a certificate's subject alternative name extension, read from its DER bytes.
function Get-CertificateNames($Certificate) {
    $extension = $Certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if (-not $extension) { return @() }
    $bytes = $extension.RawData
    $names = @()
    $at = 0
    while ($at -lt $bytes.Length) {
        $tag = $bytes[$at]
        $length = [int]$bytes[$at + 1]
        $start = $at + 2
        if ($length -ge 0x80) {
            $start += $length - 0x80
            $length = 0
            for ($k = $at + 2; $k -lt $start; $k++) { $length = $length * 256 + $bytes[$k] }
        }
        # Step into the outer SEQUENCE; collect each dNSName ([2] IA5String).
        if ($tag -eq 0x30) { $at = $start; continue }
        if ($tag -eq 0x82) { $names += [Text.Encoding]::ASCII.GetString($bytes, $start, $length).ToLowerInvariant() }
        $at = $start + $length
    }
    return $names
}

# Signed by the Origin CA root, for every hotel name, with its private key and valid 30 more days.
function Test-OriginCertificate($Certificate, $Root) {
    if (-not $Certificate -or -not $Certificate.HasPrivateKey -or $Certificate.NotAfter -lt (Get-Date).AddDays(30)) { return $false }
    $chain = New-Object Security.Cryptography.X509Certificates.X509Chain
    $chain.ChainPolicy.RevocationMode = 'NoCheck'
    $chain.ChainPolicy.VerificationFlags = 'AllowUnknownCertificateAuthority'
    [void]$chain.ChainPolicy.ExtraStore.Add($Root)
    if (-not $chain.Build($Certificate) -or $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint -ne $Root.Thumbprint) { return $false }
    $names = @(Get-CertificateNames $Certificate)
    foreach ($name in @($state.Domain, "www.$($state.Domain)", $WsHost)) {
        $parent = $name.Substring($name.IndexOf('.') + 1)
        if ($name -notin $names -and "*.$parent" -notin $names) { return $false }
    }
    return $true
}

# The certificate on the hotel's HTTPS binding.
function Get-HotelCertificate {
    $binding = Get-WebBinding -Name 'Hotel' -Protocol https -HostHeader $state.Domain -Port 443
    if (-not $binding -or -not $binding.certificateHash) { return $null }
    return Get-Item "Cert:\LocalMachine\My\$($binding.certificateHash)" -ErrorAction SilentlyContinue
}

# certreq makes the private key in the machine's key store, where it stays; Cloudflare only signs the request.
function New-OriginRequest {
    $dir = Join-Path $StateDir 'origin'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $inf = Join-Path $dir 'request.inf'
    $csr = Join-Path $dir 'request.csr'
    Remove-Item $csr -ErrorAction SilentlyContinue
    Write-Utf8 $inf @"
[Version]
Signature = "`$Windows NT`$"

[NewRequest]
Subject = "CN=$($state.Domain)"
KeyAlgorithm = RSA
KeyLength = 2048
HashAlgorithm = sha256
MachineKeySet = TRUE
Exportable = TRUE
KeyUsage = 0xa0
ProviderName = "Microsoft RSA SChannel Cryptographic Provider"
RequestType = PKCS10

[EnhancedKeyUsageExtension]
OID = 1.3.6.1.5.5.7.3.1
"@
    try { Run certreq.exe -new -q -machine $inf $csr } catch { Stop-Cloudflare 'certreq could not create the certificate request.' }
    return [IO.File]::ReadAllText($csr)
}

# Installs Cloudflare's certificate with the pending key and moves the HTTPS bindings to it.
# When a binding refuses it, every binding gets its previous certificate back.
function Install-OriginCertificate($Pem, $Root) {
    $dir = Join-Path $StateDir 'origin'
    $file = Join-Path $dir 'certificate.cer'
    Write-Utf8 $file $Pem
    $issued = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [IO.File]::ReadAllBytes($file))
    # certreq accepts a certificate only when Windows trusts its root.
    if (-not (Test-Path "Cert:\LocalMachine\Root\$($Root.Thumbprint)")) {
        $store = New-Object Security.Cryptography.X509Certificates.X509Store 'Root', 'LocalMachine'
        $store.Open('ReadWrite')
        $store.Add($Root)
        $store.Close()
    }
    try { Run certreq.exe -accept -q -machine $file } catch { Stop-Cloudflare 'Windows did not accept the certificate from Cloudflare, so the current certificate stays.' }
    $certificate = Get-Item "Cert:\LocalMachine\My\$($issued.Thumbprint)" -ErrorAction SilentlyContinue
    if (-not (Test-OriginCertificate $certificate $Root)) { Stop-Cloudflare 'The certificate from Cloudflare did not pass the checks, so the current certificate stays.' }
    $certificate.FriendlyName = 'PlusEMU Cloudflare Origin'
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
    $names = @($state.Domain, "www.$($state.Domain)")
    if ($WsHost -notin $names) { $names += $WsHost }
    $previous = @{}
    try {
        foreach ($name in $names) {
            $binding = Get-WebBinding -Name 'Hotel' -Protocol https -HostHeader $name -Port 443
            if (-not $binding) { continue }
            $previous[$name] = "$($binding.certificateHash)"
            if ($binding.certificateHash) { $binding.RemoveSslCertificate() }
            $binding.AddSslCertificate($certificate.Thumbprint, 'My')
        }
    } catch {
        $reason = "$_"
        foreach ($name in $previous.Keys) {
            $binding = Get-WebBinding -Name 'Hotel' -Protocol https -HostHeader $name -Port 443
            try { $binding.RemoveSslCertificate() } catch { }
            if ($previous[$name]) { $binding.AddSslCertificate($previous[$name], 'My') }
        }
        Stop-Cloudflare "IIS did not accept the new certificate ($reason), so the previous one is back."
    }
    return $certificate
}

function Set-CloudflareCertificate {
    $domain = $state.Domain
    $hosts = @($domain, "*.$domain")
    # The wildcard covers one level below the domain only.
    if ($WsHost.EndsWith(".$domain") -and $WsHost.Substring(0, $WsHost.Length - $domain.Length - 1).Contains('.')) { $hosts += $WsHost }
    $root = Get-OriginRoot
    $certificate = Get-HotelCertificate
    if (Test-OriginCertificate $certificate $root) {
        $script:CloudflareCertExpires = $certificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd')
        Ok "Origin certificate: already installed, valid until $script:CloudflareCertExpires"
        return
    }
    $csr = New-OriginRequest
    $response = Invoke-Cloudflare POST '/certificates' @{ hostnames = $hosts; requested_validity = 5475; request_type = 'origin-rsa'; csr = $csr }
    $certificate = Install-OriginCertificate $response.result.certificate $root
    $script:CloudflareCertExpires = $certificate.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd')
    Ok "Origin certificate installed, valid until $script:CloudflareCertExpires"
}

function Set-CloudflareSettings {
    # Full (strict) comes after the certificate step, so Cloudflare never meets the self-signed one.
    foreach ($setting in @(@('ssl', 'strict'), @('always_use_https', 'on'), @('websockets', 'on'), @('min_tls_version', '1.2'), @('browser_check', 'on'))) {
        $null = Invoke-Cloudflare PATCH "/zones/$CloudflareZone/settings/$($setting[0])" @{ value = $setting[1] }
    }
    # The security level also switches Under Attack mode, which the owner may have turned on.
    if ((Invoke-Cloudflare GET "/zones/$CloudflareZone/settings/security_level").result.value -ne 'under_attack') {
        $null = Invoke-Cloudflare PATCH "/zones/$CloudflareZone/settings/security_level" @{ value = 'medium' }
    }
    Ok 'SSL/TLS: Full (strict), Always Use HTTPS, TLS 1.2 or newer, WebSockets, Browser Integrity Check, security level medium'
}

function Set-CloudflareBotFightMode {
    $null = Invoke-Cloudflare PUT "/zones/$CloudflareZone/bot_management" @{ fight_mode = $true }
    Ok 'Bot Fight Mode on'
}

# Adds each rule to the phase, or updates the rule with the same description.
function Set-CloudflareRules($Phase, $Rules) {
    try {
        $entry = (Invoke-Cloudflare GET "/zones/$CloudflareZone/rulesets/phases/$Phase/entrypoint").result
    } catch {
        if ($script:CloudflareStatus -ne 404) { throw }
        $null = Invoke-Cloudflare PUT "/zones/$CloudflareZone/rulesets/phases/$Phase/entrypoint" @{ rules = @($Rules) }
        return
    }
    foreach ($rule in $Rules) {
        $existing = @($entry.rules) | Where-Object { $_ -and $_.description -eq $rule.description } | Select-Object -First 1
        if ($existing) {
            $null = Invoke-Cloudflare PATCH "/zones/$CloudflareZone/rulesets/$($entry.id)/rules/$($existing.id)" $rule
        } else {
            $null = Invoke-Cloudflare POST "/zones/$CloudflareZone/rulesets/$($entry.id)/rules" $rule
        }
    }
}

function Set-CloudflareRateLimit {
    # The Free plan counts by path and IP only, over 10 seconds, so opening these pages counts too.
    Set-CloudflareRules 'http_ratelimit' @(@{
        description = 'PlusEMU: limit sign-in and registration'; action = 'block'; enabled = $true
        expression = '(http.request.uri.path in {"/login" "/register" "/forgot-password" "/two-factor-challenge" "/housekeeping/login"} or http.request.uri.path wildcard "/reset-password/*")'
        ratelimit = @{ characteristics = @('cf.colo.id', 'ip.src'); period = 10; requests_per_period = 10; mitigation_timeout = 10 }
    })
    Ok 'Rate limit: 10 sign-in, registration and password reset requests per 10 seconds per visitor'
}

function Set-CloudflareFirewallRules {
    $domain = $state.Domain
    Set-CloudflareRules 'http_request_firewall_custom' @(
        @{ description = 'PlusEMU: game connection only from the hotel website'; action = 'block'; enabled = $true
           expression = "(http.host eq `"$WsHost`" and http.request.uri.path eq `"/$WsPath`" and not any(http.request.headers[`"origin`"][*] eq `"https://$domain`"))" },
        @{ description = 'PlusEMU: check visitors before housekeeping'; action = 'managed_challenge'; enabled = $true
           expression = "(http.host eq `"$domain`" and (http.request.uri.path eq `"/housekeeping`" or http.request.uri.path wildcard `"/housekeeping/*`"))" }
    )
    Ok "Firewall rules: the game connects only from https://$domain, and housekeeping visitors get a Cloudflare check first"
}

# Runs every step with the token. Returns $false and sets CloudflareError when a step fails.
function Invoke-CloudflareSetup {
    $domain = $state.Domain
    # Each step: the function, the token permission it needs, and its name in messages.
    $steps = @(
        @{ Name = 'Set-CloudflareDns'; Permission = 'Zone / DNS / Edit'; Label = 'DNS records' },
        @{ Name = 'Set-CloudflareCertificate'; Permission = 'Zone / SSL and Certificates / Edit'; Label = 'origin certificate' },
        @{ Name = 'Set-CloudflareSettings'; Permission = 'Zone / Zone Settings / Edit'; Label = 'SSL/TLS and security settings' },
        @{ Name = 'Set-CloudflareBotFightMode'; Permission = 'Zone / Bot Management / Edit'; Label = 'Bot Fight Mode' },
        @{ Name = 'Set-CloudflareRateLimit'; Permission = 'Zone / Zone WAF / Edit'; Label = 'rate limiting rule' },
        @{ Name = 'Set-CloudflareFirewallRules'; Permission = 'Zone / Zone WAF / Edit'; Label = 'firewall rules' }
    )
    if ($WsHost -ne $domain -and -not $WsHost.EndsWith(".$domain")) {
        $script:CloudflareError = "The game connection uses another domain ($WsHost), so the installer cannot set it up. Follow the manual steps in the guide."
        return $false
    }
    try { $null = Invoke-Cloudflare GET '/user/tokens/verify' }
    catch { $script:CloudflareError = "Cloudflare did not accept the token. Copy it again from My Profile > API Tokens. Cloudflare said: $_"; return $false }
    try { $zones = @((Invoke-Cloudflare GET "/zones?name=$domain").result | Where-Object { $_ }) }
    catch { $script:CloudflareError = "Could not look up $domain. The token needs the permission Zone / Zone / Read. Cloudflare said: $_"; return $false }
    if (-not $zones) {
        $script:CloudflareError = "Cloudflare has no site $domain that this token can use. Add the site to Cloudflare and change the nameservers (guide steps 1 and 2). Check that the token's Zone Resources include $domain."
        return $false
    }
    $script:CloudflareZone = $zones[0].id
    if ($zones[0].status -ne 'active') {
        Say "      Cloudflare still waits for the nameserver change of $domain. The settings work as soon as Cloudflare shows the site as Active." 'Yellow'
    }
    foreach ($step in $steps) {
        try { & $step.Name }
        catch {
            $reason = "$_"
            $script:CloudflareError = if ("$script:CloudflareStatus" -in '401', '403') {
                "The $($step.Label) step failed: the token lacks the permission $($step.Permission). Add it in My Profile > API Tokens > Edit, then try again. Cloudflare said: $reason"
            } elseif ($script:CloudflareStatus -eq 'local') {
                "The $($step.Label) step failed: $reason"
            } else {
                "The $($step.Label) step failed. Cloudflare said: $reason"
            }
            return $false
        }
    }
    return $true
}

# A hidden answer from the console, as a SecureString.
function Read-Secret($Question) { return Read-Host "  $Question" -AsSecureString }

function Connect-Cloudflare {
    Step 'Connecting your hotel to Cloudflare'
    $interactive = (Get-Setting 'PLUSEMU_YES' '0') -ne '1'
    $token = if ($env:PLUSEMU_CLOUDFLARE_TOKEN) { ConvertTo-SecureString $env:PLUSEMU_CLOUDFLARE_TOKEN -AsPlainText -Force }
    Remove-Item Env:\PLUSEMU_CLOUDFLARE_TOKEN -ErrorAction SilentlyContinue
    $script:CloudflareError = ''
    if ($interactive) {
        try { Start-Process (Join-Path (Join-Path $HotelRoot 'setup-guide') 'index.html') } catch { Write-Log "$_" }
        Say '  Your setup guide is open in your browser (also on your desktop: "Hotel setup guide").'
    } else {
        Say "  Your setup guide: $HotelRoot\setup-guide\index.html (also on your desktop: `"Hotel setup guide`")."
    }
    Say '  To let the installer set up Cloudflare for you, follow the guide''s section "Connect Cloudflare automatically".'
    $question = 'Paste your Cloudflare API token, or press Enter to skip and follow the manual steps in the guide'
    if ($state.CloudflareSetup -eq 'done') {
        Say '  Cloudflare is already connected.'
        $question = 'Press Enter to keep it, or paste a token to run it again'
    }
    while ($true) {
        if (-not $token -and $interactive) { $token = Read-Secret $question }
        if (-not $token -or $token.Length -eq 0) { break }
        $script:CloudflareToken = $token
        $script:CloudflareError = ''
        if (Invoke-CloudflareSetup) {
            $state | Add-Member -MemberType NoteProperty -Name CloudflareSetup -Value 'done' -Force
            $state | Add-Member -MemberType NoteProperty -Name CloudflareCertExpires -Value $script:CloudflareCertExpires -Force
            $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
            Ok 'Cloudflare is connected. Reload the setup guide to see what was set up.'
            break
        }
        Say "      $script:CloudflareError" 'Yellow'
        if (-not $interactive) { break }
        $retry = Read-Secret 'Fix it and press Enter to try again, paste a new token, or type skip'
        if ($retry.Length -eq 0) { continue }
        if ([Net.NetworkCredential]::new('', $retry).Password.Trim() -eq 'skip') { break }
        $token = $retry
    }
    $script:CloudflareToken = $null
    $token = $null
    $retry = $null
    if ($script:CloudflareError -and $state.CloudflareSetup -eq 'done') {
        Say '      The earlier Cloudflare setup stays as it was.' 'Yellow'
    } elseif ($script:CloudflareError) {
        Say '      The installer did not finish the Cloudflare setup. Follow the manual steps in the guide.' 'Yellow'
    } elseif ($state.CloudflareSetup -ne 'done') {
        Say '      Skipped. Follow the manual steps in the guide.'
    }
    Write-GuideFile
}

function Write-Guide {
    Step 'Writing your setup guide'
    Write-GuideFile
    Ok 'Guide written (also on your desktop)'
}

# The guide for this PC, in place of the server's Cloudflare guide.
function Write-LocalGuide($Guide) {
    Render (Join-Path $Templates 'guide-local.html') $Guide ([ordered]@{
        HOTEL_NAME = $state.HotelName; SITE_URL = Get-SiteUrl; ADMIN_USER = $state.AdminUser; LOCAL_FLAG = '-Local'
        CREDENTIALS_FILE = $StateFile; CREDENTIALS_COMMAND = "Get-Content $StateFile"
        START_COMMAND = 'Start-Service PlusEMU'; STOP_COMMAND = 'Stop-Service PlusEMU'; RESTART_COMMAND = 'Restart-Service PlusEMU'
        LOG_COMMAND = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait"
        STOP_ALL_COMMAND = 'Stop-Service PlusEMU, W3SVC, MariaDB'; HEALTH_RUN = "& '$HealthScript'"; UPDATE_RUN = 'plusemu-update'
        BACKUP_RUN = "Start-ScheduledTask 'PlusEMU nightly backup'"; BACKUP_DIR = $NightlyRoot
        SERVER_INSTALL = "irm https://raw.githubusercontent.com/$InstallerRepo/main/install.ps1 | iex"
    })
}

# The guide in its manual form, or in its connected form after the Cloudflare step.
function Write-GuideFile {
    $guide = Join-Path (Join-Path $HotelRoot 'setup-guide') 'index.html'
    New-Item -ItemType Directory -Force -Path (Split-Path $guide) | Out-Null
    if ($state.Local) {
        Write-LocalGuide $guide
        Copy-Item $guide "$([Environment]::GetFolderPath('Desktop'))\Hotel setup guide.html" -Force
        return
    }
    $mode = if ($state.GuideMode) { $state.GuideMode } else { 'simple' }
    $status = ''; $manualStart = ''; $manualEnd = ''; $gameAddress = ''
    $intro = 'Now connect <b>{{DOMAIN}}</b> through Cloudflare and install its origin certificate.'
    if ($state.CloudflareSetup -eq 'done') {
        $intro = 'Cloudflare is connected. Check your hotel below.'
        $status = [IO.File]::ReadAllText((Join-Path $Templates 'cloudflare-connected.html'))
        $manualStart = '<details class="card manual"><summary>If you need to do this by hand</summary>'
        $manualEnd = '</details>'
    }
    if ($script:CloudflareError) { $status += [IO.File]::ReadAllText((Join-Path $Templates 'cloudflare-failed.html')) }
    if ($WsHost -notin $state.Domain, "www.$($state.Domain)") { $gameAddress = ", the game address <code>$WsHost</code>" }
    $wsRow = ''
    if ($WsHost -ne $state.Domain) {
        $label = if ($WsHost.EndsWith(".$($state.Domain)")) { $WsHost.Substring(0, $WsHost.Length - $state.Domain.Length - 1) } else { $WsHost }
        $wsRow = "<tr><td>A</td><td><code>$label</code></td><td><code>$ServerIp</code></td><td>Proxied (orange cloud)</td></tr>"
    }
    # The fragments come first, so the placeholders inside them are filled too.
    Render (Join-Path $Templates 'setup-guide.html') $guide ([ordered]@{
        CLOUDFLARE_STATUS = $status; MANUAL_START = $manualStart; MANUAL_END = $manualEnd; GUIDE_INTRO = $intro; GAME_ADDRESS_ITEM = $gameAddress
        CERTIFICATE_EXPIRES = $state.CloudflareCertExpires; CLOUDFLARE_ERROR_HTML = [Net.WebUtility]::HtmlEncode("$script:CloudflareError")
        DOMAIN = $state.Domain; SERVER_IP = $ServerIp; HOTEL_NAME = $state.HotelName; WS_DNS_ROW = $wsRow; WS_HOST = $WsHost
        GUIDE_MODE_TITLE = (Get-Culture).TextInfo.ToTitleCase($mode)
        GUIDE_MODE_DETAILS = [IO.File]::ReadAllText((Join-Path $Templates "guide-$mode.html"))
        CREDENTIALS_FILE = $StateFile; RESTART_COMMAND = 'Restart-Service PlusEMU'
        LOG_COMMAND = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait"
    }) (Join-Path $Templates 'certificate-windows.html')
    Copy-Item $guide "$([Environment]::GetFolderPath('Desktop'))\Hotel setup guide.html" -Force
}

# Runs the health check once; it skips its run while the installer holds the lock.
function Invoke-InstallHealthCheck {
    if (-not $HealthScript -or -not (Test-Path $HealthScript)) { return }
    if ($script:InstallLock) { $script:InstallLock.Dispose(); $script:InstallLock = $null }
    try { $passed = Invoke-HealthCheck 6> $null } catch { $passed = $false; $script:HealthProblems = @("$_") }
    if ($passed) { Write-Host '  Health check: all checks passed.'; return }
    Write-Host '  Health check: something does not work yet:' -ForegroundColor Yellow
    foreach ($problem in $script:HealthProblems) { Write-Host "    $problem" }
}

function Open-LocalGuide {
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') {
        try { Start-Process (Join-Path (Join-Path $HotelRoot 'setup-guide') 'index.html') } catch { Write-Log "$_" }
        Say '  Your guide is open in your browser (also on your desktop: "Hotel setup guide").'
    } else {
        Say "  Your guide: $HotelRoot\setup-guide\index.html (also on your desktop: `"Hotel setup guide`")."
    }
}

function Complete-Install {
    Write-Host ''
    Write-Host 'Your hotel is installed!' -ForegroundColor Green
    Write-Host ''
    Invoke-InstallHealthCheck
    Write-Host ''
    $where = 'on this server, or through an SSH tunnel'
    if ($state.Local) {
        $where = 'on this PC'
        Write-Host '  Open your hotel on this PC: http://localhost (housekeeping: http://localhost/housekeeping).'
        Write-Host '  Your guide explains how to start, stop, update and back up the hotel (also on your desktop: "Hotel setup guide").'
    } elseif ($state.CloudflareSetup -eq 'done') {
        Write-Host "  Cloudflare is connected. Open https://$($state.Domain), log in and enter the hotel to check it."
        Write-Host '  The setup guide shows what the installer set up and what to check (also on your desktop: "Hotel setup guide").'
    } else {
        Write-Host '  One last part: connect your domain and install your Cloudflare origin certificate.'
        Write-Host '  Follow the setup guide (also on your desktop: "Hotel setup guide").'
    }
    Write-Host ''
    Write-Host "  Your admin login for $(Get-SiteUrl) (also saved in $StateFile):"
    Write-Host '      Username: ' -NoNewline; Write-Host $state.AdminUser -ForegroundColor White
    Write-Host '      Password: ' -NoNewline; Write-Host $state.AdminPassword -ForegroundColor White
    Write-Host ''
    Write-Host "  MariaDB connection ($($where)):"
    Write-Host '      Host: 127.0.0.1    Port: 3306    Database: plus    Username: hotel'
    Write-Host '      Password: ' -NoNewline; Write-Host $state.DbPassword -ForegroundColor White
    Write-Host '      Connect locally with mariadb.exe from the MariaDB bin folder:'
    Write-Host '        mariadb.exe --host=127.0.0.1 --port=3306 --user=hotel --password plus'
    Write-Host '      Database root username: root'
    Write-Host '      Database root password: ' -NoNewline; Write-Host $state.DbRootPassword -ForegroundColor White
    Write-Host ''
    Write-Host "  Retrieve saved passwords (Administrator PowerShell): Get-Content $StateFile"
    Write-Host '  Update the emulator, client and hotel files later (Administrator PowerShell): plusemu-update'
    Write-Host "  Nightly backups of the database and your settings: $NightlyRoot"
    Write-Host "  Check the hotel now (Administrator PowerShell): & '$HealthScript' (it runs every 5 minutes; log: $HealthLog)"
    if ($state.Local) { Write-Host '  This hotel works on this PC only. For a public hotel, run the installer without -Local on a server.' }
    Write-Host '  Store passwords somewhere safe. Change the initial admin password after logging in;'
    Write-Host '  the saved file retains the initial password. Keep passwords out of shared logs and screenshots.'
    Write-Host ''
}

# ---------------------------------------------------------------- update

# Copies the files of the installed folder that the new release lacks. Paths matching $Skip are not copied.
function Copy-MissingFiles($Old, $New, $Skip) {
    $base = (Get-Item -LiteralPath $Old).FullName.TrimEnd([IO.Path]::DirectorySeparatorChar)
    foreach ($file in Get-ChildItem -LiteralPath $Old -Recurse -File -Force) {
        $relative = $file.FullName.Substring($base.Length + 1).Replace([IO.Path]::DirectorySeparatorChar, '/')
        if ($Skip -and $relative -match $Skip) { continue }
        $target = Join-Path $New $relative
        if (Test-Path -LiteralPath $target) { continue }
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target
    }
}

# Deep merge like jq's "*": every value in $Overrides wins, nested objects are merged.
function Merge-Json($Defaults, $Overrides) {
    foreach ($property in $Overrides.PSObject.Properties) {
        $current = $Defaults.PSObject.Properties[$property.Name]
        if ($current -and $current.Value -is [Management.Automation.PSCustomObject] -and $property.Value -is [Management.Automation.PSCustomObject]) {
            Merge-Json $current.Value $property.Value | Out-Null
        } else {
            $Defaults | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }
    return $Defaults
}

function Copy-EmulatorSettings($Old, $New) {
    $oldConfig = Join-Path $Old 'Config'
    $newConfig = Join-Path $New 'Config'
    $defaults = Get-Content (Join-Path $newConfig 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # The release's own libraries replace the old ones; the other files it lacks are the hotel's.
    Copy-MissingFiles $Old $New '^([^/]+\.(dll|so|pdb|json)|backups/.*)$'
    if (Test-Path $oldConfig) { Copy-Item -Path (Join-Path $oldConfig '*') -Destination $newConfig -Recurse -Force }
    try { $installed = Get-Content (Join-Path $oldConfig 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Could not read $(Join-Path $oldConfig 'config.json'). Fix the file, then run the update again. Nothing was changed." }
    # Keep every installed setting and add the settings this release introduced.
    Write-Utf8 (Join-Path $newConfig 'config.json') ((Merge-Json $defaults $installed) | ConvertTo-Json -Depth 20)
}

function Copy-ClientSettings($Old, $New) {
    # Hashed bundles belong to one release; the other files the release lacks are the hotel's.
    Copy-MissingFiles $Old $New '^(src/)?assets/'
    $oldConfig = Join-Path $Old 'configuration'
    $newConfig = Join-Path $New 'configuration'
    New-Item -ItemType Directory -Force -Path $newConfig | Out-Null
    # The release ships the defaults of every setting it knows; the hotel's own files replace them below.
    $shipped = @{}
    foreach ($pair in @{ 'renderer-config.json' = 'renderer-config.json.example.json'; 'ui-config.json' = 'ui-config.example' }.GetEnumerator()) {
        $example = Join-Path $newConfig $pair.Value
        if (Test-Path $example) {
            try { $shipped[$pair.Key] = Get-Content $example -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
    }
    if (Test-Path $oldConfig) { Copy-Item -Path (Join-Path $oldConfig '*') -Destination $newConfig -Recurse -Force }
    $rendered = Join-Path $Downloads 'client-configuration'
    if (Test-Path $rendered) { Remove-Item $rendered -Recurse -Force }
    Write-ClientConfig $rendered
    foreach ($file in 'renderer-config.json', 'ui-config.json', 'client-mode.json') {
        $target = Join-Path $newConfig $file
        $defaults = Get-Content (Join-Path $rendered $file) -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($shipped.ContainsKey($file)) { $defaults = Merge-Json $shipped[$file] $defaults }
        if (-not (Test-Path $target)) { Write-Utf8 $target ($defaults | ConvertTo-Json -Depth 20); continue }
        try { $merged = Merge-Json $defaults (Get-Content $target -Raw -Encoding UTF8 | ConvertFrom-Json) }
        catch { Say "      Kept configuration/$file as it is: it is not plain JSON, so no new settings were added." 'Yellow'; continue }
        Write-Utf8 $target ($merged | ConvertTo-Json -Depth 20)
    }
    Remove-Item $rendered -Recurse -Force
}

function Invoke-DatabaseDump($File) {
    $dump = Join-Path (Split-Path (Get-MariaDb)) 'mariadb-dump.exe'
    $env:MYSQL_PWD = $state.DbRootPassword
    & cmd.exe /c "`"$dump`" -uroot --skip-ssl --single-transaction --routines --triggers --events plus > `"$File`" 2>> `"$script:Log`""
    $code = $LASTEXITCODE
    Remove-Item Env:\MYSQL_PWD
    if ($code -ne 0) { throw "Backing up the database failed (exit code $code). See $script:Log" }
}

function Invoke-DatabaseRestore($File) {
    Sql 'DROP DATABASE IF EXISTS plus; CREATE DATABASE plus CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' | Out-Null
    Import-Database $File
}

function Invoke-Migration($Dir) {
    Push-Location $Dir
    try { Run (Join-Path $Dir 'Plus Emulator.exe') --migrate } finally { Pop-Location }
}

function New-Snapshot($WithHotelFiles) {
    $snapshot = Join-Path $BackupRoot (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff')
    $partial = "$snapshot.partial"
    New-Item -ItemType Directory -Force -Path $partial | Out-Null
    Invoke-DatabaseDump (Join-Path $partial 'database.sql')
    # The emulator's own database backups stay in place and are not copied again.
    # Exit code 1 only means a file changed while it was read, for example a log of the running emulator.
    $code = Invoke-Tar @('-C', $HotelRoot, '--exclude=emulator/backups', '-czf', (Join-Path $partial 'files.tar.gz'), 'emulator', 'client')
    if ($code -notin 0, 1) { throw "Backing up the program files failed (tar exit code $code). See $script:Log" }
    if ($WithHotelFiles) {
        if ((Invoke-Tar @('-C', $HotelRoot, '-cf', (Join-Path $partial 'hotel-files.tar'), 'hotel-files')) -ne 0) { throw "Backing up the hotel files failed. See $script:Log" }
    }
    if (Test-Path $VersionsFile) { Copy-Item $VersionsFile (Join-Path $partial 'versions.json') }
    Move-Item $partial $snapshot
    return $snapshot
}

function Restore-Snapshot($Snapshot, $RestoreDatabase) {
    Stop-EmulatorService
    $staging = Join-Path $HotelRoot '.restore'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Path $staging | Out-Null
    if ((Invoke-Tar @('-xzf', (Join-Path $Snapshot 'files.tar.gz'), '-C', $staging)) -ne 0) { throw "Could not unpack the program files of $Snapshot." }
    $names = @('emulator', 'client')
    if (Test-Path (Join-Path $Snapshot 'hotel-files.tar')) {
        if ((Invoke-Tar @('-xf', (Join-Path $Snapshot 'hotel-files.tar'), '-C', $staging)) -ne 0) { throw "Could not unpack the hotel files of $Snapshot." }
        $names += 'hotel-files'
    }
    # The current folders are moved aside first, so a folder Windows does not allow to move leaves the hotel unchanged.
    $previous = Join-Path $staging 'previous'
    New-Item -ItemType Directory -Path $previous | Out-Null
    $moved = @()
    try {
        foreach ($name in $names) {
            $dir = Join-Path $HotelRoot $name
            if (Test-Path $dir) { Move-Folder $dir (Join-Path $previous $name); $moved += $name }
        }
    } catch {
        foreach ($name in $moved) { Move-Item (Join-Path $previous $name) (Join-Path $HotelRoot $name) }
        Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    # The emulator's own database backups are not in the snapshot. An unfinished update may have left them in its work folder.
    $stagedBackups = Join-Path (Join-Path $staging 'emulator') 'backups'
    $sources = @(Join-Path (Join-Path $previous 'emulator') 'backups')
    if ($script:Work) { $sources += (Join-Path (Join-Path $script:Work 'emulator.old') 'backups'), (Join-Path (Join-Path $script:Work 'emulator') 'backups') }
    $backups = $sources | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($backups -and -not (Test-Path $stagedBackups)) { Move-Item $backups $stagedBackups }
    foreach ($name in $names) { Move-Item (Join-Path $staging $name) (Join-Path $HotelRoot $name) }
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    Set-HotelPermissions
    if ($RestoreDatabase) { Invoke-DatabaseRestore (Join-Path $Snapshot 'database.sql') }
    if (Test-Path (Join-Path $Snapshot 'versions.json')) { Copy-Item (Join-Path $Snapshot 'versions.json') $VersionsFile -Force }
    else { Remove-Item $VersionsFile -ErrorAction SilentlyContinue }
    Start-EmulatorService
}

function Remove-OldSnapshots {
    if (-not (Test-Path $BackupRoot)) { return }
    Get-ChildItem $BackupRoot -Directory -Filter '*.partial' | Remove-Item -Recurse -Force
    $snapshots = @(Get-ChildItem $BackupRoot -Directory | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' } | Sort-Object Name)
    if ($snapshots.Count -gt $KeepBackups) { $snapshots[0..($snapshots.Count - $KeepBackups - 1)] | Remove-Item -Recurse -Force }
}

# Runs at the end of every update: undoes an unfinished update and removes temporary files.
function Complete-Update {
    $snapshot = $script:RestoreFrom
    $script:RestoreFrom = $null
    if ($snapshot) {
        Say ''
        Say "  Restoring the previous version from $snapshot ..."
        try {
            Restore-Snapshot $snapshot $script:RestoreDatabase
            Say '  Your hotel was restored to the version it had before this update.' 'Green'
        } catch {
            Write-Log "RESTORE ERROR: $_"
            try { Start-EmulatorService } catch { }
            Say "  The automatic restore failed. Your backup is in $snapshot" 'Red'
            Say "  (files.tar.gz and database.sql). The previous files are also in $($script:Work)."
            Say "  Ask for help on DevBest with the log: $script:Log"
            return
        }
    } elseif ($script:EmulatorStopped) {
        try { Start-EmulatorService } catch { }
    }
    $script:EmulatorStopped = $false
    if ($script:Work -and (Test-Path $script:Work)) { Remove-Item $script:Work -Recurse -Force }
    $script:Work = $null
}

function Get-FolderMegabytes($Dir, $Exclude = '') {
    if (-not (Test-Path $Dir)) { return 0 }
    $files = Get-ChildItem -LiteralPath $Dir -Recurse -File -Force
    if ($Exclude) { $files = $files | Where-Object { -not $_.FullName.StartsWith($Exclude) } }
    return [int](($files | Measure-Object Length -Sum).Sum / 1MB)
}

function Assert-UpdateSpace($WithHotelFiles) {
    # Staged copies and the backup of the files, plus two dumps of the database: the backup's and the emulator's own.
    $emulator = Join-Path $HotelRoot 'emulator'
    $filesMb = (Get-FolderMegabytes $emulator (Join-Path $emulator 'backups')) + (Get-FolderMegabytes (Join-Path $HotelRoot 'client'))
    $databaseMb = [int]"$(Sql "SELECT COALESCE(ROUND(SUM(data_length + index_length) / 1048576), 0) FROM information_schema.tables WHERE table_schema = 'plus'")".Trim()
    # Their backup, the downloaded pack and the files it adds.
    $hotelFilesMb = 0
    if ($WithHotelFiles) { $hotelFilesMb = Get-FolderMegabytes (Join-Path $HotelRoot 'hotel-files') }
    $needed = [int](($filesMb * 3 + $databaseMb * 2 + $hotelFilesMb * 3) / 1024 + 1)
    $free = (New-Object IO.DriveInfo $HotelRoot).AvailableFreeSpace / 1GB
    if ($free -lt $needed) { throw "Not enough disk space: $([int]$free) GB free, at least $needed GB needed." }
}

function Confirm-Update($Question) {
    if ($script:AssumeYes -or (Get-Setting 'PLUSEMU_YES' '0') -eq '1') { return }
    $go = Ask "$Question (y/n)" 'y'
    if ($go -notmatch '^[Yy]') { throw 'Cancelled. Nothing was changed.' }
}

function Restore-LastBackup {
    $target = Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' } | Sort-Object Name | Select-Object -Last 1
    if (-not $target) { throw "No backup found in $BackupRoot. Nothing was changed." }
    $name = $target.Name
    $versions = 'unknown versions'
    if (Test-Path (Join-Path $target.FullName 'versions.json')) {
        $saved = Get-Content (Join-Path $target.FullName 'versions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $versions = "emulator $($saved.EmulatorVersion), client $($saved.ClientVersion)"
    }
    $withHotelFiles = Test-Path (Join-Path $target.FullName 'hotel-files.tar')
    Say ''
    Say "Restore the backup from $($name.Substring(0, 4))-$($name.Substring(4, 2))-$($name.Substring(6, 2)) $($name.Substring(9, 2)):$($name.Substring(11, 2)) UTC ($versions)." 'White'
    Say '  The database goes back to that moment too: game changes made since then are lost.' 'Yellow'
    if ($withHotelFiles) { Say '  The hotel files go back to that moment as well.' 'Yellow' }
    Confirm-Update 'Restore this backup?'

    Assert-UpdateSpace $withHotelFiles
    $script:TotalSteps = 2
    $script:Step = 0
    Step 'Backing up the current state'
    # Set first, so the service starts again when stopping it fails.
    $script:EmulatorStopped = $true
    Stop-EmulatorService
    $snapshot = New-Snapshot $withHotelFiles
    Ok "Saved in $snapshot"
    Step 'Restoring the backup'
    $script:RestoreFrom = $snapshot
    $script:RestoreDatabase = $true
    Restore-Snapshot $target.FullName $true
    $script:RestoreFrom = $null
    $script:EmulatorStopped = $false
    if (-not (Wait-Emulator)) { throw "The restored emulator didn't start. See $(Join-Path (Join-Path (Join-Path $HotelRoot 'emulator') 'service') 'shawl_for_PlusEMU_rCURRENT.log')" }
    Remove-OldSnapshots
    Ok "Restored $($target.FullName)"
    Say ''
    Say '  Done. To undo this, run the same command again: plusemu-update -Rollback' 'Green'
}

# Refreshes only the hotel files, in place and without stopping the emulator.
function Update-HotelFiles([switch]$Check) {
    $latest = Get-PackVersion
    if (-not $latest) { throw "Could not find the latest hotel files. Check the server's internet connection." }
    $installed = $script:Versions.AssetsVersion
    Say ''
    Say 'PlusEMU hotel files update' 'White'
    if ($installed -eq $latest) { Say "  Hotel files: $installed (up to date)" 'Green'; return }
    Say "  Hotel files: $installed -> $latest (about 550 MB)"
    if ($Check) { Say ''; Say '  Install with: plusemu-update -Assets'; return }
    $free = (New-Object IO.DriveInfo $HotelRoot).AvailableFreeSpace / 1GB
    if ($free -lt 3) { throw "Not enough disk space: $([int]$free) GB free, at least 3 GB needed." }
    $hotelFiles = Join-Path $HotelRoot 'hotel-files'
    $archive = Join-Path $Downloads 'hotel-files.tar.gz'
    $pack = Get-PackLocation
    if (-not (Get-CheckedDownload $pack.Base $pack.Name $archive)) { throw 'Could not download the hotel files. Nothing was changed. Try again later.' }
    New-Item -ItemType Directory -Force -Path $hotelFiles | Out-Null
    # gamedata is the index of the stock content, so the pack's copy replaces it. The old copy stays for edited texts.
    $gamedata = Join-Path $hotelFiles 'gamedata'
    $copy = $null
    if (Test-Path $gamedata) {
        $copy = Join-Path $BackupRoot "gamedata-$installed"
        if (Test-Path $copy) { Remove-Item $copy -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
        Move-Item $gamedata $copy
        Say "  The previous gamedata folder is kept in $copy"
    }
    # -k keeps the files the hotel already has, so stock files the owner edited stay.
    if ((Invoke-Tar @('-xzf', $archive, '-k', '-C', $hotelFiles)) -ne 0) {
        # The installed index goes back, so the hotel keeps working.
        if ($copy) {
            if (Test-Path $gamedata) { Remove-Item $gamedata -Recurse -Force }
            Move-Item $copy $gamedata
        }
        throw "Unpacking the hotel files failed. The hotel files were not changed. See $script:Log"
    }
    Remove-Item $archive
    Remove-Item (Join-Path $hotelFiles '.complete') -Force -ErrorAction SilentlyContinue
    $script:Versions.AssetsVersion = $latest
    Save-Versions
    Ok "Hotel files $latest installed"
    Say "  The emulator's clothing data (Config\figuredata.xml) is refreshed by the full plusemu-update."
    Say '  Run that when new clothing does not show.'
}

function Update-Hotel([switch]$Check) {
    $latestEmulator = Get-ReleaseVersion $EmulatorRepo $EmulatorUrl
    if (-not $latestEmulator) { throw "Could not find the latest PlusEMU release. Check the server's internet connection." }
    $latestClient = Get-ReleaseVersion $ClientRepo $ClientUrl
    if (-not $latestClient) { throw "Could not find the latest Volt release. Check the server's internet connection." }
    $latestAssets = Get-PackVersion
    if (-not $latestAssets) { throw "Could not find the latest hotel files. Check the server's internet connection." }
    $installed = $script:Versions
    $updateEmulator = $installed.EmulatorVersion -ne $latestEmulator
    $updateClient = $installed.ClientVersion -ne $latestClient
    $updateAssets = $installed.AssetsVersion -ne $latestAssets
    Say ''
    Say 'PlusEMU hotel update' 'White'
    if ($updateEmulator) {
        Say "  Emulator (PlusEMU): $($installed.EmulatorVersion) -> $latestEmulator"
    } elseif ($updateAssets) {
        # The emulator release carries the clothing data (Config/figuredata.xml) that matches the stock hotel files.
        $updateEmulator = $true
        Say "  Emulator (PlusEMU): $($installed.EmulatorVersion) (reinstalled to load the new clothing data)"
    } else {
        Say "  Emulator (PlusEMU): $($installed.EmulatorVersion) (up to date)"
    }
    if ($updateClient) { Say "  Client (Volt):      $($installed.ClientVersion) -> $latestClient" }
    else { Say "  Client (Volt):      $($installed.ClientVersion) (up to date)" }
    if ($updateAssets) { Say "  Hotel files:        $($installed.AssetsVersion) -> $latestAssets (about 550 MB)" }
    else { Say "  Hotel files:        $($installed.AssetsVersion) (up to date)" }
    if (-not $updateEmulator -and -not $updateClient -and -not $updateAssets) {
        Say ''
        Say '  Everything is up to date.' 'Green'
        return
    }
    if ($Check) {
        Say ''
        Say '  Install the update with: plusemu-update'
        return
    }
    Say ''
    Say '  Your settings and added files are kept, and a backup is made first.'
    if ($updateAssets) { Say '  Stock hotel files are replaced by the new ones. Files you added to hotel-files are kept.' }
    if ($updateEmulator) { Say '  Players are disconnected for about a minute.' }
    Confirm-Update 'Update now?'

    Assert-UpdateSpace $updateAssets
    $script:Work = Join-Path $HotelRoot ".update-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $script:Work | Out-Null
    $script:TotalSteps = 4
    $script:Step = 0
    $emulator = Join-Path $HotelRoot 'emulator'
    $client = Join-Path $HotelRoot 'client'
    $hotelFiles = Join-Path $HotelRoot 'hotel-files'
    $newEmulator = Join-Path $script:Work 'emulator'
    $newClient = Join-Path $script:Work 'client'
    $archive = Join-Path $script:Work 'hotel-files.tar.gz'

    Step 'Downloading the new versions'
    if ($updateEmulator) {
        Expand-EmulatorRelease $latestEmulator $newEmulator
        $figuredata = Join-Path (Join-Path $newEmulator 'Config') 'figuredata.xml'
        $releaseFiguredata = Join-Path $script:Work 'figuredata.xml'
        if ($updateAssets) { Copy-Item $figuredata $releaseFiguredata }
        Copy-EmulatorSettings $emulator $newEmulator
        if ($updateAssets) { Move-Item $releaseFiguredata $figuredata -Force }
        Ok "PlusEMU $latestEmulator (your settings and added files are kept)"
    }
    if ($updateClient) {
        Get-InstallerFiles
        Expand-ClientRelease $latestClient $newClient
        Copy-ClientSettings $client $newClient
        Ok "Volt $latestClient (your configuration and added files are kept)"
    }
    if ($updateAssets) {
        $pack = Get-PackLocation
        if (-not (Get-CheckedDownload $pack.Base $pack.Name $archive)) { throw 'Could not download the hotel files. Nothing was changed. Try again later.' }
        Ok "Hotel files $latestAssets"
    }

    Step 'Backing up your hotel'
    if ($updateEmulator) {
        $script:EmulatorStopped = $true
        Stop-EmulatorService
    }
    if ($updateAssets) { New-Item -ItemType Directory -Force -Path $hotelFiles | Out-Null }
    $snapshot = New-Snapshot $updateAssets
    Ok "Your hotel is saved in $snapshot"
    $script:RestoreFrom = $snapshot
    $script:RestoreDatabase = $false

    Step 'Installing the new versions'
    if ($updateEmulator) {
        $oldEmulator = Join-Path $script:Work 'emulator.old'
        Move-Folder $emulator $oldEmulator
        Move-Item $newEmulator $emulator
        $backups = Join-Path $oldEmulator 'backups'
        if (Test-Path $backups) { Move-Item $backups (Join-Path $emulator 'backups') }
        $script:RestoreDatabase = $true
        Invoke-Migration $emulator
        Ok "PlusEMU $latestEmulator installed and the database updated"
    }
    if ($updateClient) {
        Move-Folder $client (Join-Path $script:Work 'client.old')
        Move-Item $newClient $client
        Ok "Volt $latestClient installed"
    }
    if ($updateAssets) {
        New-Item -ItemType Directory -Force -Path $hotelFiles | Out-Null
        if ((Invoke-Tar @('-xzf', $archive, '-C', $hotelFiles)) -ne 0) { throw "Unpacking the hotel files failed. See $script:Log" }
        Ok "Hotel files $latestAssets installed"
    }
    Set-HotelPermissions

    Step 'Starting the emulator'
    if ($updateEmulator) {
        Start-EmulatorService
        if (-not (Wait-Emulator)) { throw "The new emulator didn't start. See $(Join-Path (Join-Path $emulator 'service') 'shawl_for_PlusEMU_rCURRENT.log')" }
        $script:EmulatorStopped = $false
        Ok 'The emulator is running'
    } else {
        Ok 'The emulator kept running'
    }
    $script:RestoreFrom = $null
    $script:Versions.EmulatorVersion = $latestEmulator
    $script:Versions.ClientVersion = $latestClient
    if ($updateAssets) { $script:Versions.AssetsVersion = $latestAssets }
    Save-Versions
    Remove-OldSnapshots
    Write-UpdateCommand

    Say ''
    Say 'Your hotel is up to date.' 'Green'
    Say "  Emulator: $($script:Versions.EmulatorVersion)    Client: $($script:Versions.ClientVersion)    Hotel files: $($script:Versions.AssetsVersion)"
    Say '  Players get the new client when they reload the hotel page.'
    Say "  Backup of the previous version: $snapshot"
    Say '  Undo this update: plusemu-update -Rollback'
    Say '  Next time, update with: plusemu-update'
    Say ''
}

function Invoke-Update([switch]$Check, [switch]$Yes, [switch]$Rollback, [switch]$Assets) {
    Assert-Administrator
    if (-not (Test-Path $StateFile) -or -not (Test-Path (Join-Path (Join-Path $HotelRoot 'emulator') 'Plus Emulator.exe'))) {
        throw 'No hotel from the PlusEMU installer was found on this server. Install one first.'
    }
    New-Item -ItemType Directory -Force -Path $StateDir, $Downloads | Out-Null
    try { $lock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
    catch { throw "Another update is already running (could not lock $LockFile)." }
    try {
        $script:Log = $UpdateLog
        Set-Content -Path $script:Log -Value "PlusEMU update log $(Get-Date -Format s)" -Encoding UTF8
        $script:AssumeYes = [bool]$Yes
        $script:state = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Read-Versions
        $script:RestoreFrom = $null
        $script:RestoreDatabase = $false
        $script:EmulatorStopped = $false
        $script:Work = $null
        try {
            if ($Rollback) { Restore-LastBackup }
            elseif ($Assets) { Update-HotelFiles -Check:$Check }
            else { Update-Hotel -Check:$Check }
        } finally {
            Complete-Update
        }
    } finally {
        $lock.Dispose()
    }
}

function Install-Hotel {
    Get-InstallerFiles
    $first = -not (Test-Path $StateFile)
    Read-Answers
    if ($state.Local) {
        $script:TotalSteps = 11
        # A first run that stops here keeps no settings, so this PC can still get a server install.
        try { Assert-FreePorts }
        catch {
            if ($first) { Remove-Item $StateFile -ErrorAction SilentlyContinue }
            throw
        }
    }
    Say "  Admin and database passwords are saved in $StateFile. Retrieve them in Administrator PowerShell: Get-Content $StateFile"
    Get-Derived
    Install-WebServer
    Install-Toolchains
    Install-Database
    Get-Releases
    Initialize-HotelDatabase
    Get-HotelFiles
    Start-Emulator
    Write-ClientConfig
    Install-Cms
    Set-IisSite
    Protect-Server
    Write-Guide
    Write-UpdateCommand
    if ($state.Local) { Open-LocalGuide } else { Connect-Cloudflare }
    Complete-Install
}

try {
    if ($Update) {
        Invoke-Update -Check:$Check -Yes:$Yes -Rollback:$Rollback -Assets:$Assets
    } else {
        Test-Prerequisites
        # Updates, backups and the health check wait for the installer.
        try { $script:InstallLock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'An update or a backup is running. Try again in a few minutes.' }
        Install-Hotel
    }
} catch {
    Write-Log "ERROR: $_`n$($_.ScriptStackTrace)"
    Write-Host ''
    Write-Host "Something went wrong: $_" -ForegroundColor Red
    if (Test-Path $script:Log) {
        Write-Host '  The last lines of the log:'
        Get-Content $script:Log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    }
    Write-Host ''
    Write-Host "  Full log: $script:Log"
    if ($Update) {
        Write-Host '  Fix the problem (or ask for help on DevBest with the log), then run plusemu-update again.'
    } else {
        if (Test-Path $StateFile) { Write-Host "  Saved passwords: Get-Content $StateFile (Administrator PowerShell; keep this file private)." }
        Write-Host '  Fix the problem (or ask for help on DevBest with the log), then run the installer again.'
        Write-Host '  It continues where it stopped.'
    }
} finally {
    if ($script:InstallLock) { $script:InstallLock.Dispose() }
    # irm | iex runs in the owner's own window, which keeps the PC's own Node.js afterwards.
    if ($script:LocalNode) { $env:Path = $env:Path.Replace("$script:LocalNode;", ''); $script:LocalNode = $null }
    foreach ($name in 'MYSQL_PWD', 'ATOM_ADMIN_PASSWORD', 'ADMIN_PASSWORD') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $ErrorActionPreference = $SessionPreferences.ErrorAction
    $ProgressPreference = $SessionPreferences.Progress
}
