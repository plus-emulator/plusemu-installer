# Updates PHP to the newest patch release of the PHP version that is installed.
# For Windows Server with IIS (any hotel, not only ones made by install.ps1).
#
#   Open PowerShell as Administrator and run:
#   irm https://raw.githubusercontent.com/plus-emulator/plusemu-installer/main/php-update.ps1 | iex
#   or: powershell -File php-update.ps1 [-Check]
#
# What it does:
#   - Finds the PHP that IIS runs (the FastCGI php-cgi.exe), else C:\PHP, else the php.exe on PATH.
#   - PHP older than 8.2 gets no security fixes any more: the script says so and
#     stops. Update that server by hand (see README.md).
#   - Reads the newest release of that PHP version from windows.php.net and
#     downloads the matching build (same thread safety, compiler and bitness).
#   - Checks the SHA256, keeps a backup copy of the PHP folder, stops IIS,
#     unpacks the new files over the old ones (php.ini is kept), starts IIS and
#     checks the version. On any error it puts the backup back.
#   -Check only reports. It changes nothing.
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ReleasesUrl = 'https://downloads.php.net/~windows/releases/releases.json'
$DownloadBase = 'https://downloads.php.net/~windows/releases/'
$OldestSupported = [version]'8.2'

function Ok($Text) { Write-Host "  + $Text" -ForegroundColor Green }
function Warn($Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }

function Get-PhpExe {
    if (Get-Module -ListAvailable WebAdministration) {
        Import-Module WebAdministration
        $apps = Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/fastCgi/application'
        $cgi = $apps | Where-Object { $_.fullPath -like '*php-cgi.exe' } | Select-Object -First 1 -ExpandProperty fullPath
        if ($cgi -and (Test-Path $cgi)) { return Join-Path (Split-Path $cgi -Parent) 'php.exe' }
    }
    if (Test-Path 'C:\PHP\php.exe') { return 'C:\PHP\php.exe' }
    $onPath = Get-Command php.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    throw 'No PHP found: not in IIS FastCGI, not in C:\PHP and not on PATH.'
}

# Build name of the installed PHP as used by windows.php.net, e.g. nts-vs17-x64.
function Get-BuildFlavor($PhpExe, $Branch) {
    $zts = & $PhpExe -r 'echo PHP_ZTS;'
    $bits = & $PhpExe -r 'echo PHP_INT_SIZE * 8;'
    $safety = if ($zts -eq '1') { 'ts' } else { 'nts' }
    $arch = if ($bits -eq '64') { 'x64' } else { 'x86' }
    $names = $Branch.PSObject.Properties.Name | Where-Object { $_ -match "^$safety-vs\d+-$arch$" }
    if (-not $names) { throw "windows.php.net has no $safety $arch build for this PHP version." }
    return ($names | Select-Object -First 1)
}

function Get-Sha256($File) { (Get-FileHash $File -Algorithm SHA256).Hash.ToUpperInvariant() }

$phpExe = Get-PhpExe
$phpDir = Split-Path $phpExe -Parent
$installed = [version](& $phpExe -r 'echo PHP_VERSION;')
$branchName = "$($installed.Major).$($installed.Minor)"
Write-Host "PHP $branchName in $phpDir`: installed $installed" -ForegroundColor White

if ([version]$branchName -lt $OldestSupported) {
    Warn "PHP $branchName gets no security fixes any more. Update to PHP $OldestSupported or newer by hand."
    Warn 'A newer PHP needs a check of your website code first, so this script does not do it.'
    exit 1
}

$releases = Invoke-RestMethod $ReleasesUrl
$branch = $releases.$branchName
if (-not $branch) { throw "windows.php.net has no releases for PHP $branchName." }
$latest = [version]$branch.version
Write-Host "Newest release: $latest"
if ($installed -ge $latest) { Ok 'Already up to date.'; exit 0 }

$flavor = Get-BuildFlavor $phpExe $branch
$build = $branch.$flavor.zip
if ($Check) { Warn "Would upgrade PHP $installed to $latest ($flavor) (-Check: nothing changed)."; exit 0 }

$downloads = Join-Path ([IO.Path]::GetTempPath()) 'plusemu-php-update'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
$zip = Join-Path $downloads $build.path.Split('/')[-1]
Write-Host "Downloading $($build.path)..."
& curl.exe -fsSL --retry 3 -o $zip "$DownloadBase$($build.path)"
if ($LASTEXITCODE -ne 0) { throw "Download failed: $DownloadBase$($build.path)" }
if ((Get-Sha256 $zip) -ne $build.sha256.ToUpperInvariant()) { throw 'The PHP download is damaged. Run the script again.' }
Ok 'Download checked (SHA256 matches).'

$backup = "$phpDir-backup-$installed"
if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
Copy-Item $phpDir $backup -Recurse
Ok "Backup of the old PHP: $backup"

$iisWasRunning = (Get-Service W3SVC -ErrorAction SilentlyContinue).Status -eq 'Running'
try {
    if ($iisWasRunning) { & iisreset.exe /stop | Out-Null; Ok 'IIS stopped.' }
    Expand-Archive $zip $phpDir -Force
    $now = [version](& $phpExe -r 'echo PHP_VERSION;')
    if ($now -ne $latest) { throw "PHP reports $now after the update, expected $latest." }
    if (-not (Test-Path (Join-Path $phpDir 'php-cgi.exe'))) { throw 'php-cgi.exe is missing after the update.' }
    & $phpExe -r 'exit(0);' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'The new php.exe does not start. php.ini or an extension may need a change.' }
} catch {
    Warn "Update failed: $_"
    Warn 'Putting the old PHP back...'
    Get-ChildItem $phpDir | Remove-Item -Recurse -Force
    Copy-Item "$backup\*" $phpDir -Recurse -Force
    if ($iisWasRunning) { & iisreset.exe /start | Out-Null }
    throw
} finally {
    if ($iisWasRunning -and (Get-Service W3SVC).Status -ne 'Running') { & iisreset.exe /start | Out-Null; Ok 'IIS started.' }
}
Remove-Item $zip -Force
Ok "PHP $branchName is now $now. The backup in $backup can be deleted once the website works."
