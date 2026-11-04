<#
.SYNOPSIS
  One-click release build script for TinigSenyas Android APK.
.DESCRIPTION
  Builds the release APK optimized for Google Drive distribution and opens
  the destination folder in Windows Explorer.
#>

$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  TinigSenyas: Building Android Release   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "`n[1/3] Getting latest Flutter dependencies..." -ForegroundColor Yellow
flutter pub get

Write-Host "`n[2/3] Compiling Release APK (Split Per ABI)..." -ForegroundColor Yellow
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"
flutter build apk --split-per-abi

$outputDir = Join-Path $scriptDir "build\app\outputs\flutter-apk"
$apkFile = Join-Path $outputDir "app-arm64-v8a-release.apk"
if (-not (Test-Path $apkFile)) {
    $apkFile = Join-Path $outputDir "app-release.apk"
}

if (Test-Path $apkFile) {
    $namedApk = Join-Path $outputDir "tinigsenyas.apk"
    if ($apkFile -ne $namedApk) {
        Copy-Item -Path $apkFile -Destination $namedApk -Force
    }

    # Clean up all intermediate/split files so users only see the single official APK
    Get-ChildItem -Path $outputDir -Exclude "tinigsenyas.apk" | Remove-Item -Force

    # Copy directly to project root on Desktop
    $desktopRoot = "C:\Users\Jebi\Desktop\TinigSenyas"
    $rootApk = Join-Path $desktopRoot "tinigsenyas.apk"
    Copy-Item -Path $namedApk -Destination $rootApk -Force
    # Clean up any inner duplicate in repo
    $innerDuplicate = Join-Path (Split-Path -Parent $scriptDir) "tinigsenyas.apk"
    if (Test-Path $innerDuplicate) {
        Remove-Item -Path $innerDuplicate -Force
    }

    Write-Host "`n[3/3] Build Successful!" -ForegroundColor Green
    Write-Host "Single Android Release APK: $namedApk" -ForegroundColor Green
    Write-Host "Desktop Root Location:      $rootApk" -ForegroundColor Green
    Write-Host "`nOpening folder... Hand 'tinigsenyas.apk' directly to Android users!" -ForegroundColor Cyan
    explorer.exe /select,$namedApk
} else {
    Write-Host "`nBuild completed, but APK not found at expected path: $apkFile" -ForegroundColor Red
}

