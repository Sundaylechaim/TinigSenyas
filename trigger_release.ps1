# Script to trigger Unified Android & iOS Cloud Release via GitHub Actions
param (
    [string]$VersionTag = ""
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  TinigSenyas: Unified Android & iOS Cloud Release (CI/CD) " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$repoDir = $PSScriptRoot
Set-Location $repoDir

# 1. Read version from frontend/pubspec.yaml
$pubspecPath = Join-Path $repoDir "frontend\pubspec.yaml"
$detectedVersion = ""
if (Test-Path $pubspecPath) {
    $content = Get-Content $pubspecPath -Raw
    if ($content -match "version:\s*([\d.]+)") {
        $detectedVersion = "v" + $matches[1]
    }
}

if (-not $VersionTag) {
    if ($detectedVersion) {
        $VersionTag = Read-Host "Enter release tag [$detectedVersion]"
        if (-not $VersionTag) { $VersionTag = $detectedVersion }
    } else {
        $VersionTag = Read-Host "Enter release tag (e.g. v1.0.0)"
    }
}

Write-Host "`nTarget Release Tag: $VersionTag" -ForegroundColor Yellow

# 2. Check if tag exists
$existingTag = git tag -l $VersionTag
if ($existingTag) {
    Write-Host "Warning: Tag '$VersionTag' already exists locally." -ForegroundColor Red
    $choice = Read-Host "Do you want to delete existing tag locally and on GitHub to re-trigger? (y/N)"
    if ($choice -match '^[Yy]') {
        git tag -d $VersionTag
        git push origin --delete $VersionTag 2>$null
    } else {
        Write-Host "Aborted. Please bump the version in frontend/pubspec.yaml and try again." -ForegroundColor Yellow
        exit 1
    }
}

# 3. Stage and commit changes
Write-Host "`nStaging and committing files..." -ForegroundColor Cyan
git add -A
$status = git status --porcelain
if ($status) {
    git commit -m "release: $VersionTag unified Android & iOS build"
} else {
    Write-Host "Working tree clean, no new commits needed." -ForegroundColor Green
}

# 4. Push commit and tag
Write-Host "Pushing changes to GitHub..." -ForegroundColor Cyan
git push origin HEAD

Write-Host "Pushing release tag $VersionTag..." -ForegroundColor Cyan
git tag $VersionTag
git push origin $VersionTag

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host " Unified Build Successfully Triggered on GitHub!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host "Both Android APK and iOS IPA are compiling in the cloud:`n"
Write-Host "1. Watch the build pipeline: https://github.com/Sundaylechaim/TinigSenyas/actions" -ForegroundColor Cyan
Write-Host "2. Release download page:   https://github.com/Sundaylechaim/TinigSenyas/releases/tag/$VersionTag" -ForegroundColor Cyan
Write-Host "`nOnce finished (~5 mins), testers will find both:"
Write-Host "  - TinigSenyas-Android.apk (for Android phones)" -ForegroundColor Yellow
Write-Host "  - TinigSenyas-iOS.ipa    (for iPhones / Sideloadly)" -ForegroundColor Yellow
Write-Host "  - TinigSenyas-iOS-Simulator.zip (for web testing on Appetize.io)`n" -ForegroundColor Yellow

