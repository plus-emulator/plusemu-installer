# Exercise the real update mode against fake releases, without services, programs or network.
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
$previousTemp = $env:TEMP
$env:TEMP = $testDir

# Script-level settings the installer normally defines at the top of install.ps1.
$InstallerRepo = 'plus-emulator/plusemu-installer'
$InstallerRef = 'main'
$EmulatorRepo = 'plus-emulator/PlusEMU'
$ClientRepo = 'plus-emulator/Volt'
$EmulatorUrl = ''
$ClientUrl = ''
$AssetPackUrl = 'https://github.com/plus-emulator/plusemu-installer/releases/download/hotel-files/hotel-files.tar.gz'
$HotelRoot = Join-Path $testDir 'hotel'
$StateDir = Join-Path $testDir 'state'
$StateFile = Join-Path $StateDir 'hotel.json'
$VersionsFile = Join-Path $StateDir 'versions.json'
$BackupRoot = Join-Path $StateDir 'backups'
$UpdateCommand = Join-Path $StateDir 'plusemu-update.ps1'
$Log = Join-Path $StateDir 'install.log'
$UpdateLog = Join-Path $StateDir 'update.log'
$LockFile = Join-Path $StateDir 'update.lock'
$Downloads = Join-Path $testDir 'downloads'
$KeepBackups = 3
$Templates = Join-Path $root 'templates'
$script:Step = 0; $TotalSteps = 10
$Releases = Join-Path $testDir 'releases'
$script:Migration = 'ok'
$script:Calls = [Collections.Generic.List[string]]::new()

# External programs and Windows-only steps are replaced; everything else is the real installer code.
function Assert-Administrator { }
function Get-InstallerFiles { $script:Templates = Join-Path $root 'templates' }
function Add-MachinePath($Dir) { $Calls.Add("path $Dir") }
function Invoke-WebRequest { throw 'offline' }
function Sql([string]$Query, [string]$Database = '') { $Calls.Add("sql $Query"); return '0' }
function Stop-EmulatorService { $Calls.Add('stop') }
function Start-EmulatorService { $Calls.Add('start') }
function Wait-Emulator { return $true }
function Set-HotelPermissions { $Calls.Add('permissions') }
function Invoke-DatabaseDump($File) { Set-Content $File 'CREATE TABLE users (id INT);' }
function Invoke-DatabaseRestore($File) { $Calls.Add('restore database'); $script:RestoredSql = Get-Content $File -Raw }
function Invoke-Migration($Dir) {
    $Calls.Add("migrate $Dir")
    if ($script:Migration -ne 'ok') { throw 'The migration failed' }
}
function Invoke-Tar([string[]]$Arguments) {
    # GNU tar reports kept files as errors with -k; tar.exe on Windows (bsdtar) skips them silently.
    $Arguments = $Arguments | ForEach-Object { if ($_ -eq '-k') { '--skip-old-files' } else { $_ } }
    & tar @Arguments 2>&1 | Out-Null
    return $LASTEXITCODE
}
function Invoke-Curl([string[]]$Arguments) {
    $url = $Arguments | Where-Object { $_ -like 'http*' } | Select-Object -First 1
    $outIndex = [Array]::IndexOf($Arguments, '-o')
    $out = if ($outIndex -ge 0) { $Arguments[$outIndex + 1] } else { '' }
    $wantsCode = $Arguments -contains '-w'
    $Calls.Add("curl $url")
    switch -Wildcard ($url) {
        'https://github.com/plus-emulator/PlusEMU/releases/latest' {
            return @{ Code = 0; Output = "https://github.com/plus-emulator/PlusEMU/releases/tag/$script:LatestEmulator" }
        }
        'https://github.com/plus-emulator/Volt/releases/latest' {
            return @{ Code = 0; Output = "https://github.com/plus-emulator/Volt/releases/tag/$script:LatestClient" }
        }
        'https://github.com/*/releases/download/*' {
            $file = Join-Path $Releases ($url -replace '^https://github.com/[^/]+/[^/]+/releases/download/', '')
            if (-not (Test-Path $file)) {
                if ($wantsCode) { return @{ Code = 0; Output = '404' } }
                return @{ Code = 22; Output = '' }
            }
            if ($out) { Copy-Item $file $out -Force }
            return @{ Code = 0; Output = $(if ($wantsCode) { '200' } else { '' }) }
        }
        default { return @{ Code = 7; Output = '' } }
    }
}

function Write-Bom($Path, $Text) {
    [IO.File]::WriteAllBytes($Path, [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($Text))
}
function Write-Sums($Dir, $File) {
    $hash = (Get-FileHash (Join-Path $Dir $File) -Algorithm SHA256).Hash.ToLower()
    Set-Content (Join-Path $Dir 'SHA256SUMS') "$hash  $File"
}
function New-EmulatorRelease($Tag) {
    $dir = Join-Path (Join-Path $testDir 'build') $Tag
    $release = Join-Path $Releases $Tag
    New-Item -ItemType Directory -Force (Join-Path $dir 'Config'), (Join-Path $dir 'Database'), $release | Out-Null
    Set-Content (Join-Path $dir 'Plus Emulator.exe') "emulator $Tag"
    Set-Content (Join-Path $dir "new-$Tag.dll") $Tag
    Write-Bom (Join-Path (Join-Path $dir 'Config') 'config.json') '{"Database": {"Password": "", "Port": 3306, "Timeout": 30}, "NewSection": {"Enabled": true}}'
    Set-Content (Join-Path (Join-Path $dir 'Config') 'nlog.config') 'default nlog'
    Set-Content (Join-Path (Join-Path $dir 'Config') 'figuredata.xml') 'default figuredata'
    Set-Content (Join-Path (Join-Path $dir 'Database') 'FreshInstall.sql') "schema $Tag"
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath (Join-Path $release 'plusemu-win-x64.zip') -Force
    Write-Sums $release 'plusemu-win-x64.zip'
}
function New-ClientRelease($Tag) {
    $dir = Join-Path (Join-Path $testDir 'build') $Tag
    $release = Join-Path $Releases $Tag
    New-Item -ItemType Directory -Force (Join-Path $dir 'assets'), (Join-Path $dir 'configuration'), (Join-Path $dir 'plugins'), $release | Out-Null
    Set-Content (Join-Path $dir 'index.html') "client $Tag"
    Set-Content (Join-Path (Join-Path $dir 'assets') "index-$Tag.js") 'bundle'
    Set-Content (Join-Path (Join-Path $dir 'configuration') 'ui-config.example') '{}'
    Set-Content (Join-Path (Join-Path $dir 'configuration') 'pets.json') '{"pets": []}'
    Set-Content (Join-Path (Join-Path $dir 'plugins') 'room-builder.js') 'builder'
    # Client releases publish no SHA256SUMS, like the releases made before checksums existed.
    Compress-Archive -Path (Join-Path $dir '*') -DestinationPath (Join-Path $release 'volt-client.zip') -Force
}
function New-HotelFilesPack($Revision, $ExtraFiles = @{}) {
    $dir = Join-Path (Join-Path $testDir 'build') "hotel-files-$Revision"
    $release = Join-Path $Releases 'hotel-files'
    New-Item -ItemType Directory -Force (Join-Path $dir 'gamedata'), (Join-Path (Join-Path $dir 'assets') 'furni'), $release | Out-Null
    Set-Content (Join-Path (Join-Path $dir 'gamedata') 'FigureData.json') "figuredata $Revision"
    Set-Content (Join-Path (Join-Path (Join-Path $dir 'assets') 'furni') "stock_$Revision.nitro") "furni $Revision"
    foreach ($file in $ExtraFiles.Keys) { Set-Content (Join-Path $dir $file) $ExtraFiles[$file] }
    & tar -C $dir -czf (Join-Path $release 'hotel-files.tar.gz') .
    Write-Sums $release 'hotel-files.tar.gz'
    return ((Get-Content (Join-Path $release 'SHA256SUMS')) -split '\s+')[0].Substring(0, 12)
}

function Get-Tree($Dir) {
    $base = (Get-Item $Dir).FullName
    return (Get-ChildItem $Dir -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $entry = $_.FullName.Substring($base.Length)
        if ($_.PSIsContainer) { "$entry dir" } else { "$entry $((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }
    }) -join "`n"
}
function Get-Text($Path) { return (Get-Content $Path -Raw).Trim() }
function Get-Json($Path) { return Get-Content $Path -Raw | ConvertFrom-Json }
function Get-Snapshots { return @(Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}-\d{6}-\d{3}$' } | Sort-Object Name) }
function Get-Versions { return Get-Json $VersionsFile }
function Invoke-TestUpdate {
    param([switch]$Check, [switch]$Yes, [switch]$Rollback, [switch]$Assets)
    $script:Terminal = ''
    Invoke-Update -Check:$Check -Yes:$Yes -Rollback:$Rollback -Assets:$Assets 6>&1 | ForEach-Object { $script:Terminal += "$_`n" }
}
function Test-UpdateFails {
    param([switch]$Check, [switch]$Yes, [switch]$Rollback, [switch]$Assets)
    try { Invoke-TestUpdate -Check:$Check -Yes:$Yes -Rollback:$Rollback -Assets:$Assets; return $false }
    catch { $script:LastError = "$_"; return $true }
}

try {
    # An installation made before update mode existed: no versions file, user edits everywhere.
    $emulator = Join-Path $HotelRoot 'emulator'
    $client = Join-Path $HotelRoot 'client'
    $hotelFiles = Join-Path $HotelRoot 'hotel-files'
    $emulatorConfig = Join-Path $emulator 'Config'
    $clientConfig = Join-Path $client 'configuration'
    New-Item -ItemType Directory -Force $StateDir, $Downloads, $emulatorConfig, (Join-Path (Join-Path $emulator 'plugins') 'MyPlugin'),
        (Join-Path $emulator 'backups'), (Join-Path $client 'assets'), $clientConfig, (Join-Path $client 'plugins'),
        (Join-Path $hotelFiles 'gamedata'), (Join-Path (Join-Path $hotelFiles 'assets') 'custom') | Out-Null
    [pscustomobject]@{
        Domain = 'example.com'; WsUrl = 'wss://example.com/ws'; HotelName = 'Example'; AdminUser = 'admin'; AdminEmail = 'admin@example.com'
        GuideMode = 'simple'; AdminPassword = 'OriginalAlpha123!'; DbPassword = 'database-secret'; DbRootPassword = 'root-secret'
    } | ConvertTo-Json | Set-Content $StateFile
    Set-Content (Join-Path $emulator 'Plus Emulator.exe') 'emulator old'
    Set-Content (Join-Path $emulator 'old.dll') 'old'
    Set-Content (Join-Path $emulatorConfig 'config.json') '{"Database": {"Password": "database-secret", "Port": 3306}, "Custom": "kept"}'
    Set-Content (Join-Path $emulatorConfig 'nlog.config') 'my nlog'
    Set-Content (Join-Path $emulatorConfig 'figuredata.xml') 'my custom clothes'
    Set-Content (Join-Path (Join-Path (Join-Path $emulator 'plugins') 'MyPlugin') 'MyPlugin.dll') 'plugin'
    Set-Content (Join-Path (Join-Path $emulator 'backups') 'before-migration.sql') 'dump'
    Set-Content (Join-Path $client 'index.html') 'client old'
    Set-Content (Join-Path (Join-Path $client 'assets') 'index-old.js') 'old bundle'
    Set-Content (Join-Path $clientConfig 'renderer-config.json') '{"socket.url": "wss://custom.example.com/game", "my.setting": 1}'
    Set-Content (Join-Path $clientConfig 'ui-config.json') '{"hotel.name": "Mine"}'
    Set-Content (Join-Path $clientConfig 'client-mode.json') '{"apiBaseUrl": "https://example.com"}'
    Set-Content (Join-Path $clientConfig 'UITexts_en.jsonc') '{"text": "mine"}'
    Set-Content (Join-Path $client 'ads.txt') 'ads'
    Set-Content (Join-Path (Join-Path $client 'plugins') 'mine.js') 'mine'
    Set-Content (Join-Path (Join-Path $hotelFiles 'gamedata') 'FigureData.json') 'figuredata 0'
    Set-Content (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'custom') 'my_furni.nitro') 'my furni'
    New-Item -ItemType File (Join-Path $hotelFiles '.complete') | Out-Null
    $original = Get-Tree $HotelRoot

    New-EmulatorRelease 'v2.0.0'
    New-ClientRelease 'client-v2.0.0'
    $pack1 = New-HotelFilesPack 1
    $script:LatestEmulator = 'v2.0.0'; $script:LatestClient = 'client-v2.0.0'

    # -Check reports the available updates, hotel files included, and changes nothing.
    Invoke-TestUpdate -Check
    Assert ($Terminal.Contains('v2.0.0') -and $Terminal.Contains('client-v2.0.0') -and $Terminal.Contains($pack1)) "Check did not name the new versions: $Terminal"
    Assert ((Get-Tree $HotelRoot) -ceq $original) 'Check changed the hotel'
    Assert ((Get-Snapshots).Count -eq 0 -and -not ($Calls -contains 'stop') -and -not (Test-Path $VersionsFile)) 'Check touched the server'

    # A download that fails its checksum stops before the hotel is touched.
    $sums = Join-Path (Join-Path $Releases 'v2.0.0') 'SHA256SUMS'
    $goodSums = Get-Content $sums -Raw
    Set-Content $sums ("$('0' * 64)  plusemu-win-x64.zip")
    Assert (Test-UpdateFails -Yes) 'A bad checksum was accepted'
    Assert ((Get-Tree $HotelRoot) -ceq $original) 'A bad checksum changed the hotel'
    Assert ((Get-Snapshots).Count -eq 0 -and -not ($Calls -contains 'stop')) 'A bad checksum stopped the emulator or made a backup'
    Set-Content $sums $goodSums -NoNewline

    # Only one update runs at a time.
    $lock = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
    try { Assert (Test-UpdateFails -Check) 'A second update ran while another holds the lock' } finally { $lock.Dispose() }
    Assert ($LastError -like '*Another update*') "Wrong lock error: $LastError"

    # A failed migration restores the previous emulator, client, hotel files and database.
    $script:Migration = 'fail'
    Assert (Test-UpdateFails -Yes) 'A failed migration was reported as success'
    Assert ((Get-Tree $HotelRoot) -ceq $original) 'A failed migration left changed files'
    Assert ((Get-Snapshots).Count -eq 1) 'A failed migration did not keep its backup'
    Assert ($Calls -contains 'restore database' -and $RestoredSql.Contains('CREATE TABLE users')) 'The database was not restored from the backup'
    Assert (@($Calls | Where-Object { $_ -in 'stop', 'start' })[-1] -eq 'start') 'The emulator was not started again after the restore'
    Assert (-not (Test-Path $VersionsFile)) 'A failed update recorded versions'
    Assert ($Terminal -match '(?i)restored') "The restore was not reported: $Terminal"

    # A successful update installs both releases and the hotel files, and keeps every user file and setting.
    $script:Migration = 'ok'; $Calls.Clear(); $script:RestoredSql = ''
    Invoke-TestUpdate -Yes
    Assert ((Get-Text (Join-Path $emulator 'Plus Emulator.exe')) -eq 'emulator v2.0.0') 'The new emulator was not installed'
    Assert ((Test-Path (Join-Path $emulator 'new-v2.0.0.dll')) -and -not (Test-Path (Join-Path $emulator 'old.dll'))) 'Old emulator libraries were kept'
    Assert ((Get-Text (Join-Path (Join-Path $emulator 'Database') 'FreshInstall.sql')) -eq 'schema v2.0.0') 'The new database schema was not installed'
    $config = Get-Json (Join-Path $emulatorConfig 'config.json')
    Assert ($config.Database.Password -eq 'database-secret') 'The database password was lost'
    Assert ($config.Database.Timeout -eq 30 -and $config.NewSection.Enabled -eq $true) 'New config defaults were not added'
    Assert ($config.Custom -eq 'kept') 'A custom config setting was lost'
    Assert ((Get-Text (Join-Path $emulatorConfig 'nlog.config')) -eq 'my nlog') 'nlog.config was replaced'
    Assert ((Get-Text (Join-Path $emulatorConfig 'figuredata.xml')) -eq 'default figuredata') 'figuredata.xml was not replaced with the release file that matches the new hotel files'
    Assert ((Test-Path (Join-Path (Join-Path (Join-Path $emulator 'plugins') 'MyPlugin') 'MyPlugin.dll')) -and (Test-Path (Join-Path (Join-Path $emulator 'backups') 'before-migration.sql'))) 'Plugins or emulator backups were lost'
    Assert ($Calls -contains "migrate $emulator") 'The migration did not run in the emulator folder'
    Assert ($Calls -contains 'permissions') 'Permissions were not applied again'
    Assert ((Get-Text (Join-Path $client 'index.html')) -eq 'client client-v2.0.0') 'The new client was not installed'
    Assert ((Test-Path (Join-Path (Join-Path $client 'assets') 'index-client-v2.0.0.js')) -and -not (Test-Path (Join-Path (Join-Path $client 'assets') 'index-old.js'))) 'Old client bundles were kept'
    Assert ((Test-Path (Join-Path $client 'ads.txt')) -and (Test-Path (Join-Path (Join-Path $client 'plugins') 'mine.js')) -and (Test-Path (Join-Path (Join-Path $client 'plugins') 'room-builder.js'))) 'Client files were lost'
    Assert ((Test-Path (Join-Path $clientConfig 'pets.json')) -and (Test-Path (Join-Path $clientConfig 'UITexts_en.jsonc'))) 'Client configuration files were lost'
    $renderer = Get-Json (Join-Path $clientConfig 'renderer-config.json')
    Assert ($renderer.'socket.url' -eq 'wss://custom.example.com/game' -and $renderer.'my.setting' -eq 1) 'Custom renderer settings were lost'
    Assert ($renderer.'asset.url' -eq 'https://example.com/hotel-files/assets') 'New renderer settings were not added'
    Assert ((Get-Json (Join-Path $clientConfig 'ui-config.json')).'hotel.name' -eq 'Mine') 'Custom ui-config settings were lost'
    Assert ((Get-Text (Join-Path (Join-Path $hotelFiles 'gamedata') 'FigureData.json')) -eq 'figuredata 1') 'The hotel files were not updated'
    Assert ((Test-Path (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'furni') 'stock_1.nitro')) -and (Test-Path (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'custom') 'my_furni.nitro'))) 'Stock or owner-added hotel files are missing'
    $versions = Get-Versions
    Assert ($versions.EmulatorVersion -eq 'v2.0.0' -and $versions.ClientVersion -eq 'client-v2.0.0' -and $versions.AssetsVersion -eq $pack1) "Versions were not recorded: $(Get-Content $VersionsFile -Raw)"
    Assert ((Get-Snapshots).Count -eq 2) 'The update did not keep its backup'
    $latest = (Get-Snapshots)[-1].FullName
    Assert ((Get-Content (Join-Path $latest 'database.sql') -Raw).Contains('CREATE TABLE users')) 'The backup holds no database dump'
    Assert ((Test-Path (Join-Path $latest 'hotel-files.tar')) -and (Test-Path (Join-Path $latest 'files.tar.gz'))) 'The backup misses the hotel files or the program files'
    $command = Get-Content $UpdateCommand -Raw
    Assert ($command.Contains('-Update') -and $command.Contains("https://raw.githubusercontent.com/$InstallerRepo/$InstallerRef/install.ps1")) 'The update command does not run the installer in update mode'
    Assert ($Calls -contains "path $StateDir") 'The update command folder was not added to the PATH'
    Assert (-not (Test-Path (Join-Path $HotelRoot '.restore')) -and -not (Get-ChildItem $HotelRoot -Directory -Force | Where-Object Name -like '.update*')) 'Temporary folders were left behind'
    $updated = Get-Tree $HotelRoot

    # Nothing to do when every component is current.
    $Calls.Clear()
    Invoke-TestUpdate -Yes
    Assert ((Get-Snapshots).Count -eq 2 -and -not ($Calls -contains 'stop')) 'An up-to-date hotel was updated'
    Assert ($Terminal -match '(?i)up to date') "Up to date was not reported: $Terminal"
    Assert ((Get-Tree $HotelRoot) -ceq $updated) 'An up-to-date run changed files'

    # -Rollback returns to the state before the last update, database and hotel files included.
    $script:RestoredSql = ''
    Invoke-TestUpdate -Yes -Rollback
    Assert ((Get-Tree $HotelRoot) -ceq $original) 'Rollback did not restore the previous files'
    Assert ($RestoredSql.Contains('CREATE TABLE users')) 'Rollback did not restore the database'
    Assert (-not (Test-Path $VersionsFile) -and (Get-Snapshots).Count -eq 3) 'Rollback kept the versions file or lost the backups'
    # The rollback saved the state it replaced, so a second rollback undoes it.
    Invoke-TestUpdate -Yes -Rollback
    Assert ((Get-Tree $HotelRoot) -ceq $updated) 'The second rollback did not return to the updated state'
    Assert ((Get-Versions).EmulatorVersion -eq 'v2.0.0') 'The second rollback did not restore the versions file'

    # Only the newest three backups are kept, and an owner's figuredata.xml survives an emulator-only update.
    Set-Content (Join-Path $emulatorConfig 'figuredata.xml') 'my custom clothes'
    foreach ($tag in 'v2.1.0', 'v2.2.0') {
        New-EmulatorRelease $tag
        $script:LatestEmulator = $tag
        Invoke-TestUpdate -Yes
    }
    Assert ((Get-Snapshots).Count -eq 3) 'More than three backups were kept'
    Assert ((Get-Text (Join-Path $emulator 'Plus Emulator.exe')) -eq 'emulator v2.2.0') 'The newest emulator was not installed'
    Assert ((Get-Text (Join-Path $client 'index.html')) -eq 'client client-v2.0.0') 'The client was replaced without a new release'
    Assert ((Get-Text (Join-Path $emulatorConfig 'figuredata.xml')) -eq 'my custom clothes') 'figuredata.xml was replaced although the hotel files did not change'
    Assert (-not (Test-Path (Join-Path (Get-Snapshots)[-1].FullName 'hotel-files.tar'))) 'The hotel files were backed up although they did not change'
    $beforeAssets = Get-Tree $HotelRoot

    # A newer pack with everything else current still updates, and -Check names it.
    $pack2 = New-HotelFilesPack 2
    Invoke-TestUpdate -Check
    Assert ($Terminal.Contains($pack2) -and $Terminal -notmatch 'Everything is up to date') "A newer pack was not reported: $Terminal"
    Assert ((Get-Tree $HotelRoot) -ceq $beforeAssets) 'Check changed the hotel files'

    # A damaged pack changes nothing.
    $sums = Join-Path (Join-Path $Releases 'hotel-files') 'SHA256SUMS'
    $goodSums = Get-Content $sums -Raw
    Set-Content $sums ("$('0' * 64)  hotel-files.tar.gz")
    Assert (Test-UpdateFails -Yes) 'A damaged pack was accepted'
    Assert ((Get-Tree $HotelRoot) -ceq $beforeAssets) 'A damaged pack changed the hotel'
    Set-Content $sums $goodSums -NoNewline

    # A failed update restores the hotel files too.
    $script:Migration = 'fail'
    Assert (Test-UpdateFails -Yes) 'A failed migration was reported as success'
    Assert ((Get-Tree $HotelRoot) -ceq $beforeAssets) 'A failed update left changed hotel files'
    $script:Migration = 'ok'

    # The new pack is installed over the hotel files, with the emulator's matching clothing data.
    Invoke-TestUpdate -Yes
    Assert ((Get-Text (Join-Path (Join-Path $hotelFiles 'gamedata') 'FigureData.json')) -eq 'figuredata 2') 'The new hotel files were not installed'
    $furni = Join-Path (Join-Path $hotelFiles 'assets') 'furni'
    Assert ((Test-Path (Join-Path $furni 'stock_2.nitro')) -and (Test-Path (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'custom') 'my_furni.nitro'))) 'Stock or owner-added hotel files are missing'
    Assert ((Get-Text (Join-Path $emulatorConfig 'figuredata.xml')) -eq 'default figuredata') 'figuredata.xml was not replaced with the release file'
    Assert ((Get-Text (Join-Path $emulatorConfig 'nlog.config')) -eq 'my nlog') 'nlog.config was replaced'
    Assert ((Get-Json (Join-Path $emulatorConfig 'config.json')).Custom -eq 'kept') 'A custom config setting was lost'
    Assert ((Get-Text (Join-Path $emulator 'Plus Emulator.exe')) -eq 'emulator v2.2.0') 'The emulator version changed without a new release'
    $versions = Get-Versions
    Assert ($versions.AssetsVersion -eq $pack2 -and $versions.EmulatorVersion -eq 'v2.2.0') "Versions were not recorded: $(Get-Content $VersionsFile -Raw)"
    Assert (Test-Path (Join-Path (Get-Snapshots)[-1].FullName 'hotel-files.tar')) 'The backup misses the hotel files'
    $Calls.Clear()
    Invoke-TestUpdate -Yes
    Assert (-not ($Calls -contains 'stop') -and $Terminal -match '(?i)up to date') 'A current pack was installed again'

    # -Rollback also returns the hotel files.
    Invoke-TestUpdate -Yes -Rollback
    Assert ((Get-Tree $HotelRoot) -ceq $beforeAssets) 'Rollback did not restore the hotel files'

    # -Assets refreshes the hotel files in place: new stock files are added, edited files stay, gamedata is replaced.
    $pack3 = New-HotelFilesPack 3 @{ 'assets/furni/stock_1.nitro' = 'changed upstream' }
    Set-Content (Join-Path $furni 'stock_1.nitro') 'edited by owner'
    $beforeAssetsOnly = Get-Tree $HotelRoot
    $snapshotCount = (Get-Snapshots).Count
    $Calls.Clear()
    Invoke-TestUpdate -Check -Assets
    Assert ($Terminal.Contains($pack3)) "Check -Assets did not name the new pack: $Terminal"
    Assert ((Get-Tree $HotelRoot) -ceq $beforeAssetsOnly) 'Check -Assets changed the hotel'
    Invoke-TestUpdate -Assets
    Assert (Test-Path (Join-Path $furni 'stock_3.nitro')) 'A new stock file was not added'
    Assert ((Get-Text (Join-Path $furni 'stock_1.nitro')) -eq 'edited by owner') 'An edited stock file was replaced'
    Assert ((Get-Text (Join-Path (Join-Path $hotelFiles 'gamedata') 'FigureData.json')) -eq 'figuredata 3') 'gamedata was not replaced'
    Assert (Test-Path (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'custom') 'my_furni.nitro')) 'An owner-added file was removed'
    Assert (-not (Test-Path (Join-Path $hotelFiles '.complete'))) 'The stale .complete marker was kept'
    $gamedataCopy = Join-Path $BackupRoot "gamedata-$pack1"
    Assert ((Get-Text (Join-Path $gamedataCopy 'FigureData.json')) -eq 'figuredata 1') 'The old gamedata folder was not copied to the backups folder'
    Assert (-not ($Calls -contains 'stop') -and -not ($Calls -contains 'start') -and -not ($Calls -like 'migrate*')) 'An assets-only update touched the emulator'
    Assert ((Get-Snapshots).Count -eq $snapshotCount) 'An assets-only update made a full backup'
    $versions = Get-Versions
    Assert ($versions.AssetsVersion -eq $pack3 -and $versions.EmulatorVersion -eq 'v2.2.0') "Versions were not recorded: $(Get-Content $VersionsFile -Raw)"
    Assert ($Terminal.Contains($pack3) -and $Terminal.Contains('figuredata.xml')) "The result or the clothing data hint is missing: $Terminal"
    $afterAssetsOnly = Get-Tree $HotelRoot
    Invoke-TestUpdate -Assets
    Assert ($Terminal -match '(?i)up to date' -and (Get-Tree $HotelRoot) -ceq $afterAssetsOnly) 'A current pack was installed again by -Assets'

    # On install, the hotel files step skips a current pack and refreshes an older one.
    $script:Step = 0
    $Calls.Clear()
    $output = Get-HotelFiles 6>&1 | Out-String
    Assert ($output.Contains("Already downloaded (version $pack3)")) "A current pack was not skipped: $output"
    Assert (-not ($Calls -contains "curl $AssetPackUrl")) 'A current pack was downloaded again'
    Assert ((Get-Tree $HotelRoot) -ceq $afterAssetsOnly) 'A skipped pack changed the hotel files'
    Set-Content $VersionsFile (@{ EmulatorVersion = 'v2.2.0'; ClientVersion = 'client-v2.0.0'; AssetsVersion = $pack1 } | ConvertTo-Json)
    Remove-Item (Join-Path $furni 'stock_3.nitro')
    Get-HotelFiles *> $null
    Assert (Test-Path (Join-Path $furni 'stock_3.nitro')) 'An older pack was not refreshed'
    Assert (Test-Path (Join-Path (Join-Path (Join-Path $hotelFiles 'assets') 'custom') 'my_furni.nitro')) 'The refresh removed an owner-added file'
    Assert ((Get-Versions).AssetsVersion -eq $pack3) 'The refreshed pack version was not recorded'
    Write-Host 'PowerShell update checks passed'
} catch {
    Write-Host "Failed: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    if (Test-Path $UpdateLog) { Write-Host '--- update.log'; Get-Content $UpdateLog -Tail 30 }
    exit 1
} finally {
    foreach ($name in 'PLUSEMU_YES') { Remove-Item "Env:\$name" -ErrorAction SilentlyContinue }
    $env:TEMP = $previousTemp
    Remove-Item $testDir -Recurse -Force
}
