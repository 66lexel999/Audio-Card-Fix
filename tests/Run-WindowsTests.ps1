<#
    Tests Focusrite-Doctor.ps1 on a REAL Windows PC (used by .github/workflows/windows-test.yml).
    NOT for the person with the Focusrite - this is for whoever maintains the tool.

    What it does:
      1. Checks the shipped files: pure ASCII, CRLF line endings, parse with Windows PowerShell 5.1.
      2. Builds a FAKE "Focusrite USB ASIO" driver from tests\MockAsio.cpp (needs Visual Studio C++ tools).
      3. Runs the doctor with -ReportOnly in several situations (no driver, driver works, driver fails
         with 0x54f, driver hangs, driver crashes, ...) and checks what it says.
    It registers the fake driver in the registry while it runs and removes it at the end, so run it
    on a test machine or CI runner, as Administrator.
#>
param(
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'

$Repo     = Split-Path -Parent $PSScriptRoot
$Doctor   = Join-Path $Repo 'Focusrite-Doctor.ps1'
$Shipped  = @('Focusrite-Doctor.ps1', 'Run-Focusrite-Doctor.bat', 'READ ME FIRST.txt')
$Clsid    = '{AEEBC837-F17A-4CDA-A5BA-B837D12DB50B}'
$AsioName = 'Focusrite USB ASIO'
$Ps64     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Ps32     = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'focusrite-doctor-test' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Failures = New-Object 'System.Collections.Generic.List[string]'
$Scenario = 'setup'

function Check {
    param([bool]$Ok, [string]$What)
    if ($Ok) { Write-Host ('    PASS  ' + $What) -ForegroundColor Green }
    else {
        Write-Host ('    FAIL  ' + $What) -ForegroundColor Red
        $Failures.Add($Scenario + ': ' + $What)
    }
}

function Title {
    param([string]$Text)
    Write-Host ''
    Write-Host ('##### ' + $Text) -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
Title 'Environment'
Write-Host ('  Windows: ' + (Get-CimInstance Win32_OperatingSystem).Caption + ' build ' + [Environment]::OSVersion.Version)
Write-Host ('  PowerShell: ' + $PSVersionTable.PSVersion + ' (' + $PSVersionTable.PSEdition + '), CLR ' + $PSVersionTable.CLRVersion)
$Scenario = 'environment'
Check ($PSVersionTable.PSVersion.Major -eq 5) 'running in Windows PowerShell 5.x'
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Check $isAdmin 'running as Administrator (needed to register the fake driver)'
$existingFocusrite = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_1235' })
Check ($existingFocusrite.Count -eq 0) 'no real Focusrite connected (the expected output assumes none)'

# -----------------------------------------------------------------------------
Title 'Shipped files: ASCII, CRLF, PowerShell 5.1 syntax'
$Scenario = 'files'
$eol = @(& git -C $Repo ls-files --eol 2>$null)
foreach ($f in $Shipped) {
    $path = Join-Path $Repo $f
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    $bareLf = 0
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -eq 10 -and ($i -eq 0 -or $bytes[$i - 1] -ne 13)) { $bareLf++ }
    }
    Check ($nonAscii -eq 0) ($f + ': pure ASCII (' + $nonAscii + ' non-ASCII bytes)')
    Check ($bareLf -eq 0) ($f + ': CRLF line endings on disk (' + $bareLf + ' bare LF)')
    $line = @($eol | Where-Object { $_ -match ('\t' + [regex]::Escape($f) + '$') }) | Select-Object -First 1
    if ($line) { Check ($line -match '^i/crlf') ($f + ': stored with CRLF in git (' + ($line -split '\s+')[0] + ')') }
}
foreach ($f in @($Doctor, $PSCommandPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
    foreach ($e in @($errors)) { Write-Host ('      ' + $e.Extent.StartLineNumber + ': ' + $e.Message) -ForegroundColor Red }
    Check (@($errors).Count -eq 0) ((Split-Path -Leaf $f) + ': no syntax errors in PowerShell ' + $PSVersionTable.PSVersion)
}

# -----------------------------------------------------------------------------
Title 'Build the fake Focusrite USB ASIO driver'
$Scenario = 'build'
$MockDll = Join-Path $OutDir 'MockAsio.dll'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = ''
if (Test-Path $vswhere) { $vs = [string](& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
if (-not $vs -or -not (Test-Path $vcvars)) { throw 'Visual Studio C++ build tools not found.' }
$bat = Join-Path $OutDir 'build.bat'
$batText = "@echo off`r`ncall `"$vcvars`" >nul || exit /b 1`r`ncd /d `"$OutDir`"`r`n" +
    "cl /nologo /LD /O2 /W3 /EHsc `"$(Join-Path $PSScriptRoot 'MockAsio.cpp')`" /Fe:MockAsio.dll ole32.lib`r`n"
[System.IO.File]::WriteAllText($bat, $batText, [System.Text.Encoding]::ASCII)
& cmd.exe /c "`"$bat`""
Check (($LASTEXITCODE -eq 0) -and (Test-Path $MockDll)) 'MockAsio.dll built'
if (-not (Test-Path $MockDll)) { throw 'Build failed.' }

# -----------------------------------------------------------------------------
$hadAsioKey = Test-Path 'HKLM:\SOFTWARE\ASIO'

function Register-Mock {
    param([string]$DllPath, [string]$Threading = 'Apartment')
    $ck = 'HKLM:\SOFTWARE\Classes\CLSID\' + $Clsid
    New-Item -Path ($ck + '\InprocServer32') -Force | Out-Null
    Set-ItemProperty -Path $ck -Name '(default)' -Value 'Focusrite Doctor TEST driver'
    Set-ItemProperty -Path ($ck + '\InprocServer32') -Name '(default)' -Value $DllPath
    Set-ItemProperty -Path ($ck + '\InprocServer32') -Name 'ThreadingModel' -Value $Threading
    New-Item -Path ('HKLM:\SOFTWARE\ASIO\' + $AsioName) -Force | Out-Null
    Set-ItemProperty -Path ('HKLM:\SOFTWARE\ASIO\' + $AsioName) -Name 'CLSID' -Value $Clsid
    Set-ItemProperty -Path ('HKLM:\SOFTWARE\ASIO\' + $AsioName) -Name 'Description' -Value $AsioName
}

function Unregister-Mock {
    Remove-Item -Path ('HKLM:\SOFTWARE\Classes\CLSID\' + $Clsid) -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path ('HKLM:\SOFTWARE\ASIO\' + $AsioName) -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $hadAsioKey) { Remove-Item -Path 'HKLM:\SOFTWARE\ASIO' -Recurse -Force -ErrorAction SilentlyContinue }
}

# Runs the doctor like a user would. Default: -ReportOnly with the keyboard closed (stdin), so any
# question gets no answer. With -Answers: normal mode, and those lines are "typed" one per question.
function Invoke-Doctor {
    param([string]$Mode = 'ok', [string]$Exe = $Ps64, [int]$TimeoutSec = 300, [string[]]$Answers = $null)
    $logPath = Join-Path $OutDir ($Scenario + '-driver-log.txt')
    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    $env:MOCKASIO_MODE = $Mode
    $env:MOCKASIO_LOG = $logPath
    $env:FOCUSRITE_DOCTOR_BAT = '1'          # no "Press Enter to close" at the end
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Doctor + '" -NoElevate'
    if ($null -eq $Answers) { $psi.Arguments += ' -ReportOnly' }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    foreach ($a in @($Answers)) { if ($null -ne $a) { $p.StandardInput.WriteLine($a) } }
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) { try { $p.Kill() } catch { } ; [void]$p.WaitForExit(5000) }
    [void]$outTask.Wait(10000)
    [void]$errTask.Wait(10000)
    $watch.Stop()
    $out = [string]$outTask.Result
    $err = [string]$errTask.Result
    $report = ''
    $reportPath = ''
    if ($out -match 'Saved to: (.+?\.txt)') {
        $reportPath = $Matches[1].Trim()
        if (Test-Path -LiteralPath $reportPath) {
            $report = [System.IO.File]::ReadAllText($reportPath)
            Copy-Item -LiteralPath $reportPath -Destination (Join-Path $OutDir ($Scenario + '-report.txt')) -Force
            Remove-Item -LiteralPath $reportPath -Force
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $OutDir ($Scenario + '-console.txt')), $out + "`r`n----- stderr -----`r`n" + $err)
    $driverLog = ''
    if (Test-Path -LiteralPath $logPath) { $driverLog = [System.IO.File]::ReadAllText($logPath) }
    $code = -1
    if ($finished) { $code = $p.ExitCode }
    Write-Host ('    (took {0:N0} s, exit code {1})' -f $watch.Elapsed.TotalSeconds, $code)

    # Checks that apply to every run
    Check $finished 'the doctor finished on its own (did not wait for input or hang)'
    Check ($code -eq 0) 'exit code 0'
    Check ($out -notmatch 'Unexpected error') 'no "Unexpected error"'
    Check ($err.Trim() -eq '') 'nothing written to stderr (no PowerShell error records)'
    Check ($out -match '=== Summary') 'printed the Summary'
    # Read-Host does not echo its prompt when the keyboard is redirected, so look in the report too
    # (the doctor logs every question it asks there).
    if ($null -eq $Answers) { Check (($out -notmatch '>> ') -and ($report -notmatch '(?m)^\s*>> ')) 'asked no questions in -ReportOnly mode' }
    Check (-not (Test-Path (Join-Path $env:TEMP 'FocusriteDoctor-AsioTest.ps1'))) 'left no live-test helper file in TEMP'
    Check ($report -match 'FOCUSRITE DOCTOR' -and $report -match '=== Summary') 'saved the report file'
    Check ($out -notmatch 'could not run on this PC') 'the live test was able to run (no TEST_UNAVAILABLE)'
    if ($err.Trim()) { Write-Host $err -ForegroundColor Red }

    [pscustomobject]@{ Out = $out; Err = $err; Report = $report; DriverLog = $driverLog; Code = $code }
}

function Show-Output {
    param($R)
    Write-Host '    ---------------- doctor output ----------------' -ForegroundColor DarkGray
    foreach ($l in ($R.Out -split "`r?`n")) { Write-Host ('    | ' + $l) }
    if ($R.DriverLog) {
        Write-Host '    ---------------- fake driver log ----------------' -ForegroundColor DarkGray
        foreach ($l in ($R.DriverLog -split "`r?`n")) { if ($l) { Write-Host ('    | ' + $l) } }
    }
}

try {
    Unregister-Mock

    # -------------------------------------------------------------------------
    $Scenario = 'no-focusrite'
    Title 'Scenario: no Focusrite plugged in, no Focusrite driver installed'
    $r = Invoke-Doctor
    Show-Output $r
    Check ($r.Out -match 'Windows cannot see a Focusrite on USB right now') 'says the Focusrite is not connected'
    Check ($r.Out -match 'no 64-bit Focusrite ASIO driver registered') 'says there is no Focusrite ASIO driver'
    Check ($r.Out -match 'Skipped - there is no Focusrite ASIO driver to test') 'skips the live test'
    Check ($r.Out -match 'Report-only mode: no fixes offered') 'offers no fixes'

    # -------------------------------------------------------------------------
    $Scenario = 'driver-works'
    Title 'Scenario: fake driver opens and streams audio'
    Register-Mock -DllPath $MockDll
    $r = Invoke-Doctor -Mode 'ok'
    Show-Output $r
    Check ($r.Out -match '"Focusrite USB ASIO" -> ') 'finds the Focusrite USB ASIO driver in the registry'
    Check ($r.Out -match '"Focusrite USB ASIO" opened: 2 inputs / 2 outputs, 48000 Hz, buffer 256 samples') 'live test opened it and read channels, rate and buffer size'
    Check ($r.Out -match 'Audio runs: [1-9]\d* audio blocks') 'audio blocks arrived'
    Check ($r.Out -match 'LIVE TEST PASSED') 'LIVE TEST PASSED'
    Check ($r.Report -match 'test\.RATES_OK = 44100,48000,88200,96000') 'sample-rate question got the right answers (doubles passed correctly)'
    Check ($r.Report -match 'test\.SAMPLE_TYPE = 18') 'channel info read at the right offset'
    Check ($r.Report -match 'test\.ARCH = 64-bit') 'test ran 64-bit'
    Check ($r.Report -match 'test\.APARTMENT = STA') 'Apartment-threaded driver opened in STA'
    Check ($r.DriverLog -match 'createBuffers channels=4 size=256') 'driver got 2 in + 2 out buffers of the preferred size'
    Check ($r.DriverLog -match 'asioMessage selectorSupported\(engineVersion\)=1 engineVersion=2') 'asioMessage callback works'
    Check ($r.DriverLog -match 'blocks-with-silence-written=[1-9]\d* blocks-not-written=0') 'the test wrote silence into every output buffer'
    Check ($r.DriverLog -match 'disposeBuffers' -and $r.DriverLog -match 'release \(last reference\)') 'driver closed cleanly (stop, disposeBuffers, Release)'

    # -------------------------------------------------------------------------
    $Scenario = 'driver-0x54f'
    Title 'Scenario: driver init fails with 0x54f (the friend''s error)'
    $r = Invoke-Doctor -Mode 'fail54f'
    Show-Output $r
    Check ($r.Out -match 'could NOT open: Cannot open the device\. \(Error code: 0x54f\)') 'shows the driver''s own error text'
    Check ($r.Out -match 'Same error TONEX shows') 'links it to the TONEX error'
    Check ($r.Out -match 'LIVE TEST FAILED') 'LIVE TEST FAILED'
    Check ($r.DriverLog -match 'release \(last reference\)') 'driver released after the failed init'

    # -------------------------------------------------------------------------
    $Scenario = 'driver-noaudio'
    Title 'Scenario: driver opens but no audio blocks arrive'
    $r = Invoke-Doctor -Mode 'noaudio'
    Check ($r.Out -match 'no audio came through') 'says no audio came through'
    Check ($r.Out -match 'LIVE TEST FAILED') 'LIVE TEST FAILED'

    # -------------------------------------------------------------------------
    $Scenario = 'driver-crash'
    Title 'Scenario: driver crashes while opening'
    $r = Invoke-Doctor -Mode 'crash'
    Show-Output $r
    Check ($r.Out -match 'The driver crashed during the test') 'reports the crash (and survives it)'
    Check ($r.Out -match 'LIVE TEST FAILED') 'LIVE TEST FAILED'

    # -------------------------------------------------------------------------
    $Scenario = 'driver-hang'
    Title 'Scenario: driver freezes while opening'
    $r = Invoke-Doctor -Mode 'hang'
    Check ($r.Out -match 'The driver froze while opening') 'reports the freeze'
    Check ($r.Out -match 'LIVE TEST FAILED') 'LIVE TEST FAILED'

    # -------------------------------------------------------------------------
    $Scenario = 'free-threaded'
    Title 'Scenario: driver registered as free-threaded (needs the MTA retry)'
    Unregister-Mock
    Register-Mock -DllPath $MockDll -Threading 'Free'
    $r = Invoke-Doctor -Mode 'ok'
    Show-Output $r
    Check ($r.Out -match 'LIVE TEST PASSED') 'LIVE TEST PASSED'
    Check ($r.Report -match 'test\.APARTMENT = MTA') 'opened from the MTA after the STA attempt'

    # -------------------------------------------------------------------------
    $Scenario = 'held-by-other-app'
    Title 'Scenario: another program has the ASIO driver loaded'
    Unregister-Mock
    Register-Mock -DllPath $MockDll
    $holder = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\rundll32.exe') -ArgumentList ('"' + $MockDll + '",HoldOpen') -PassThru
    Start-Sleep -Seconds 2
    try {
        $r = Invoke-Doctor -Mode 'ok'
        Check ($r.Out -match ('rundll32 \(process ' + $holder.Id + '\) - has the Focusrite ASIO driver open')) 'finds the program holding the driver'
    } finally {
        try { Stop-Process -Id $holder.Id -Force -ErrorAction Stop } catch { }
    }

    # -------------------------------------------------------------------------
    $Scenario = 'driver-file-missing'
    Title 'Scenario: ASIO entry points to a driver file that is missing'
    Unregister-Mock
    Register-Mock -DllPath (Join-Path $OutDir 'NotThere\FocusriteUSBASIO.dll')
    $r = Invoke-Doctor -Mode 'ok'
    Show-Output $r
    Check ($r.Out -match 'BROKEN: driver file missing') 'marks the ASIO entry as broken'
    Check ($r.Out -match 'points to a file that is missing') 'explains the file is missing'
    Check ($r.Out -match 'Windows could not load the "Focusrite USB ASIO" driver file \(0x8007007E') 'live test: driver file could not be loaded'

    # -------------------------------------------------------------------------
    $Scenario = 'questions-enter-is-not-yes'
    Title 'Scenario: normal mode, pressing Enter on a question that changes the PC'
    Unregister-Mock
    $ssBefore = (@(& powercfg.exe /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226) -join "`n")
    # 1st question: walk through plugging in? -> n.  2nd: turn off USB selective suspend? -> Enter, then n.
    $r = Invoke-Doctor -Answers @('n', '', 'n') -TimeoutSec 240
    Show-Output $r
    $ssAfter = (@(& powercfg.exe /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226) -join "`n")
    Check ($r.Report -match 'Turn off USB selective suspend\? \(stops Windows powering down USB audio\) \[y/n\]') 'PC-changing question shows [y/n] (no default)'
    Check ($r.Out -match 'This changes something on your PC, so please type Y') 'Enter alone is not taken as yes'
    Check ($r.Out -notmatch 'USB selective suspend is now off') 'nothing was changed'
    Check ($ssBefore -eq $ssAfter) 'power setting really unchanged'
    Check ($r.Out -match 'Still not working\? Do these, in order') 'printed the next steps'

    # -------------------------------------------------------------------------
    $Scenario = 'questions-typed-yes'
    Title 'Scenario: normal mode, typing Y to turn off USB selective suspend'
    $r = Invoke-Doctor -Answers @('n', 'y') -TimeoutSec 240
    $ss = (@(& powercfg.exe /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226) -join "`n")
    Write-Host ('    powercfg now: ' + (($ss -split "`n" | Where-Object { $_ -match '0x' }) -join ' | '))
    Check ($r.Out -match 'USB selective suspend is now off') 'says the setting was changed'
    $m = [regex]::Matches($ss, '0x([0-9a-fA-F]{8})')
    Check ($m.Count -ge 2 -and [Convert]::ToInt32($m[$m.Count - 2].Groups[1].Value, 16) -eq 0 -and [Convert]::ToInt32($m[$m.Count - 1].Groups[1].Value, 16) -eq 0) 'power setting really is off now (AC and DC)'

    # -------------------------------------------------------------------------
    $Scenario = 'started-32-bit'
    Title 'Scenario: started from 32-bit PowerShell (must switch to 64-bit)'
    Unregister-Mock
    Register-Mock -DllPath $MockDll
    $r = Invoke-Doctor -Mode 'ok' -Exe $Ps32
    Check ($r.Out -match 'LIVE TEST PASSED') 'LIVE TEST PASSED'
    Check ($r.Report -match 'test\.ARCH = 64-bit') 'live test ran 64-bit'
} finally {
    Unregister-Mock
    Remove-Item Env:\MOCKASIO_MODE, Env:\MOCKASIO_LOG, Env:\FOCUSRITE_DOCTOR_BAT -ErrorAction SilentlyContinue
}

Title 'Result'
if ($Failures.Count -eq 0) {
    Write-Host '  ALL CHECKS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ('  ' + $Failures.Count + ' CHECK(S) FAILED:') -ForegroundColor Red
foreach ($f in $Failures) { Write-Host ('   - ' + $f) -ForegroundColor Red }
exit 1
