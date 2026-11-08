param(
    [Parameter(Mandatory)][string]$Godot,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$Iscc,
    [switch]$AndroidRelease,
    [int]$AndroidVersionCode,
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) {
    throw "Use a new output directory: $Output"
}
New-Item -ItemType Directory -Path "$Output/windows" | Out-Null

function Invoke-Godot {
    & $Godot --headless --path $project @args 2>&1 | ForEach-Object {
        Write-Host $_
        if ("$_" -match '^(SCRIPT ERROR:|ERROR:)') { $script:godotError = $true }
    }
    if ($LASTEXITCODE -ne 0 -or $script:godotError) {
        throw "Godot failed: $args"
    }
}

Invoke-Godot --import
Invoke-Godot --export-release 'Windows Desktop' "$Output/windows/FazDevilCorp.exe"
foreach ($file in 'FazDevilCorp.exe', 'libgodotsteam.windows.template_release.x86_64.dll', 'steam_api64.dll') {
    if (!(Test-Path -LiteralPath "$Output/windows/$file" -PathType Leaf)) {
        throw "Missing Windows export file: $file"
    }
}

$preset = Join-Path $project 'export_presets.cfg'
$apk = "$Output/FazDevilCorp-Android-Test.apk"
if ($AndroidRelease) {
    if ($AndroidVersionCode -lt 1 -or $AndroidVersionCode -gt 2100000000 -or $Version -notmatch '^v\d+\.\d+\.\d+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$') {
        throw 'Supply a valid release version and Android version code.'
    }
    $original = [IO.File]::ReadAllBytes($preset)
    try {
        $config = [Text.Encoding]::UTF8.GetString($original)
        $config = $config -replace '(?m)^version/code=\d+', "version/code=$AndroidVersionCode"
        $config = $config -replace '(?m)^version/name="[^"]+"', ('version/name="' + $Version.Substring(1) + '"')
        [IO.File]::WriteAllText($preset, $config)
        Invoke-Godot --export-release 'Android Test' $apk
    } finally {
        [IO.File]::WriteAllBytes($preset, $original)
    }
} else {
    Invoke-Godot --export-debug 'Android Test' $apk
}
if (!(Test-Path -LiteralPath $apk -PathType Leaf)) { throw 'Missing Android APK' }

$windows = Join-Path $Output 'windows'
Set-Content -LiteralPath "$windows/steam_appid.txt" -Value '480' -Encoding ascii
$installerArgs = @("/DPayloadDir=$windows", "/O$Output", '/FFazDevilCorp-Windows-Setup')
if ($AndroidRelease) { $installerArgs += "/DMyAppVersion=$($Version.Substring(1))" }
& $Iscc @installerArgs (Join-Path $project 'installer/fazdevilcorp.iss')
if ($LASTEXITCODE -ne 0) { throw 'Windows installer compilation failed' }
Get-Item "$Output/FazDevilCorp-Windows-Setup.exe", $apk | Select-Object Name, Length
