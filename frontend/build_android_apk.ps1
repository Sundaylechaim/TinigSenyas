<#
.SYNOPSIS
  Builds one Shorebird-enabled ARM64 release APK for TinigSenyas.
.DESCRIPTION
  Publishes the Shorebird release for the version in pubspec.yaml, then leaves
  one signed APK at Flutter's standard output path for Drive distribution.
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

if (-not (Get-Command shorebird -ErrorAction SilentlyContinue)) {
    throw "Shorebird CLI is required. Install and authenticate it before releasing."
}

$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
if (-not (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
    throw "Android Studio JDK was not found at $env:JAVA_HOME."
}

Write-Host "[1/3] Resolving locked Flutter dependencies..." -ForegroundColor Yellow
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "Flutter dependency resolution failed." }

Write-Host "[2/3] Publishing the Shorebird-enabled ARM64 release..." -ForegroundColor Yellow
shorebird release android --artifact apk --target-platform=android-arm64 --flutter-version=3.47.9
if ($LASTEXITCODE -ne 0) { throw "Shorebird release failed." }

$outputsDir = Join-Path $scriptDir "build\app\outputs"
$apkFile = Join-Path $outputsDir "flutter-apk\app-release.apk"
if (-not (Test-Path $apkFile)) {
    throw "Shorebird finished without producing the expected APK: $apkFile"
}

# Keep the standard Flutter artifact as the one local distributable APK.
Get-ChildItem -LiteralPath $outputsDir -Filter *.apk -Recurse -File |
    Where-Object { $_.FullName -ne $apkFile } |
    Remove-Item -Force

Write-Host "[3/3] Release APK ready:" -ForegroundColor Green
Write-Host $apkFile -ForegroundColor Green
explorer.exe /select,$apkFile
