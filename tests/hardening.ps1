# Exercise the nightly backup against a fake database, without services, programs or network.
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
    $BackupRoot = Join-Path $StateDir 'backups'
    $NightlyRoot = Join-Path $BackupRoot 'nightly'
    $LockFile = Join-Path $StateDir 'update.lock'
    $BackupScript = Join-Path $StateDir 'plusemu-backup.ps1'
    $BackupLog = Join-Path $StateDir 'backup.log'
    $KeepNightly = 7
    $BackupLockWait = 3600
    $script:Log = $BackupLog
    $script:Step = 0; $TotalSteps = 11
    $nightly = $NightlyRoot

    # External programs are replaced; everything else is the real installer code.
    function Sql([string]$Query, [string]$Database = '') { return '1' }
    function Invoke-DatabaseDump($File) { Set-Content $File 'CREATE TABLE users (id INT);' }
    function Invoke-Tar([string[]]$Arguments) { & tar @Arguments 2>&1 | Out-Null; return $LASTEXITCODE }
    function New-ScheduledTaskAction { return 'action' }
    function New-ScheduledTaskTrigger { return 'trigger' }
    function Register-ScheduledTask { $script:Registered = $args -join ' ' }

    foreach ($file in @('emulator/Config/config.json', 'emulator/Plus Emulator.exe', 'emulator/backups/old.sql', 'client/configuration/ui-config.json',
                        'client/assets/index.js', 'cms/.env', 'cms/storage/app/public/avatar.png', 'cms/storage/logs/laravel.log',
                        'hotel-files/gamedata/ExternalTexts.json', 'hotel-files/assets/chair.hab')) {
        $path = Join-Path $HotelRoot $file
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        Set-Content $path $file
    }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    Set-Content $StateFile '{"DbRootPassword": "x"}'
    Set-Content (Join-Path $StateDir 'versions.json') '{"EmulatorVersion": "v1"}'
    # The update's own snapshots share the backup folder.
    New-Item -ItemType Directory -Force -Path (Join-Path $BackupRoot '20260101-000000-000') | Out-Null

    function Get-Nightly { return @(Get-ChildItem $nightly -Directory | Sort-Object Name) }

    for ($i = 0; $i -lt 9; $i++) { Invoke-NightlyBackup; Start-Sleep -Milliseconds 5 }
    $backups = Get-Nightly
    Assert ($backups.Count -eq 7) "Expected 7 nightly backups, found $($backups.Count)"
    Assert ($backups[-1].Name -match '^\d{8}-\d{6}-\d{3}$') "Unexpected backup name $($backups[-1].Name)"
    $latest = $backups[-1].FullName
    $sql = Join-Path $testDir 'restored.sql'
    $in = [IO.File]::OpenRead((Join-Path $latest 'database.sql.gz'))
    $zip = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    $reader = New-Object IO.StreamReader($zip)
    $restored = $reader.ReadToEnd().Trim()
    $reader.Dispose()
    Assert ($restored -eq 'CREATE TABLE users (id INT);') 'The database dump was not saved'
    $files = @(& tar -tzf (Join-Path $latest 'hotel.tar.gz'))
    foreach ($kept in 'emulator/Config/config.json', 'client/configuration/ui-config.json', 'cms/.env', 'cms/storage/app/public/avatar.png', 'hotel-files/gamedata/ExternalTexts.json') {
        Assert ($files -contains $kept) "Missing from the backup: $kept"
    }
    # Files that come back with a download or an update are left out.
    foreach ($left in 'emulator/Plus Emulator.exe', 'emulator/backups/old.sql', 'client/assets/index.js', 'hotel-files/assets/chair.hab', 'cms/storage/logs/laravel.log') {
        Assert ($files -notcontains $left) "Backed up a downloadable file: $left"
    }
    $settings = @(& tar -tzf (Join-Path $latest 'settings.tar.gz'))
    Assert (($settings -contains 'hotel.json') -and ($settings -contains 'versions.json')) 'The settings backup misses the state files'
    Assert (Test-Path (Join-Path $BackupRoot '20260101-000000-000')) 'Pruning removed an update snapshot'
    Remove-OldSnapshots
    Assert ((Get-Nightly).Count -eq 7) "The update's pruning removed nightly backups"

    # An unfinished backup is removed by the next one.
    New-Item -ItemType Directory -Path (Join-Path $nightly '20260102-000000-000.partial') | Out-Null
    Invoke-NightlyBackup
    Assert (-not (Test-Path (Join-Path $nightly '20260102-000000-000.partial'))) 'An unfinished backup was kept'
    Assert ((Get-Nightly).Count -eq 7) 'Pruning after an unfinished backup failed'

    # A running update holds the lock: the backup gives up without a new backup.
    $before = (Get-Nightly).Name -join ','
    $BackupLockWait = 1
    $update = [IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
    $failed = $false
    try { Invoke-NightlyBackup } catch { $failed = $true } finally { $update.Dispose() }
    Assert $failed 'A backup ran while an update held the lock'
    Assert (((Get-Nightly).Name -join ',') -eq $before) 'A backup was made while an update held the lock'
    $BackupLockWait = 3600

    # The installed command carries its own copy of the functions it needs.
    Write-BackupCommand *> $null
    $command = Get-Content $BackupScript -Raw
    $null = [scriptblock]::Create($command)
    foreach ($name in 'Invoke-NightlyBackup', 'Invoke-DatabaseDump', 'Invoke-Tar', 'Sql', 'Get-MariaDb', 'Find-MariaDb', 'Write-Log') {
        Assert ($command -match "(?m)^function $name \{") "The backup command misses $name"
    }
    Assert ($command.Contains("`$HotelRoot = '$HotelRoot'")) 'The backup command misses the hotel folder'
    Assert ($script:Registered -like '*PlusEMU nightly backup*') 'The backup task was not registered'
    Write-Host 'PowerShell hardening checks passed'
} finally {
    Remove-Item $testDir -Recurse -Force
}
