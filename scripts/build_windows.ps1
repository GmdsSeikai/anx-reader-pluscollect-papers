param(
    [switch]$SkipBuild,
    [string]$StagingDirectory,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$releaseDirectory = Join-Path $repoRoot 'build/windows/x64/runner/Release'
if (-not $StagingDirectory) { $StagingDirectory = Join-Path $repoRoot 'build/windows/package-staging' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'build/windows/unsigned' }
$stagingPath = [IO.Path]::GetFullPath($StagingDirectory)
$outputPath = [IO.Path]::GetFullPath($OutputDirectory)
$archivePath = Join-Path $outputPath 'app.zip'
$stagingPrefix = $stagingPath.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($outputPath.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $outputPath.TrimEnd('\', '/') -eq $stagingPath.TrimEnd('\', '/')) {
    throw 'Package output must be outside the staging directory.'
}
$releasePrefix = [IO.Path]::GetFullPath($releaseDirectory).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($stagingPath.StartsWith($releasePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $stagingPath.TrimEnd('\', '/') -eq $releasePrefix.TrimEnd('\', '/')) {
    throw 'Package staging must be outside the Release directory.'
}
if (Test-Path -LiteralPath $stagingPath) {
    if (-not (Test-Path -LiteralPath $stagingPath -PathType Container) -or
        @(Get-ChildItem -LiteralPath $stagingPath -Force).Count -gt 0) {
        throw 'Package staging must be empty; choose a new directory.'
    }
}
if (Test-Path -LiteralPath $archivePath) { throw 'The output archive already exists; choose a new directory.' }

if (-not $SkipBuild) {
    Push-Location $repoRoot
    try {
        flutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }
        flutter gen-l10n
        if ($LASTEXITCODE -ne 0) { throw 'flutter gen-l10n failed.' }
        dart run build_runner build --delete-conflicting-outputs
        if ($LASTEXITCODE -ne 0) { throw 'Code generation failed.' }
        flutter build windows --release --target=lib/main.dart
        if ($LASTEXITCODE -ne 0) { throw 'Windows release build failed.' }
    } finally { Pop-Location }
}

foreach ($required in @('anx_reader.exe', 'data/app.so', 'flutter_windows.dll', 'WebView2Loader.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $required) -PathType Leaf)) {
        throw "Release package input is missing: $required"
    }
}
New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
Get-ChildItem -LiteralPath $releaseDirectory -Force | Copy-Item -Destination $stagingPath -Recurse
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'windows/x64') -File | Copy-Item -Destination $stagingPath
Copy-Item -LiteralPath (Join-Path $repoRoot 'windows/runner/resources/app_icon.ico') -Destination (Join-Path $stagingPath 'logo.ico')
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $stagingPath 'LICENSE')
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs/packaging/windows-portable.md') -Destination (Join-Path $stagingPath 'README.md')
$members = @(Get-ChildItem -LiteralPath $stagingPath -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($stagingPrefix.Length).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
[IO.File]::WriteAllText((Join-Path $stagingPath 'package-manifest.json'),
    (ConvertTo-Json -InputObject $members -Depth 4), [Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stagingPath, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
Write-Output "Generated Windows zip: $archivePath"

