# Switch a hotel's language against fake downloads, database, PHP and service commands, and check what it writes.
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
    $LockFile = Join-Path $testDir 'lock'
    $Downloads = Join-Path $testDir 'downloads'
    $PhpDir = Join-Path $testDir 'php'
    $LanguageManifestUrl = 'https://assets.test/language'
    $AirPort = 30000
    $script:Log = Join-Path $testDir 'install.log'
    $script:Step = 0; $script:TotalSteps = 1
    $script:ServerIp = '192.0.2.10'
    $published = Join-Path $testDir 'published'
    $files = Join-Path $HotelRoot 'hotel-files'
    $gamedata = Join-Path $files 'gamedata'
    $languageDir = Join-Path $files 'language'
    $renderer = Join-Path (Join-Path (Join-Path $HotelRoot 'client') 'configuration') 'renderer-config.json'
    $config = Join-Path (Join-Path (Join-Path $HotelRoot 'emulator') 'Config') 'config.json'
    $envFile = Join-Path (Join-Path $HotelRoot 'cms') '.env'
    New-Item -ItemType Directory -Force -Path $StateDir, $Downloads, $published, $gamedata, (Split-Path $renderer), (Split-Path $config), (Split-Path $envFile) | Out-Null
    $script:state = [pscustomobject]@{ Domain = 'example.com'; Local = $false; Air = $true; AirGameHost = ''; Language = 'en'; FurniLanguage = 'en' }

    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:Statements = ''
    $script:Running = $true
    function Run { $script:Calls.Add("$args") }
    function Import-Database($File) { $script:Calls.Add('import'); $script:Statements = Get-Content $File -Raw -Encoding UTF8 }
    function Get-Service { return [pscustomobject]@{ Status = if ($script:Running) { 'Running' } else { 'Stopped' } } }
    function Restart-Service { $script:Calls.Add("restart $args") }
    function Wait-Emulator { return $true }
    function Get-NodeExe { return (Get-Command node).Source }
    # The published files are served from the test folder, like assets.plusemu.dev.
    function Invoke-Curl([string[]]$Arguments) {
        $out = $Arguments[[array]::IndexOf($Arguments, '-o') + 1]
        $source = Join-Path $published ($Arguments[-1] -replace '^.*/', '')
        if (-not (Test-Path $source)) { return @{ Code = 22; Output = '' } }
        Copy-Item $source $out
        return @{ Code = 0; Output = '' }
    }
    function Invoke-Tar([string[]]$Arguments) { & tar @Arguments; return $LASTEXITCODE }
    function Get-Sha($File) { return (Get-FileHash $File -Algorithm SHA256).Hash.ToLower() }
    function Publish($Code, $Greeting) {
        $pack = Join-Path $testDir "pack-$Code"
        if (Test-Path $pack) { Remove-Item $pack -Recurse -Force }
        New-Item -ItemType Directory -Path $pack | Out-Null
        Write-Utf8 (Join-Path $pack 'ExternalTexts.json') (@{ 'widget.greeting' = $Greeting } | ConvertTo-Json)
        Write-Utf8 (Join-Path $pack 'UITexts.jsonc') "{`n    // $Code`n    `"connection.login.name`": `"Name`"`n}`n"
        Write-Utf8 (Join-Path $pack 'furni-names.json') (@{ shelves_norja = @{ name = "Regal $Greeting"; description = "F$([char]0xFC)r O'Brien \ B$([char]0xFC)cher." } } | ConvertTo-Json)
        Write-Utf8 (Join-Path $pack 'product-names.json') (@{ shelves_norja = @{ name = 'Beiges Regal'; description = "F$([char]0xFC)r B$([char]0xFC)cher." }; '25' = @{ name = 'Schulset'; description = 'Blau.' } } | ConvertTo-Json)
        $archive = Join-Path $published "language-$Code.tar.gz"
        & tar -czf $archive -C $pack .
        Write-Utf8 (Join-Path $published "$Code.json") (@{
            language = $Code; hotel = 'https://www.habbo.test'; url = "https://assets.test/language/language-$Code.tar.gz"; sha256 = Get-Sha $archive
        } | ConvertTo-Json)
    }
    function Read-Json($File) { return Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json }

    # The stock hotel: English gamedata, the installer's client settings, an emulator with the AIR client and the website.
    Write-Utf8 (Join-Path $gamedata 'ProductData.json') '{"productdata":{"product":[{"code":"shelves_norja","name":"Beige Bookcase","description":"For books.","extra":1},{"code":"chair","name":"Chair","description":"Sit."},{"code":25,"name":"School Set","description":"Blue."}]}}'
    Write-Utf8 (Join-Path $gamedata 'FurnitureData.json') '{"roomitemtypes":{"furnitype":[{"id":13,"classname":"shelves_norja","name":"Beige Bookcase","description":"For books."}]},"wallitemtypes":{"furnitype":[{"id":4001,"classname":"poster","name":"Poster","description":null}]}}'
    $stockRenderer = @'
{
    "external.texts.url": [
        "${gamedata.url}/ExternalTexts.json?t=%timestamp%",
        "${gamedata.url}/UITexts.jsonc?t=%timestamp%",
        "${gamedata.url}/hotel-texts.json?t=%timestamp%"
    ],
    "productdata.url": "${gamedata.url}/ProductData.json?t=%timestamp%",
    "furni.rotation.bounce.height": 0.0625
}
'@
    Write-Utf8 $renderer $stockRenderer
    $stockProducts = Join-Path $gamedata 'ProductData.json'
    Write-Utf8 $config (@{
        AirClient = @{ ExternalTextsFiles = @('air/external_flash_texts.txt', (Join-Path $gamedata 'ExternalTexts.json'), 'my-texts.txt'); ProductDataFile = $stockProducts }
        Database = @{ Password = 'secret' }
    } | ConvertTo-Json -Depth 5)
    $stockConfig = Get-Content $config -Raw
    Write-Utf8 $envFile "APP_NAME=`"Example`"`nAPP_LOCALE=`"en`"`n"

    # The choice: -Language or PLUSEMU_LANGUAGE, then the saved one, then English.
    Assert ((Resolve-Language '') -eq 'en') 'The default is not English'
    Assert ((Resolve-Language 'fr') -eq 'fr') 'The saved choice was lost'
    $env:PLUSEMU_LANGUAGE = 'nl'
    Assert ((Resolve-Language 'fr') -eq 'nl') 'PLUSEMU_LANGUAGE was ignored'
    Remove-Item Env:\PLUSEMU_LANGUAGE
    $Language = 'DE'
    Assert ((Resolve-Language 'fr') -eq 'de') '-Language was ignored'
    $Language = 'xx'
    $failed = $null
    try { Resolve-Language '' } catch { $failed = "$_" }
    Assert ($failed -like 'Unknown language: xx*') "Unknown language: $failed"
    $Language = ''

    # The published pack is downloaded and checked.
    $state.Language = 'de'
    Save-State
    Publish 'de' 'Hallo'
    Assert (Get-LanguagePack) "Download: $script:LanguageError"
    Assert ((Get-ActiveLanguage) -eq 'de') 'The pack is not active'
    Assert ((Read-Json (Join-Path $languageDir 'ExternalTexts.json')).'widget.greeting' -eq 'Hallo') 'The texts were not saved'
    # A pack that does not match its checksum changes nothing, and says why.
    Publish 'de' 'Servus'
    Add-Content (Join-Path $published 'language-de.tar.gz') 'tampered'
    Assert (-not (Get-LanguagePack)) 'A tampered pack was accepted'
    Assert ($script:LanguageError -like '*German*checksum*') "Reason: $script:LanguageError"
    Assert ((Read-Json (Join-Path $languageDir 'ExternalTexts.json')).'widget.greeting' -eq 'Hallo') 'A failed download replaced the texts'
    # A list for another language is refused too.
    Publish 'de' 'Hallo'
    $manifest = Read-Json (Join-Path $published 'de.json'); $manifest.language = 'nl'
    Write-Utf8 (Join-Path $published 'de.json') ($manifest | ConvertTo-Json)
    Assert (-not (Get-LanguagePack)) 'A list for another language was accepted'
    Assert ($script:LanguageError -like "*$LanguageManifestUrl/de.json*") "Reason: $script:LanguageError"

    # Switching to German.
    Publish 'de' 'Hallo'
    $script:Calls.Clear()
    $output = Set-HotelLanguage -Restart 6>&1 | Out-String
    Assert ($output -like '*German language pack downloaded and checked*') "Output: $output"
    $settings = Read-Json $renderer
    $base = 'https://example.com/hotel-files/language'
    $expected = '${gamedata.url}/ExternalTexts.json?t=%timestamp%', "$base/ExternalTexts.json?t=%timestamp%", '${gamedata.url}/UITexts.jsonc?t=%timestamp%', "$base/UITexts.jsonc?t=%timestamp%", '${gamedata.url}/hotel-texts.json?t=%timestamp%'
    Assert ((@($settings.'external.texts.url') -join ',') -eq ($expected -join ',')) "Texts: $($settings.'external.texts.url' -join ',')"
    Assert ($settings.'productdata.url' -eq "$base/ProductData.json?t=%timestamp%") "Products: $($settings.'productdata.url')"
    Assert ((Get-Content $renderer -Raw) -match '"furni.rotation.bounce.height": 0.0625') 'A number setting changed'
    $products = (Read-Json (Join-Path $languageDir 'ProductData.json')).productdata.product
    Assert ($products.Count -eq 3 -and $products[0].name -eq 'Beiges Regal' -and $products[0].extra -eq 1 -and $products[1].name -eq 'Chair' -and $products[2].name -eq 'Schulset' -and $products[2].code -eq 25) "Merged products: $($products | ConvertTo-Json -Compress)"
    $air = (Read-Json $config).AirClient
    Assert ((@($air.ExternalTextsFiles) -join ',') -eq "air/external_flash_texts.txt,$(Join-Path $gamedata 'ExternalTexts.json'),my-texts.txt,$(Join-Path $languageDir 'ExternalTexts.json')") "AIR texts: $($air.ExternalTextsFiles -join ',')"
    Assert ($air.ProductDataFile -eq (Join-Path $languageDir 'ProductData.json')) "AIR products: $($air.ProductDataFile)"
    Assert ((Read-Json $config).Database.Password -eq 'secret') 'Another setting changed'
    Assert (@(Get-Content $envFile) -contains 'APP_LOCALE="de"') 'The website language was not set'
    Assert ($script:Calls -match 'artisan optimize') "Calls: $($script:Calls -join '; ')"
    # One backslash becomes two and one quote becomes two, so MariaDB reads the text back as it was.
    Assert ($script:Statements.Contains("('shelves_norja', 'Regal Hallo', 'F$([char]0xFC)r O''Brien \\ B$([char]0xFC)cher.')")) "SQL: $script:Statements"
    Assert ($script:Statements.Contains('UPDATE furniture f INNER JOIN language_furni_names n ON n.classname = f.item_name')) "SQL: $script:Statements"
    Assert ((Read-Json $StateFile).FurniLanguage -eq 'de') 'The furniture language was not saved'
    Assert ($script:Calls -contains 'restart PlusEMU') "Calls: $($script:Calls -join '; ')"

    # A second run changes nothing: no names written again, no restart, no website rebuild.
    $rendererAfter = Get-Content $renderer -Raw; $configAfter = Get-Content $config -Raw
    $script:Calls.Clear()
    $null = Set-HotelLanguage -Restart 6>&1
    Assert ((Get-Content $renderer -Raw) -eq $rendererAfter -and (Get-Content $config -Raw) -eq $configAfter) 'A second run changed the settings'
    Assert ($script:Calls.Count -eq 0) "Calls: $($script:Calls -join '; ')"

    # The AIR settings the installer writes again keep the German products.
    $json = Read-Json $config
    Set-AirSettings $json
    Assert ($json.AirClient.ProductDataFile -eq (Join-Path $languageDir 'ProductData.json')) "AIR products after Set-AirSettings: $($json.AirClient.ProductDataFile)"
    Assert (@($json.AirClient.ExternalTextsFiles | Where-Object { $_ -eq (Join-Path $languageDir 'ExternalTexts.json') }).Count -eq 1) 'The German AIR texts are missing or doubled'

    # A hotel with German texts keeps them when the pack list is gone.
    Remove-Item (Join-Path $published 'de.json')
    $output = Set-HotelLanguage -Restart 6>&1 | Out-String
    Assert ($output -like '*keeps the German texts it had*') "Output: $output"
    Assert ((Get-ActiveLanguage) -eq 'de') 'The German texts were lost'
    # A hotel without them stays English for now, and the furniture names follow what the client shows.
    Remove-Item $languageDir -Recurse -Force
    $output = Set-HotelLanguage -Restart 6>&1 | Out-String
    Assert ($output -like '*stays English for now. Try again later: plusemu-update -Language de*') "Output: $output"
    Assert ((Read-Json $renderer).'productdata.url' -eq '${gamedata.url}/ProductData.json?t=%timestamp%') 'The client still loads the German products'
    Assert ((Read-Json $config).AirClient.ProductDataFile -eq $stockProducts) 'The AIR client still loads the German products'
    Assert ($script:Statements.Contains("('shelves_norja', 'Beige Bookcase', 'For books.')") -and $script:Statements.Contains("('poster', 'Poster', '')")) "SQL: $script:Statements"
    Assert ((Read-Json $StateFile).FurniLanguage -eq 'en') 'The furniture language was not saved'

    # Back to English.
    Publish 'de' 'Hallo'
    $null = Set-HotelLanguage -Restart 6>&1
    Assert ((Get-ActiveLanguage) -eq 'de') 'German did not come back'
    $state.Language = 'en'
    Save-State
    $script:Calls.Clear()
    $null = Set-HotelLanguage -Restart 6>&1
    Assert (-not (Test-Path $languageDir)) 'The language folder stayed'
    Assert (((Read-Json $renderer) | ConvertTo-Json -Depth 5) -eq (($stockRenderer | ConvertFrom-Json) | ConvertTo-Json -Depth 5)) "Renderer: $(Get-Content $renderer -Raw)"
    Assert (((Read-Json $config) | ConvertTo-Json -Depth 5) -eq (($stockConfig | ConvertFrom-Json) | ConvertTo-Json -Depth 5)) "Config: $(Get-Content $config -Raw)"
    Assert (@(Get-Content $envFile) -contains 'APP_LOCALE="en"') 'The website stayed German'
    Assert ((Read-Json $StateFile).FurniLanguage -eq 'en') 'The furniture names stayed German'
    Assert ($script:Calls -contains 'restart PlusEMU') "Calls: $($script:Calls -join '; ')"

    # A client configuration that is not plain JSON is left alone, with a warning.
    Write-Utf8 $renderer "{ // my notes`n}`n"
    $output = Set-LanguageClientConfig $renderer 6>&1 | Out-String
    Assert ((Get-Content $renderer -Raw) -eq "{ // my notes`n}`n") 'A configuration with comments was changed'
    Assert ($output -like '*not plain JSON*') "Output: $output"

    Write-Host 'PowerShell language checks passed'
} finally {
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}
