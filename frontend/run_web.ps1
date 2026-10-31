$ErrorActionPreference = 'Stop'

$frontendPath = $PSScriptRoot
$backendPath = Join-Path (Split-Path $frontendPath -Parent) 'backend'
$backendRequirements = Join-Path $backendPath 'requirements.txt'
$backendVenv = Join-Path $backendPath '.venv'
$backendPython = Join-Path $backendVenv 'Scripts\python.exe'

function Get-CompatiblePython {
    $knownCandidates = @(
        'C:\Users\Jebi\AppData\Local\Python\pythoncore-3.10-64\python.exe',
        'C:\Python310\python.exe',
        'C:\Python311\python.exe',
        'C:\Python312\python.exe'
    )
    foreach ($cand in $knownCandidates) {
        if (Test-Path -LiteralPath $cand) {
            return $cand
        }
    }
    foreach ($ver in @('-3.10', '-3.11', '-3.12')) {
        try {
            $foundPath = (& py $ver -c "import sys; print(sys.executable)" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $foundPath -and (Test-Path -LiteralPath $foundPath.Trim())) {
                return $foundPath.Trim()
            }
        } catch {}
    }
    return (Get-Command python -ErrorAction Stop).Source
}

$systemPython = Get-CompatiblePython
$backendLog = Join-Path $env:TEMP "tinigsenyas-backend-$PID.log"
$backendErrorLog = Join-Path $env:TEMP "tinigsenyas-backend-$PID-error.log"
$dependencyCheckLog = Join-Path $env:TEMP "tinigsenyas-dependency-check-$PID.log"
$dependencyCheckErrorLog = Join-Path $env:TEMP "tinigsenyas-dependency-check-$PID-error.log"
$dependencyInstallLog = Join-Path $env:TEMP "tinigsenyas-dependency-install-$PID.log"
$dependencyInstallErrorLog = Join-Path $env:TEMP "tinigsenyas-dependency-install-$PID-error.log"
$backendProcess = $null
$startedBackend = $false

function Test-BackendDependencies {
    Remove-Item -LiteralPath $dependencyCheckLog, $dependencyCheckErrorLog `
        -Force -ErrorAction SilentlyContinue
    $checkProcess = Start-Process `
        -FilePath $backendPython `
        -ArgumentList '-c', '"import cv2,edge_tts,fastapi,uvicorn,mediapipe,numpy"' `
        -WorkingDirectory $backendPath `
        -PassThru `
        -Wait `
        -NoNewWindow `
        -RedirectStandardOutput $dependencyCheckLog `
        -RedirectStandardError $dependencyCheckErrorLog
    return ($checkProcess.ExitCode -eq 0)
}

function Test-SpeechBackend {
    try {
        $response = Invoke-WebRequest `
            -UseBasicParsing `
            -Uri 'http://127.0.0.1:5000/tts/health' `
            -TimeoutSec 1 `
            -ErrorAction Stop
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

Push-Location $backendPath
try {
    if (-not (Test-Path -LiteralPath $backendPython)) {
        Write-Host 'Creating an isolated Python environment for the backend...' -ForegroundColor Cyan
        Remove-Item -LiteralPath $dependencyInstallLog, $dependencyInstallErrorLog `
            -Force -ErrorAction SilentlyContinue
        $venvProcess = Start-Process `
            -FilePath $systemPython `
            -ArgumentList "-m venv `"$backendVenv`"" `
            -WorkingDirectory $backendPath `
            -PassThru `
            -Wait `
            -NoNewWindow `
            -RedirectStandardOutput $dependencyInstallLog `
            -RedirectStandardError $dependencyInstallErrorLog
        if ($venvProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $backendPython)) {
            $details = @()
            foreach ($log in @($dependencyInstallLog, $dependencyInstallErrorLog)) {
                if (Test-Path -LiteralPath $log) {
                    $details += Get-Content -LiteralPath $log -Raw
                }
            }
            throw "Could not create the backend Python environment. $($details -join [Environment]::NewLine)"
        }
    }

    if (-not (Test-BackendDependencies)) {
        Write-Host 'Installing backend packages required for camera and Filipino speech...' -ForegroundColor Cyan
        Remove-Item -LiteralPath $dependencyInstallLog, $dependencyInstallErrorLog `
            -Force -ErrorAction SilentlyContinue
        $installProcess = Start-Process `
            -FilePath $backendPython `
            -ArgumentList "-m pip install -r `"$backendRequirements`"" `
            -WorkingDirectory $backendPath `
            -PassThru `
            -Wait `
            -NoNewWindow `
            -RedirectStandardOutput $dependencyInstallLog `
            -RedirectStandardError $dependencyInstallErrorLog
        if ($installProcess.ExitCode -ne 0) {
            $details = @()
            foreach ($log in @($dependencyInstallLog, $dependencyInstallErrorLog)) {
                if (Test-Path -LiteralPath $log) {
                    $details += Get-Content -LiteralPath $log -Raw
                }
            }
            throw "Could not install backend packages from requirements.txt. $($details -join [Environment]::NewLine)"
        }
        if (-not (Test-BackendDependencies)) {
            $details = ''
            if (Test-Path -LiteralPath $dependencyCheckErrorLog) {
                $details = Get-Content -LiteralPath $dependencyCheckErrorLog -Raw
            }
            throw "Backend packages are still unavailable after installation. $details"
        }
    }

    if (-not (Test-SpeechBackend)) {
        Write-Host 'Starting TinigSenyas backend server on port 5000...' -ForegroundColor Cyan
        $backendProcess = Start-Process `
            -FilePath $backendPython `
            -ArgumentList 'server.py' `
            -WorkingDirectory $backendPath `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $backendLog `
            -RedirectStandardError $backendErrorLog
        $startedBackend = $true

        $backendReady = $false
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            if ($backendProcess.HasExited) {
                $details = ''
                if (Test-Path -LiteralPath $backendErrorLog) {
                    $details = Get-Content -LiteralPath $backendErrorLog -Raw
                }
                throw "The speech backend exited before becoming ready. $details"
            }
            if (Test-SpeechBackend) {
                $backendReady = $true
                break
            }
            Start-Sleep -Milliseconds 250
        }

        if (-not $backendReady) {
            throw 'The speech backend did not become ready on port 5000.'
        }
    } else {
        Write-Host 'TinigSenyas backend is already running on port 5000.' -ForegroundColor Green
    }

    Push-Location $frontendPath
    try {
        Write-Host 'Launching TinigSenyas web app on http://localhost:5001...' -ForegroundColor Cyan
        flutter run -d chrome --web-port=5001
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter exited with code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($startedBackend -and $null -ne $backendProcess) {
        if (-not $backendProcess.HasExited) {
            Stop-Process -Id $backendProcess.Id
        }
    }
    Remove-Item -LiteralPath $backendLog, $backendErrorLog `
        -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dependencyCheckLog, $dependencyCheckErrorLog, `
        $dependencyInstallLog, $dependencyInstallErrorLog `
        -Force -ErrorAction SilentlyContinue
    Pop-Location
}
