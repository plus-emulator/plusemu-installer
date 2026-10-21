# PlusEMU hotel installer for Windows Server 2019/2022/2025 (IIS).
#
#   Open PowerShell as Administrator and run:
#   irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
#
# Installs and wires together: PlusEMU (emulator, as a Windows service) and Volt
# (client) from their latest GitHub releases, Atom CMS (website), MariaDB, PHP,
# IIS and the hotel files. Everything is self-hosted on this server; Cloudflare
# sits in front. Safe to run again: settings are reused and finished steps are kept.
#
# Unattended runs can preset the answers: PLUSEMU_DOMAIN, PLUSEMU_WS_URL,
# PLUSEMU_HOTEL_NAME, PLUSEMU_ADMIN_USER, PLUSEMU_ADMIN_EMAIL, PLUSEMU_YES=1.
# PLUSEMU_GUIDE_MODE=simple|advanced selects the final instructions only.
#
# Update an installed hotel (PlusEMU, the Volt client and the hotel files) later with:
#   plusemu-update [-Check] [-Yes] [-Assets] [-Rollback]
# or, when that command is missing, with the installer itself:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1))) -Update
# -WithAssets is accepted for older instructions and ignored: the hotel files are always part of an update.

param([string]$GuideMode, [switch]$Update, [switch]$Check, [switch]$Yes, [switch]$Rollback, [switch]$Assets, [switch]$WithAssets)

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
$UpdateLog     = Join-Path $StateDir 'update.log'
$LockFile      = Join-Path $StateDir 'update.lock'
$KeepBackups   = 3
$Downloads  = Join-Path $env:TEMP 'plusemu-downloads'
$script:Log        = "$StateDir\install.log"
$PhpDir     = 'C:\PHP'
$NodeMajor  = 22
$MariaDbSeries = '11.4'
$script:TotalSteps = 10
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
    $saved = Get-Content $VersionsFile -Raw | ConvertFrom-Json
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
    if ([Environment]::OSVersion.Version.Build -lt 17763) { throw 'Windows Server 2019 or newer is required.' }
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

function Read-Answers {
    $selectedMode = Resolve-GuideMode
    Write-Host ''
    Write-Host 'Welcome to the PlusEMU hotel installer!' -ForegroundColor White
    Write-Host 'This sets up your emulator, client and website on this server in about 10 minutes.'
    Write-Host ''

    if (Test-Path $StateFile) {
        $script:state = Get-Content $StateFile -Raw | ConvertFrom-Json
        $selectedMode = Resolve-GuideMode $state.GuideMode
        $state | Add-Member -MemberType NoteProperty -Name GuideMode -Value $selectedMode -Force
        $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
        Say "Found the settings of an earlier run for $($state.Domain); continuing that installation."
        Say "  Setup guide: $selectedMode. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
        return
    }

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

    $suggested = (Get-Culture).TextInfo.ToTitleCase($domain.Split('.')[0])
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
        if (-not $mail) { $mail = Ask 'Email for your admin account' "admin@$domain" }
        if ($mail -match '^[^@\s'']+@[^@\s'']+\.[^@\s'']+$') { break }
        Write-Host "  That doesn't look like an email address." -ForegroundColor Yellow
        $mail = ''
    }

    Write-Host ''
    Write-Host "  Website:    https://$domain"
    Write-Host "  WebSocket:  $ws"
    Write-Host "  Hotel name: $name"
    Write-Host "  Admin:      $user ($mail)"
    Write-Host "  Setup guide: $selectedMode. Selecting this guide does not change SSH, RDP, firewall, updates or backups."
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') {
        $go = Ask 'Start the installation? (y/n)' 'y'
        if ($go -notmatch '^[Yy]') { throw 'Installation cancelled. Nothing was changed.' }
    }

    $script:state = [pscustomobject]@{
        Domain = $domain; WsUrl = $ws; HotelName = $name; AdminUser = $user; AdminEmail = $mail
        GuideMode = $selectedMode
        AdminPassword = New-AdminPassword; DbPassword = New-Secret 32; DbRootPassword = New-Secret 32
    }
    $state | ConvertTo-Json | Set-Content $StateFile -Encoding UTF8
}

function Get-Derived {
    $rest = $state.WsUrl.Substring(6)
    $script:WsHost = $rest.Split('/')[0]
    $script:WsPath = if ($rest.Contains('/')) { $rest.Substring($rest.IndexOf('/') + 1) } else { '' }
    try { $script:ServerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10).Trim() }
    catch { $script:ServerIp = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' } | Select-Object -First 1).IPAddress }
}

function Install-WebServer {
    Step 'Installing IIS with URL Rewrite, reverse proxy and WebSockets'
    $features = 'Web-Server', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Http-Errors', 'Web-Http-Logging',
                'Web-Stat-Compression', 'Web-Dyn-Compression', 'Web-Filtering', 'Web-CGI', 'Web-WebSockets', 'Web-Mgmt-Console'
    $result = Install-WindowsFeature -Name $features
    if (-not $result.Success) { throw 'Installing IIS failed.' }
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
    Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/proxy' -Name 'enabled' -Value 'True'
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

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node -or -not ((& node --version) -like "v$NodeMajor.*")) {
        $base = "https://nodejs.org/dist/latest-v$NodeMajor.x"
        $sums = (Invoke-WebRequest "$base/SHASUMS256.txt" -UseBasicParsing).Content -split "`n"
        $line = $sums | Where-Object { $_ -match 'node-v[\d.]+-x64\.msi$' } | Select-Object -First 1
        $hash, $file = $line -split '\s+'
        Download "$base/$file" "$Downloads\$file"
        if ((Get-FileHash "$Downloads\$file" -Algorithm SHA256).Hash -ne $hash.ToUpper()) { throw 'The Node.js download is damaged. Run the installer again.' }
        Install-Msi "$Downloads\$file"
        Update-Path
    }
    Ok "Node.js $(& node --version)"

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
        Set-Content "$PhpDir\composer.bat" "@php `"%~dp0composer.phar`" %*" -Encoding ASCII
    }
    Ok 'Composer'
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

function Write-ClientConfig($Dir = (Join-Path (Join-Path $HotelRoot 'client') 'configuration')) {
    # Newer emulators build FurnitureData.json from the furniture table; older ones need the static file.
    $furnidata = '${gamedata.url}/FurnitureData.json?t=%timestamp%'
    try {
        Invoke-WebRequest 'http://127.0.0.1:8080/api/gamedata/furnidata' -UseBasicParsing -TimeoutSec 30 | Out-Null
        $furnidata = "https://$($state.Domain)/api/gamedata/furnidata"
    } catch { }
    $values = @{ DOMAIN = $state.Domain; SOCKET_URL = $state.WsUrl; FURNIDATA_URL = $furnidata }
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
    $json = Get-Content $config -Raw | ConvertFrom-Json
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

function Stop-EmulatorService { Stop-Service PlusEMU }
function Start-EmulatorService { Start-Service PlusEMU }

function Install-Cms {
    Step 'Installing the Atom CMS website'
    $cms = "$HotelRoot\cms"
    $envFile = "$cms\.env"
    $domain = $state.Domain
    Push-Location $cms
    if (-not (Test-Path $envFile)) { Copy-Item .env.example $envFile }
    # Laravel trusts the visitor address Cloudflare forwards, but only from Cloudflare itself.
    $cloudflare = try { ((Invoke-WebRequest 'https://www.cloudflare.com/ips-v4' -UseBasicParsing).Content.Trim() -split '\s+') + ((Invoke-WebRequest 'https://www.cloudflare.com/ips-v6' -UseBasicParsing).Content.Trim() -split '\s+') }
    catch {
        @('173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18', '108.162.192.0/18', '190.93.240.0/20',
          '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17', '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13',
          '131.0.72.0/22', '2400:cb00::/32', '2606:4700::/32', '2803:f800::/32', '2405:b500::/32', '2405:8100::/32', '2a06:98c0::/29', '2c0f:f248::/32')
    }
    $settings = [ordered]@{
        APP_NAME = $state.HotelName; APP_ENV = 'production'; APP_DEBUG = 'false'; APP_URL = "https://$domain"; LOG_LEVEL = 'warning'
        DB_CONNECTION = 'mariadb'; DB_HOST = '127.0.0.1'; DB_PORT = '3306'; DB_DATABASE = 'plus'; DB_USERNAME = 'hotel'; DB_PASSWORD = $state.DbPassword
        EMULATOR_DRIVER = 'plus'; CLIENT_NITRO_ENABLED = 'true'; NITRO_CLIENT_PATH = "https://$domain/client"
        RCON_HOST = '127.0.0.1'; RCON_PORT = '30001'; FORCE_HTTPS = 'true'; SESSION_SECURE_COOKIE = 'true'
        TRUSTED_PROXIES = ($cloudflare -join ',')
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
        nitro_path = "https://$domain/client"; rcon_ip = '127.0.0.1'; rcon_port = '30001'
        badges_path = "https://$domain/hotel-files/c_images/album1584"; furniture_icons_path = "https://$domain/hotel-files/c_images/hof_furni/icons"
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
    Step 'Configuring the IIS website, HTTPS and the firewall'
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
    if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site' }

    if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null }
    Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
    if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
        New-Website -Name $site -PhysicalPath "$HotelRoot\cms\public" -ApplicationPool $pool -HostHeader $domain -Port 80 | Out-Null
    }
    if (-not (Get-WebConfiguration -PSPath $apphost -Location $site -Filter "system.webServer/defaultDocument/files/add[@value='index.php']")) {
        Add-WebConfigurationProperty -PSPath $apphost -Location $site -Filter 'system.webServer/defaultDocument/files' -Name '.' -Value @{ value = 'index.php' } -AtIndex 0
    }
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
    Add-WebConfigurationProperty -PSPath $apphost -Filter $rules -Name '.' -Value @{ name = 'PlusEMU www'; stopProcessing = 'True' }
    Set-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU www']/match" -Name 'url' -Value '(.*)'
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU www']/conditions" -Name '.' -Value @{ input = '{HTTP_HOST}'; pattern = "^www\.$([regex]::Escape($domain))$" }
    $action = "$rules/rule[@name='PlusEMU www']/action"
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'type' -Value 'Redirect'
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'url' -Value "https://$domain/{R:1}"
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'redirectType' -Value 'Permanent'

    Add-WebConfigurationProperty -PSPath $apphost -Filter $rules -Name '.' -Value @{ name = 'PlusEMU websocket'; stopProcessing = 'True' }
    Set-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/match" -Name 'url' -Value "^$([regex]::Escape($WsPath))$"
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/conditions" -Name '.' -Value @{ input = '{HTTP_HOST}'; pattern = "^$([regex]::Escape($WsHost))$" }
    Add-WebConfigurationProperty -PSPath $apphost -Filter "$rules/rule[@name='PlusEMU websocket']/conditions" -Name '.' -Value @{ input = '{HTTP_ORIGIN}'; pattern = "^https://$([regex]::Escape($domain))$" }
    $action = "$rules/rule[@name='PlusEMU websocket']/action"
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'type' -Value 'Rewrite'
    Set-WebConfigurationProperty -PSPath $apphost -Filter $action -Name 'url' -Value 'http://127.0.0.1:2096/'

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
    Start-Website -Name $site -ErrorAction SilentlyContinue
    if ((Get-WebAppPoolState -Name $pool).Value -eq 'Started') { Restart-WebAppPool -Name $pool } else { Start-WebAppPool -Name $pool }
    Ok "IIS serves https://$domain"

    foreach ($port in 80, 443) {
        if (-not (Get-NetFirewallRule -Name "PlusEMU-$port" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name "PlusEMU-$port" -DisplayName "Hotel website (TCP $port)" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
        }
    }
    Ok 'Firewall allows HTTP and HTTPS (the database and emulator stay private)'
}

function Set-HotelPermissions {
    # IIS needs to read the client and the hotel files; only administrators may read the emulator's passwords.
    foreach ($dir in 'client', 'hotel-files') {
        $path = Join-Path $HotelRoot $dir
        if (Test-Path $path) { Run icacls.exe $path /grant 'IIS_IUSRS:(OI)(CI)RX' 'IUSR:(OI)(CI)RX' /Q }
    }
    Run icacls.exe (Join-Path (Join-Path $HotelRoot 'emulator') 'Config') /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F'
}

function Write-Guide {
    Step 'Writing your setup guide'
    $mode = if ($state.GuideMode) { $state.GuideMode } else { 'simple' }
    $wsRow = ''
    if ($WsHost -ne $state.Domain) {
        $label = if ($WsHost.EndsWith(".$($state.Domain)")) { $WsHost.Substring(0, $WsHost.Length - $state.Domain.Length - 1) } else { $WsHost }
        $wsRow = "<tr><td>A</td><td><code>$label</code></td><td><code>$ServerIp</code></td><td>Proxied (orange cloud)</td></tr>"
    }
    New-Item -ItemType Directory -Force -Path "$HotelRoot\setup-guide" | Out-Null
    Render "$Templates\setup-guide.html" "$HotelRoot\setup-guide\index.html" @{
        DOMAIN = $state.Domain; SERVER_IP = $ServerIp; HOTEL_NAME = $state.HotelName; WS_DNS_ROW = $wsRow; WS_HOST = $WsHost
        GUIDE_MODE_TITLE = (Get-Culture).TextInfo.ToTitleCase($mode)
        GUIDE_MODE_DETAILS = [IO.File]::ReadAllText("$Templates\guide-$mode.html")
        CREDENTIALS_FILE = $StateFile; RESTART_COMMAND = 'Restart-Service PlusEMU'
        LOG_COMMAND = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait"
    } "$Templates\certificate-windows.html"
    Copy-Item "$HotelRoot\setup-guide\index.html" "$([Environment]::GetFolderPath('Desktop'))\Hotel setup guide.html" -Force
    Ok 'Guide written (also on your desktop)'
}

function Complete-Install {
    Write-Host ''
    Write-Host 'Your hotel is installed!' -ForegroundColor Green
    Write-Host ''
    Write-Host '  One last part: connect your domain and install your Cloudflare origin certificate.'
    Write-Host '  The setup guide is opening in your browser now (also on your desktop: "Hotel setup guide").'
    Write-Host ''
    Write-Host "  Your admin login for https://$($state.Domain) (also saved in $StateFile):"
    Write-Host '      Username: ' -NoNewline; Write-Host $state.AdminUser -ForegroundColor White
    Write-Host '      Password: ' -NoNewline; Write-Host $state.AdminPassword -ForegroundColor White
    Write-Host ''
    Write-Host '  MariaDB connection (on this server, or through an SSH tunnel):'
    Write-Host '      Host: 127.0.0.1    Port: 3306    Database: plus    Username: hotel'
    Write-Host '      Password: ' -NoNewline; Write-Host $state.DbPassword -ForegroundColor White
    Write-Host '      Connect locally with mariadb.exe from the MariaDB bin folder:'
    Write-Host '        mariadb.exe --host=127.0.0.1 --port=3306 --user=hotel --password plus'
    Write-Host '      Database root username: root'
    Write-Host '      Database root password: ' -NoNewline; Write-Host $state.DbRootPassword -ForegroundColor White
    Write-Host ''
    Write-Host "  Retrieve saved passwords (Administrator PowerShell): Get-Content $StateFile"
    Write-Host '  Update the emulator, client and hotel files later (Administrator PowerShell): plusemu-update'
    Write-Host '  Store passwords somewhere safe. Change the initial admin password after logging in;'
    Write-Host '  the saved file retains the initial password. Keep passwords out of shared logs and screenshots.'
    Write-Host ''
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') { Start-Process "$HotelRoot\setup-guide\index.html" }
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
    $defaults = Get-Content (Join-Path $newConfig 'config.json') -Raw | ConvertFrom-Json
    # The release's own libraries replace the old ones; the other files it lacks are the hotel's.
    Copy-MissingFiles $Old $New '^([^/]+\.(dll|so|pdb|json)|backups/.*)$'
    if (Test-Path $oldConfig) { Copy-Item -Path (Join-Path $oldConfig '*') -Destination $newConfig -Recurse -Force }
    try { $installed = Get-Content (Join-Path $oldConfig 'config.json') -Raw | ConvertFrom-Json }
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
    if (Test-Path $oldConfig) { Copy-Item -Path (Join-Path $oldConfig '*') -Destination $newConfig -Recurse -Force }
    $rendered = Join-Path $Downloads 'client-configuration'
    if (Test-Path $rendered) { Remove-Item $rendered -Recurse -Force }
    Write-ClientConfig $rendered
    foreach ($file in 'renderer-config.json', 'ui-config.json', 'client-mode.json') {
        $target = Join-Path $newConfig $file
        if (-not (Test-Path $target)) { Copy-Item (Join-Path $rendered $file) $target; continue }
        try { $merged = Merge-Json (Get-Content (Join-Path $rendered $file) -Raw | ConvertFrom-Json) (Get-Content $target -Raw | ConvertFrom-Json) }
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
    $hotelFiles = Join-Path $HotelRoot 'hotel-files'
    if (Test-Path (Join-Path $Snapshot 'hotel-files.tar')) {
        if ((Invoke-Tar @('-xf', (Join-Path $Snapshot 'hotel-files.tar'), '-C', $staging)) -ne 0) { throw "Could not unpack the hotel files of $Snapshot." }
        if (Test-Path $hotelFiles) { Remove-Item $hotelFiles -Recurse -Force }
        Move-Item (Join-Path $staging 'hotel-files') $hotelFiles
    }
    $emulator = Join-Path $HotelRoot 'emulator'
    $client = Join-Path $HotelRoot 'client'
    $backups = Join-Path $emulator 'backups'
    $stagedBackups = Join-Path (Join-Path $staging 'emulator') 'backups'
    if ((Test-Path $backups) -and -not (Test-Path $stagedBackups)) { Move-Item $backups $stagedBackups }
    foreach ($dir in $emulator, $client) { if (Test-Path $dir) { Remove-Item $dir -Recurse -Force } }
    Move-Item (Join-Path $staging 'emulator') $emulator
    Move-Item (Join-Path $staging 'client') $client
    Remove-Item $staging -Recurse -Force
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
        $saved = Get-Content (Join-Path $target.FullName 'versions.json') -Raw | ConvertFrom-Json
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
    Stop-EmulatorService
    $script:EmulatorStopped = $true
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
    $hotelFiles = Join-Path $HotelRoot 'hotel-files'
    $archive = Join-Path $Downloads 'hotel-files.tar.gz'
    $pack = Get-PackLocation
    if (-not (Get-CheckedDownload $pack.Base $pack.Name $archive)) { throw 'Could not download the hotel files. Nothing was changed. Try again later.' }
    # gamedata is the index of the stock content, so the pack's copy replaces it. The old copy stays for edited texts.
    $gamedata = Join-Path $hotelFiles 'gamedata'
    if (Test-Path $gamedata) {
        $copy = Join-Path $BackupRoot "gamedata-$installed"
        if (Test-Path $copy) { Remove-Item $copy -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null
        Move-Item $gamedata $copy
        Say "  The previous gamedata folder is kept in $copy"
    }
    New-Item -ItemType Directory -Force -Path $hotelFiles | Out-Null
    # -k keeps the files the hotel already has, so stock files the owner edited stay.
    if ((Invoke-Tar @('-xzf', $archive, '-k', '-C', $hotelFiles)) -ne 0) { throw "Unpacking the hotel files failed. See $script:Log" }
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
        Stop-EmulatorService
        $script:EmulatorStopped = $true
    }
    if ($updateAssets) { New-Item -ItemType Directory -Force -Path $hotelFiles | Out-Null }
    $snapshot = New-Snapshot $updateAssets
    Ok "Your hotel is saved in $snapshot"
    $script:RestoreFrom = $snapshot
    $script:RestoreDatabase = $false

    Step 'Installing the new versions'
    if ($updateEmulator) {
        $backups = Join-Path $emulator 'backups'
        if (Test-Path $backups) { Move-Item $backups (Join-Path $newEmulator 'backups') }
        Move-Item $emulator (Join-Path $script:Work 'emulator.old')
        Move-Item $newEmulator $emulator
        $script:RestoreDatabase = $true
        Invoke-Migration $emulator
        Ok "PlusEMU $latestEmulator installed and the database updated"
    }
    if ($updateClient) {
        Move-Item $client (Join-Path $script:Work 'client.old')
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
        $script:state = Get-Content $StateFile -Raw | ConvertFrom-Json
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

try {
    if ($Update) {
        Invoke-Update -Check:$Check -Yes:$Yes -Rollback:$Rollback -Assets:$Assets
    } else {
        Test-Prerequisites
        Get-InstallerFiles
        Read-Answers
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
        Write-Guide
        Write-UpdateCommand
        Complete-Install
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
    foreach ($name in 'MYSQL_PWD', 'ATOM_ADMIN_PASSWORD', 'ADMIN_PASSWORD') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $ErrorActionPreference = $SessionPreferences.ErrorAction
    $ProgressPreference = $SessionPreferences.Progress
}
