<#
.SYNOPSIS
    RainCheck end-to-end verification:
    Protocol Sync -> Core Unit Tests -> CLI Dist -> E2E Demo -> Unsigned APK -> iOS Integrity -> Workspace Hygiene.

.DESCRIPTION
    All checks run completely offline against a local mock server; no real Yuketang endpoints are contacted.
    Exits non-zero if any verification step fails.

.EXAMPLE
    powershell -NoProfile -File tools\verify.ps1
    powershell -NoProfile -File tools\verify.ps1 -SkipAndroid
    powershell -NoProfile -File tools\verify.ps1 -UpdateDist
#>
param(
    [switch]$SkipAndroid,
    [switch]$SkipDemo,
    [switch]$UpdateDist,
    [int]$Port = 8787
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$env:PYTHONIOENCODING = 'utf-8'

# Respect user's JAVA_HOME or PATH java; only fall back to local JDK21 when neither is available.
function Resolve-JavaHome {
    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        Write-Host "Using existing JAVA_HOME: $env:JAVA_HOME" -ForegroundColor DarkGray
        return
    }
    $javaCmd = Get-Command java -ErrorAction SilentlyContinue
    if ($javaCmd) {
        Write-Host "Using java from PATH: $($javaCmd.Source)" -ForegroundColor DarkGray
        return
    }
    $fallbackJdk = 'C:\Users\Administrator\Tools\jdk21\jdk-21.0.12+8'
    if (Test-Path (Join-Path $fallbackJdk 'bin\java.exe')) {
        $env:JAVA_HOME = $fallbackJdk
        Write-Host "JAVA_HOME not set; falling back to: $fallbackJdk" -ForegroundColor DarkGray
        return
    }
    throw "No JDK found. Set JAVA_HOME or install JDK 17/21 in PATH."
}

function Resolve-Python {
    foreach ($candidate in @('python', 'python3')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    throw "Python 3 not found in PATH."
}

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
$failures = @()
$steps = @()

function Step([string]$name, [scriptblock]$body) {
    Write-Host "`n=== $name ===" -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $body
        $sw.Stop()
        $script:steps += [pscustomobject]@{
            Step    = $name
            Result  = 'PASS'
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
        Write-Host "PASS ($([math]::Round($sw.Elapsed.TotalSeconds, 1))s)" -ForegroundColor Green
    } catch {
        $sw.Stop()
        $script:steps += [pscustomobject]@{
            Step    = $name
            Result  = 'FAIL'
            Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        }
        $script:failures += "$name -> $($_.Exception.Message)"
        Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    }
}

try {
    Resolve-JavaHome
    $py = Resolve-Python

    Step 'Protocol profile sync (source)' {
        & $py tools\check_artifacts.py profile-sync --root .
        if ($LASTEXITCODE -ne 0) { throw "profile-sync failed (exit=$LASTEXITCODE)" }
    }

    Step 'Core JVM unit tests (--rerun + JUnit XML >= 20)' {
        & .\gradlew.bat :core:jvmTest --rerun --console=plain
        if ($LASTEXITCODE -ne 0) { throw "gradlew :core:jvmTest failed (exit=$LASTEXITCODE)" }
        & $py tools\check_artifacts.py junit-xml --dir core\build\test-results\jvmTest --min-tests 20
        if ($LASTEXITCODE -ne 0) { throw "Core JUnit XML assertion failed (exit=$LASTEXITCODE)" }
    }

    Step 'CLI unit tests (--rerun + JUnit XML >= 4)' {
        & .\gradlew.bat :cli:test --rerun --console=plain
        if ($LASTEXITCODE -ne 0) { throw "gradlew :cli:test failed (exit=$LASTEXITCODE)" }
        & $py tools\check_artifacts.py junit-xml --dir cli\build\test-results\test --min-tests 4
        if ($LASTEXITCODE -ne 0) { throw "CLI JUnit XML assertion failed (exit=$LASTEXITCODE)" }
    }

    Step 'CLI installDist + embedded profile.json SHA-256' {
        & .\gradlew.bat :cli:installDist --console=plain
        if ($LASTEXITCODE -ne 0) { throw "gradlew :cli:installDist failed (exit=$LASTEXITCODE)" }
        & $py tools\check_artifacts.py profile-sync --root . --check-cli-jar
        if ($LASTEXITCODE -ne 0) { throw "CLI jar profile.json verification failed (exit=$LASTEXITCODE)" }
    }

    if (-not $SkipDemo) {
        Step 'End-to-end demo (8 accounts + fallback + login + dry-run)' {
            & $py tools\demo.py --port $Port
            if ($LASTEXITCODE -ne 0) { throw "tools/demo.py failed (exit=$LASTEXITCODE)" }
        }
    }

    if (-not $SkipAndroid) {
        Step 'Android unsigned release APK (V1 + V2/V3 + embedded profile)' {
            & .\gradlew.bat :androidApp:assembleRelease --console=plain
            if ($LASTEXITCODE -ne 0) { throw "gradlew :androidApp:assembleRelease failed (exit=$LASTEXITCODE)" }

            $apkPath = 'androidApp\build\outputs\apk\release\androidApp-release-unsigned.apk'
            if (-not (Test-Path $apkPath)) {
                throw "Expected unsigned APK not found: $apkPath"
            }

            & $py tools\check_artifacts.py apk-unsigned $apkPath
            if ($LASTEXITCODE -ne 0) { throw "Unsigned APK check failed (exit=$LASTEXITCODE)" }

            & $py tools\check_artifacts.py profile-sync --root . --apk $apkPath
            if ($LASTEXITCODE -ne 0) { throw "APK embedded profile check failed (exit=$LASTEXITCODE)" }

            $distApk = 'dist\RainCheck-1.0.0-unsigned.apk'
            if ($UpdateDist) {
                New-Item -ItemType Directory -Force -Path dist | Out-Null
                Copy-Item $apkPath $distApk -Force
                Write-Host "Updated $distApk" -ForegroundColor DarkGray
            } elseif (Test-Path $distApk) {
                & $py tools\check_artifacts.py apk-unsigned $distApk
                if ($LASTEXITCODE -ne 0) { throw "dist APK unsigned check failed (exit=$LASTEXITCODE)" }
                & $py tools\check_artifacts.py profile-sync --root . --apk $distApk
                if ($LASTEXITCODE -ne 0) { throw "dist APK embedded profile check failed (exit=$LASTEXITCODE)" }
            }
        }
    }

    Step 'iOS project integrity (YAML / Tests / Liquid Glass / Redaction)' {
        & $py tools\check_artifacts.py ios-project --ios-dir iosApp
        if ($LASTEXITCODE -ne 0) { throw "iOS project integrity check failed (exit=$LASTEXITCODE)" }
    }

    Step 'Workspace hygiene (no stale log files in tools/)' {
        foreach ($stale in @('tools\demo.out.txt', 'tools\mock-server.log')) {
            if (Test-Path $stale) {
                throw "Stale log file found in workspace: $stale"
            }
        }
        Write-Host 'No stale logs in tools/.'
    }
}
finally {
    Pop-Location
}

Write-Host "`n==== Summary ====" -ForegroundColor Cyan
$steps | Format-Table -AutoSize
if ($failures.Count -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
exit 0
