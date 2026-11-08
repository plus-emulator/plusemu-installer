# Set up the camera service against fake npm, service and permission commands, and check what it writes.
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
    $script:Log = Join-Path $testDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 1
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:Services = @{}
    $script:CameraAnswers = $true
    function Run { $script:Calls.Add("$args") }
    function Get-Service($Name) { if ($script:Services.ContainsKey($Name)) { return [pscustomobject]@{ Name = $Name } } }
    function Start-Service($Name) { $script:Calls.Add("Start-Service $Name"); $script:Services[$Name] = $true }
    function Stop-Service($Name) { $script:Calls.Add("Stop-Service $Name") }
    function Restart-Service($Name) { $script:Calls.Add("Restart-Service $Name") }
    function Invoke-WebRequest { if (-not $script:CameraAnswers) { throw 'no answer' } }
    function Start-Sleep { }
    function Get-NodeExe { return (Join-Path (Join-Path $testDir 'node') 'node.exe') }

    $emulator = Join-Path $HotelRoot 'emulator'
    $renderer = Join-Path $emulator 'CameraRenderer'
    New-Item -ItemType Directory -Force -Path (Join-Path $emulator 'Config'), $renderer, (Join-Path $emulator 'service') | Out-Null
    Set-Content (Join-Path (Join-Path $emulator 'service') 'shawl.exe') 'shawl'

    # A new hotel gets a camera password and a photo folder that IIS serves.
    $json = '{"Camera":{"RendererUrl":"http://127.0.0.1:3921/render","Bearer":"","OutputDirectory":"camera"}}' | ConvertFrom-Json
    Set-CameraSettings $json
    $bearer = $json.Camera.Bearer
    Assert ($bearer.Length -eq 48) "Camera password: $bearer"
    Assert ($json.Camera.OutputDirectory -eq (Join-Path $HotelRoot 'camera')) "Photo folder: $($json.Camera.OutputDirectory)"
    Assert ($json.Camera.RendererUrl -eq 'http://127.0.0.1:3921/render') 'The renderer address changed'

    # A rerun or an update keeps them, and the owner's own settings too.
    Set-CameraSettings $json
    Assert ($json.Camera.Bearer -eq $bearer) 'The camera password changed on a rerun'
    $json.Camera.OutputDirectory = 'D:\Photos'
    Set-CameraSettings $json
    Assert ($json.Camera.OutputDirectory -eq 'D:\Photos') 'The owner''s photo folder was replaced'
    # An emulator config from before the camera gets the settings too.
    $old = '{"Database":{}}' | ConvertFrom-Json
    Set-CameraSettings $old
    Assert ($old.Camera.Bearer.Length -eq 48) 'An old config got no camera password'
    $json.Camera.OutputDirectory = 'camera'
    Write-Utf8 (Join-Path (Join-Path $emulator 'Config') 'config.json') ($json | ConvertTo-Json -Depth 5)

    # An emulator release without the camera service skips the step.
    Install-Camera *> $null
    Assert (-not (Test-Path (Join-Path $HotelRoot 'camera-service'))) 'The camera was set up without a camera service'

    # The service reads the installer's hotel files and the installed client, with the emulator's password.
    Set-Content (Join-Path $renderer 'server.mjs') 'server'
    $output = Install-Camera 6>&1 | Out-String
    Assert ($output -like '*Players can take photos (service: PlusEMUCamera)*') "Camera step: $output"
    $service = Join-Path $HotelRoot 'camera-service'
    $envFile = Join-Path $service 'camera.env'
    $values = @{}
    foreach ($line in Get-Content $envFile) { $key, $value = $line -split '=', 2; $values[$key] = $value }
    Assert ($values.CAMERA_RENDERER_SECRET -eq $bearer) 'The camera service has another password'
    Assert ($values.CAMERA_ASSET_LAYOUT -eq 'hotel-files') "Asset layout: $($values.CAMERA_ASSET_LAYOUT)"
    Assert ($values.CAMERA_ASSET_ROOT -eq (Join-Path $HotelRoot 'hotel-files')) "Asset folder: $($values.CAMERA_ASSET_ROOT)"
    Assert ($values.CAMERA_MEDIA_ROOT -eq (Join-Path $HotelRoot 'camera')) "Photo folder: $($values.CAMERA_MEDIA_ROOT)"
    Assert ($values.CAMERA_PAGE_ROOT -eq (Join-Path $HotelRoot 'client')) "Client folder: $($values.CAMERA_PAGE_ROOT)"
    Assert (Test-Path (Join-Path (Join-Path $service 'app') 'server.mjs')) 'The service has no copy of the camera program'
    Assert ($script:Calls -match 'npm.cmd ci --omit=dev') "Calls: $($script:Calls -join '; ')"
    Assert ($script:Calls -match 'npx.cmd playwright install --only-shell chromium') "Calls: $($script:Calls -join '; ')"
    Assert ($script:Calls -match "icacls.exe $([regex]::Escape($envFile)) /inheritance:r") 'The password file is readable by everyone'
    Assert ($script:Calls -match "shawl.exe add --name PlusEMUCamera .* --env-file=$([regex]::Escape($envFile)) server.mjs") "Calls: $($script:Calls -join '; ')"
    Assert ($script:Calls -contains 'Start-Service PlusEMUCamera') 'The camera service was not started'

    # A rerun stops the running service before it replaces the program.
    $script:Calls.Clear()
    Install-Camera *> $null
    Assert ($script:Calls[0] -eq 'Stop-Service PlusEMUCamera') "First call: $($script:Calls[0])"
    Assert (-not ($script:Calls -match 'shawl.exe add')) 'The service was added twice'

    # A failed setup warns and lets the rest of the install go on.
    $script:CameraAnswers = $false
    $output = Install-Camera 6>&1 | Out-String
    Assert ($output -like '*The camera could not be set up, so photos do not work yet*') "Camera step: $output"
    $script:CameraAnswers = $true

    # An update to an emulator without the camera service turns the service off.
    Remove-Item (Join-Path $renderer 'server.mjs')
    $script:Calls.Clear()
    Update-CameraService
    Assert ($script:Calls -contains 'Stop-Service PlusEMUCamera') "Calls: $($script:Calls -join '; ')"
    Assert ($script:Calls -contains 'sc.exe config PlusEMUCamera start= disabled') "Calls: $($script:Calls -join '; ')"
    Write-Host 'PowerShell camera checks passed'
} finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
