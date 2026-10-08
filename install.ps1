# PlusEMU hotel installer for Windows Server 2019/2022/2025 (IIS).
#
#   Open PowerShell as Administrator and run:
#   irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/install.ps1 | iex
#
# Installs and wires together: PlusEMU (emulator, as a Windows service) and Octane
# (client) from their latest GitHub releases, Atom CMS (website), MariaDB, PHP,
# IIS and the hotel files. Everything is self-hosted on this server; Cloudflare
# sits in front. Safe to run again: settings are reused and finished steps are kept.
#
# Unattended runs can preset the answers: PLUSEMU_DOMAIN, PLUSEMU_WS_URL,
# PLUSEMU_HOTEL_NAME, PLUSEMU_ADMIN_USER, PLUSEMU_ADMIN_EMAIL, PLUSEMU_YES=1.

function Get-Setting($Name, $Default) {
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value } else { return $Default }
}

$InstallerRepo   = Get-Setting 'INSTALLER_REPO' 'plus-emulator/plusemu-installer'
$InstallerRef    = Get-Setting 'INSTALLER_REF' 'main'
$AssetPackUrl    = Get-Setting 'ASSET_PACK_URL' 'https://github.com/plus-emulator/plusemu-installer/releases/latest/download/hotel-files.tar.gz'
$EmulatorUrl     = Get-Setting 'EMULATOR_URL' 'https://github.com/plus-emulator/PlusEMU/releases/latest/download/plusemu-win-x64.zip'
$ClientUrl       = Get-Setting 'CLIENT_URL' 'https://github.com/plus-emulator/Octane/releases/latest/download/octane-client.zip'
$AtomRepo        = Get-Setting 'ATOM_REPO' 'https://github.com/atom-projects/atom-cms.git'
# "auto" picks the Atom CMS that matches the downloaded emulator's database (see Get-Releases).
$AtomRef         = Get-Setting 'ATOM_REF' 'auto'

$HotelRoot  = 'C:\Hotel'
$StateDir   = 'C:\ProgramData\PlusEMU'
$StateFile  = "$StateDir\hotel.json"
$Downloads  = Join-Path $env:TEMP 'plusemu-downloads'
$Log        = "$StateDir\install.log"
$PhpDir     = 'C:\PHP'
$NodeMajor  = 22
$MariaDbSeries = '11.4'
$TotalSteps = 10
$script:Step = 0

# `irm | iex` runs in the user's own session, so these are restored at the end.
$SessionPreferences = @{ ErrorAction = $ErrorActionPreference; Progress = $ProgressPreference }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with its progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- output

function Write-Log($Text) { Add-Content -Path $Log -Value $Text -Encoding UTF8 }
function Say($Text, $Color = 'Gray') { Write-Host $Text -ForegroundColor $Color; Write-Log $Text }
function Step($Text) {
    $script:Step++
    Write-Host ''
    Write-Host "[$script:Step/$TotalSteps] " -ForegroundColor Cyan -NoNewline
    Write-Host $Text -ForegroundColor White
    Write-Log "`n[$script:Step/$TotalSteps] $Text"
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
    & $Exe @Arguments 2>&1 | ForEach-Object { Add-Content -Path $Log -Value "$_" -Encoding UTF8 }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($code -ne 0) { throw "'$Exe $($Arguments -join ' ')' failed with exit code $code" }
}

function Download($Url, $File) {
    Write-Log "download $Url"
    & curl.exe -fsSL --retry 3 -o $File $Url
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
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

function Write-Utf8($Path, $Text) { [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false)) }

function Render($Template, $Output, $Values) {
    $content = [IO.File]::ReadAllText($Template)
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

function Sql([string]$Query, [string]$Database = '') {
    $arguments = @('-uroot', '-N', '-e', $Query)
    if ($Database) { $arguments += $Database }
    $env:MYSQL_PWD = $state.DbRootPassword
    $ErrorActionPreference = 'Continue'   # native stderr is not an error by itself
    $result = & $script:MariaDb @arguments 2>> $Log
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Remove-Item Env:\MYSQL_PWD
    if ($code -ne 0) { throw "A database command failed (exit code $code). See $Log" }
    return $result
}

# ---------------------------------------------------------------- steps

function Test-Prerequisites {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { throw 'Please run PowerShell as Administrator (right-click PowerShell > Run as administrator).' }
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'A 64-bit Windows is required.' }
    if ([Environment]::OSVersion.Version.Build -lt 17763) { throw 'Windows Server 2019 or newer is required.' }
    $free = (Get-PSDrive C).Free / 1GB
    if ($free -lt 15) { throw "Not enough disk space on C: ($([int]$free) GB free, at least 15 GB needed)." }
    New-Item -ItemType Directory -Force -Path $StateDir, $HotelRoot, $Downloads | Out-Null
    # Only administrators may read the passwords and the log.
    & icacls.exe $StateDir /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not protect $StateDir." }
    Set-Content -Path $Log -Value "PlusEMU installer log $(Get-Date -Format s)" -Encoding UTF8
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
    Write-Host ''
    Write-Host 'Welcome to the PlusEMU hotel installer!' -ForegroundColor White
    Write-Host 'This sets up your emulator, client and website on this server in about 10 minutes.'
    Write-Host ''

    if (Test-Path $StateFile) {
        $script:state = Get-Content $StateFile -Raw | ConvertFrom-Json
        Say "Found the settings of an earlier run for $($state.Domain); continuing that installation."
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
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') {
        $go = Ask 'Start the installation? (y/n)' 'y'
        if ($go -notmatch '^[Yy]') { throw 'Installation cancelled. Nothing was changed.' }
    }

    $script:state = [pscustomobject]@{
        Domain = $domain; WsUrl = $ws; HotelName = $name; AdminUser = $user; AdminEmail = $mail
        AdminPassword = New-Secret 16; DbPassword = New-Secret 32; DbRootPassword = New-Secret 32
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
    $script:MariaDb = Get-ChildItem "$env:ProgramFiles\MariaDB*\bin\mariadb.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $MariaDb) {
        $latest = Invoke-RestMethod "https://downloads.mariadb.org/rest-api/mariadb/$MariaDbSeries/latest/"
        $release = $latest.releases.PSObject.Properties | Select-Object -First 1
        $msi = $release.Value.files | Where-Object { $_.file_name -match 'winx64\.msi$' } | Select-Object -First 1
        Download ($msi.file_download_url -replace '^http:', 'https:') "$Downloads\mariadb.msi"
        if ($msi.checksum.sha256sum -and (Get-FileHash "$Downloads\mariadb.msi" -Algorithm SHA256).Hash -ne $msi.checksum.sha256sum.ToUpper()) { throw 'The MariaDB download is damaged. Run the installer again.' }
        Install-Msi "$Downloads\mariadb.msi" @("PASSWORD=$($state.DbRootPassword)", 'SERVICENAME=MariaDB', 'PORT=3306', 'UTF8=1')
        $script:MariaDb = Get-ChildItem "$env:ProgramFiles\MariaDB*\bin\mariadb.exe" | Select-Object -First 1 -ExpandProperty FullName
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
    Step 'Downloading PlusEMU, the Octane client and Atom CMS'
    # A re-run repairs and keeps the installed releases: a newer emulator may need
    # database changes this installer does not apply.
    $out = "$HotelRoot\emulator"
    if (Test-Path "$out\Plus Emulator.exe") {
        Ok 'PlusEMU (already installed)'
    } else {
        Download $EmulatorUrl "$Downloads\plusemu.zip"
        Expand-Archive "$Downloads\plusemu.zip" $out -Force
        Ok 'PlusEMU (latest release)'
    }

    $client = "$HotelRoot\client"
    if (Test-Path "$client\index.html") {
        Ok 'Octane client (already installed)'
    } else {
        Download $ClientUrl "$Downloads\octane-client.zip"
        if (Test-Path $client) { Remove-Item $client -Recurse -Force }
        Expand-Archive "$Downloads\octane-client.zip" $client
        Write-Utf8 "$client\configuration\news.json" '[]'
        Copy-Item "$client\configuration\adsense.example" "$client\configuration\adsense.json"
        Ok 'Octane client (latest release)'
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

function Write-ClientConfig {
    # Newer emulators build FurnitureData.json from the furniture table; older ones need the static file.
    $furnidata = '${gamedata.url}/FurnitureData.json?t=%timestamp%'
    try {
        Invoke-WebRequest 'http://127.0.0.1:8080/api/gamedata/furnidata' -UseBasicParsing -TimeoutSec 30 | Out-Null
        $furnidata = "https://$($state.Domain)/api/gamedata/furnidata"
    } catch { }
    $values = @{ DOMAIN = $state.Domain; SOCKET_URL = $state.WsUrl; FURNIDATA_URL = $furnidata }
    foreach ($file in 'renderer-config.json', 'ui-config.json', 'client-mode.json') {
        Render "$Templates\$file" "$HotelRoot\client\configuration\$file" $values
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
        $sqlFile = "$HotelRoot\emulator\Database\FreshInstall.sql"
        $env:MYSQL_PWD = $state.DbRootPassword
        & cmd.exe /c "`"$MariaDb`" -uroot plus < `"$sqlFile`" 2>> `"$Log`""
        $code = $LASTEXITCODE
        Remove-Item Env:\MYSQL_PWD
        if ($code -ne 0) { throw 'Importing the database failed.' }
        Ok "Imported the PlusEMU database ($("$(Sql 'SELECT COUNT(*) FROM furniture' 'plus')".Trim()) furniture types)"
    } else {
        Ok 'The database already exists; kept it as it is'
    }
}

function Get-HotelFiles {
    Step 'Downloading the hotel files (furniture, clothes, badges, texts; about 470 MB)'
    $files = "$HotelRoot\hotel-files"
    if (Test-Path "$files\.complete") { Ok 'Already downloaded'; return }
    if (Test-Path $files) { Remove-Item $files -Recurse -Force }
    New-Item -ItemType Directory -Path $files | Out-Null
    $archive = Join-Path $env:TEMP 'hotel-files.tar.gz'
    $ErrorActionPreference = 'Continue'   # the progress bar is written to stderr
    & curl.exe -fL --retry 3 --progress-bar -o $archive $AssetPackUrl
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) { throw "Downloading the hotel files failed: $AssetPackUrl" }
    Run tar.exe -xzf $archive -C $files
    Remove-Item $archive
    New-Item -ItemType File -Path "$files\.complete" | Out-Null
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
    $json.Nitro.Hostname = '127.0.0.1'; $json.Nitro.Port = 2096; $json.Nitro.Name = 'Octane'
    $json.Rcon.Hostname = '127.0.0.1'; $json.Rcon.Port = 30001; $json.Rcon.AllowedAddresses = @('127.0.0.1', 'localhost')
    $json.AuthApi.Enabled = $false; $json.AuthApi.Hostname = '127.0.0.1'
    $json.FurniEditor.FurnidataPath = "$HotelRoot\hotel-files\gamedata\FurnitureData.json"
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
    for ($i = 0; $i -lt 60; $i++) {
        try { Invoke-RestMethod 'http://127.0.0.1:8080/api/health' -TimeoutSec 2 | Out-Null; Ok 'The emulator is running (service: PlusEMU)'; return } catch { Start-Sleep 2 }
    }
    throw "The emulator didn't start. See $out\service\shawl_for_PlusEMU_rCURRENT.log"
}

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
    foreach ($type in @(@('.hab', 'application/octet-stream'), @('.nitro', 'application/octet-stream'), @('.jsonc', 'application/json'), @('.wasm', 'application/wasm'))) {
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
    # Cloudflare (SSL mode "Full") encrypts to this certificate; visitors see Cloudflare's.
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

    # IIS needs to read the website and client, and write Atom's storage and cache.
    foreach ($dir in 'cms', 'client', 'hotel-files') { Run icacls.exe "$HotelRoot\$dir" /grant 'IIS_IUSRS:(OI)(CI)RX' 'IUSR:(OI)(CI)RX' /Q }
    foreach ($dir in "$HotelRoot\cms\storage", "$HotelRoot\cms\bootstrap\cache") { Run icacls.exe $dir /grant "IIS AppPool\$($pool):(OI)(CI)M" /T /Q }
    Run icacls.exe "$HotelRoot\cms\.env" /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' "IIS AppPool\$($pool):R"
    Run icacls.exe "$HotelRoot\emulator\Config" /inheritance:r /grant:r 'Administrators:(OI)(CI)F' 'SYSTEM:(OI)(CI)F'
    Start-Website -Name $site -ErrorAction SilentlyContinue
    Restart-WebAppPool -Name $pool -ErrorAction SilentlyContinue
    Ok "IIS serves https://$domain"

    foreach ($port in 80, 443) {
        if (-not (Get-NetFirewallRule -Name "PlusEMU-$port" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name "PlusEMU-$port" -DisplayName "Hotel website (TCP $port)" -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow | Out-Null
        }
    }
    Ok 'Firewall allows HTTP and HTTPS (the database and emulator stay private)'
}

function Write-Guide {
    Step 'Writing your setup guide'
    $wsRow = ''
    if ($WsHost -ne $state.Domain) {
        $label = if ($WsHost.EndsWith(".$($state.Domain)")) { $WsHost.Substring(0, $WsHost.Length - $state.Domain.Length - 1) } else { $WsHost }
        $wsRow = "<tr><td>A</td><td><code>$label</code></td><td><code>$ServerIp</code></td><td>Proxied (orange cloud)</td></tr>"
    }
    New-Item -ItemType Directory -Force -Path "$HotelRoot\setup-guide" | Out-Null
    Render "$Templates\setup-guide.html" "$HotelRoot\setup-guide\index.html" @{
        DOMAIN = $state.Domain; SERVER_IP = $ServerIp; HOTEL_NAME = $state.HotelName; WS_DNS_ROW = $wsRow
        CREDENTIALS_FILE = $StateFile; RESTART_COMMAND = 'Restart-Service PlusEMU'
        LOG_COMMAND = "Get-Content $HotelRoot\emulator\service\shawl_for_PlusEMU_rCURRENT.log -Tail 50 -Wait"
    }
    Copy-Item "$HotelRoot\setup-guide\index.html" "$([Environment]::GetFolderPath('Desktop'))\Hotel setup guide.html" -Force
    Ok 'Guide written (also on your desktop)'
}

function Complete-Install {
    Write-Host ''
    Write-Host 'Your hotel is installed!' -ForegroundColor Green
    Write-Host ''
    Write-Host '  One last part: connect your domain through Cloudflare (about 5 minutes).'
    Write-Host '  The setup guide is opening in your browser now (also on your desktop: "Hotel setup guide").'
    Write-Host ''
    Write-Host "  Your admin login for https://$($state.Domain) (also saved in $StateFile):"
    Write-Host '      Username: ' -NoNewline; Write-Host $state.AdminUser -ForegroundColor White
    Write-Host '      Password: ' -NoNewline; Write-Host $state.AdminPassword -ForegroundColor White
    Write-Host ''
    Write-Host '  Write the password down somewhere safe and change it after logging in.'
    Write-Host ''
    if ((Get-Setting 'PLUSEMU_YES' '0') -ne '1') { Start-Process "$HotelRoot\setup-guide\index.html" }
}

try {
    Test-Prerequisites
    Get-InstallerFiles
    Read-Answers
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
    Complete-Install
} catch {
    Write-Log "ERROR: $_`n$($_.ScriptStackTrace)"
    Write-Host ''
    Write-Host "Something went wrong: $_" -ForegroundColor Red
    if (Test-Path $Log) {
        Write-Host '  The last lines of the log:'
        Get-Content $Log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    }
    Write-Host ''
    Write-Host "  Full log: $Log"
    Write-Host '  Fix the problem (or ask for help on DevBest with the log), then run the installer again.'
    Write-Host '  It continues where it stopped.'
} finally {
    foreach ($name in 'MYSQL_PWD', 'ATOM_ADMIN_PASSWORD', 'ADMIN_PASSWORD') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $ErrorActionPreference = $SessionPreferences.ErrorAction
    $ProgressPreference = $SessionPreferences.Progress
}
