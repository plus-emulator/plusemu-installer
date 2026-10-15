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
function Test-Password($Password) {
    return $Password.Length -ge 12 -and $Password -cmatch '[A-Z]' -and
        $Password -cmatch '[a-z]' -and $Password -match '[0-9]' -and $Password -match '[^a-zA-Z0-9\s]'
}
$testDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory $testDir | Out-Null
$previousTemp = $env:TEMP
$env:TEMP = $testDir
try {
    $StateFile = Join-Path $testDir 'hotel.json'
    $Log = Join-Path $testDir 'install.log'
    $HotelRoot = Join-Path $testDir 'hotel'
    $PhpDir = Join-Path $testDir 'php'
    $script:Step = 0; $TotalSteps = 10
    for ($i = 0; $i -lt 500; $i++) {
        $password = New-AdminPassword
        Assert ($password.Length -eq 20 -and (Test-Password $password)) 'Invalid generated admin password'
    }
    Assert (-not (Test-Password 'OriginalAlpha123')) 'Legacy password must fail the policy'
    Assert ((New-Secret 32) -cmatch '^[A-Za-z0-9]{32}$') 'Database password format changed'
    $env:PLUSEMU_DOMAIN = 'example.com'; $env:PLUSEMU_WS_URL = 'wss://example.com/ws'
    $env:PLUSEMU_HOTEL_NAME = 'Example'; $env:PLUSEMU_ADMIN_USER = 'Ruiz'
    $env:PLUSEMU_ADMIN_EMAIL = 'ruiz@example.com'; $env:PLUSEMU_YES = '1'
    Read-Answers *> $null
    Assert (Test-Password $state.AdminPassword) 'Fresh setup password invalid'
    $initial = $state.AdminPassword; $database = $state.DbPassword; $dbRoot = $state.DbRootPassword
    Read-Answers *> $null
    Assert ($state.AdminPassword -ceq $initial -and $state.DbPassword -ceq $database -and $state.DbRootPassword -ceq $dbRoot) 'Rerun changed saved credentials'

    # Run the real CMS flow with external commands mocked. Stop before OS setup.
    New-Item -ItemType Directory "$HotelRoot/cms" -Force | Out-Null
    Set-Content "$HotelRoot/cms/.env" ''
    # Windows paths need normalization only for running these stubs on Linux.
    $script:SetEnvValueImpl = ${function:Set-EnvValue}
    function Set-EnvValue($File, $Key, $Value) {
        if ([IO.Path]::DirectorySeparatorChar -eq '/') { $File = $File.Replace('\', '/') }
        & $script:SetEnvValueImpl $File $Key $Value
    }
    function Invoke-WebRequest { return @{ Content = '192.0.2.0/24' } }
    function Sql { return $script:Completed }
    function Run {
        param($Exe, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
        if ($Arguments -contains 'atom:setup') {
            Assert (Test-Password $env:ATOM_ADMIN_PASSWORD) 'CMS received invalid password'
            $script:UsedPassword = $env:ATOM_ADMIN_PASSWORD
            throw 'TEST_SETUP_REACHED'
        }
        if ($Arguments -contains 'optimize:clear') { throw 'TEST_COMPLETED_REACHED' }
    }
    function Invoke-TestCms($ExpectedStop) {
        try { Install-Cms *> $null; throw 'Expected test stop was not reached' }
        catch { if ($_.Exception.Message -ne $ExpectedStop) { throw } }
        finally { Pop-Location }
    }
    $state.AdminPassword = 'OriginalAlpha123'
    $state | ConvertTo-Json | Set-Content $StateFile
    $script:Completed = 0
    Invoke-TestCms 'TEST_SETUP_REACHED'
    $saved = Get-Content $StateFile -Raw | ConvertFrom-Json
    Assert ($saved.AdminPassword -ceq $script:UsedPassword -and (Test-Password $saved.AdminPassword)) 'Repair not saved before setup'
    Assert ($saved.DbPassword -ceq $database -and $saved.DbRootPassword -ceq $dbRoot) 'Repair changed database credentials'
    $repaired = $saved.AdminPassword
    Invoke-TestCms 'TEST_SETUP_REACHED'
    Assert ($state.AdminPassword -ceq $repaired) 'Retry changed a valid password'
    $state.AdminPassword = 'OriginalAlpha123'
    $state | ConvertTo-Json | Set-Content $StateFile
    $script:Completed = 1; $script:UsedPassword = $null
    Invoke-TestCms 'TEST_COMPLETED_REACHED'
    $saved = Get-Content $StateFile -Raw | ConvertFrom-Json
    Assert ($saved.AdminPassword -ceq 'OriginalAlpha123' -and $null -eq $script:UsedPassword) 'Completed setup changed admin credentials'

    $summary = Complete-Install 6>&1 | Out-String
    foreach ($secret in $state.AdminPassword, $database, $dbRoot) {
        Assert ($summary.Contains($secret)) 'Password absent from terminal summary'
        Assert (-not (Get-Content $Log -Raw).Contains($secret)) 'Password leaked into installer log'
    }
    Assert ($summary.Contains('Host: 127.0.0.1    Port: 3306    Database: plus    Username: hotel')) 'Missing database connection details'
    Assert ($summary.Contains("Get-Content $StateFile")) 'Missing password retrieval command'
    # Guide rendering does not receive password values.
    $guide = Join-Path $testDir 'guide.html'
    Render "$root/templates/setup-guide.html" $guide @{ CREDENTIALS_FILE = $StateFile; DOMAIN = $state.Domain }
    foreach ($secret in $state.AdminPassword, $database, $dbRoot) {
        Assert (-not (Get-Content $guide -Raw).Contains($secret)) 'Password leaked into setup guide'
    }
    Write-Host 'PowerShell credential regression checks passed'
} finally {
    foreach ($name in 'PLUSEMU_DOMAIN', 'PLUSEMU_WS_URL', 'PLUSEMU_HOTEL_NAME', 'PLUSEMU_ADMIN_USER', 'PLUSEMU_ADMIN_EMAIL', 'PLUSEMU_YES', 'ATOM_ADMIN_PASSWORD', 'ATOM_ADMIN_EMAIL', 'COMPOSER_ALLOW_SUPERUSER', 'COMPOSER_NO_INTERACTION') {
        Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
    }
    $env:TEMP = $previousTemp
    Remove-Item $testDir -Recurse -Force
}
