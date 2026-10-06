<#
.SYNOPSIS
    DSH shell bridge: run a PowerShell or cmd payload without transcoding or
    quoting failures on a legacy-code-page Windows console.
.DESCRIPTION
    Why this exists
    ---------------
    The stock pwsh tool runs every command as "pwsh ... -Command <text>". On a
    zh-CN Windows box the console code page is 936 and the spawned pwsh has no
    console, so:
      * native tools (ipconfig, python, systeminfo, netstat, many CLIs) emit
        cp936 bytes that the harness decodes as UTF-8  -> mojibake;
      * text piped into a native tool is encoded UTF-8 that it reads as cp936;
      * the injected "[Console]::OutputEncoding = ...; " preamble makes param()
        and using/#requires illegal (they must be the first statement);
      * the whole script travels as ONE argv, so anything past the Windows
        ~32k command-line ceiling dies with "spawn ENAMETOOLONG";
      * every backslash and double quote must survive JSON + PowerShell
        parsing before the command even starts.

    What this does
    --------------
    Runs the payload from a script file in a child shell that owns a hidden
    console pinned to code page 65001. PowerShell, cmd.exe and every native
    child then agree on UTF-8, so output and input both round-trip. The script
    file removes the outer quoting/escaping layer, keeps param()/using first,
    and has no practical size limit. stdout/stderr bytes are pumped straight
    through, so output streams live and background jobs keep working; the
    child's exit code is propagated unchanged.

.PARAMETER Name
    Task name. Loads <DSH_HOME>/tasks/<Name>.ps1 for pwsh (or .cmd for cmd).
    Defaults to "main" when no other payload parameter is given.
.PARAMETER ScriptFile
    Explicit payload path (used instead of -Name).
.PARAMETER Command
    Inline payload, materialised to a temp script (used instead of -Name).
.PARAMETER Shell
    pwsh (default) or cmd.
.PARAMETER WorkDir
    Working directory for the child; defaults to the caller's location.
.PARAMETER TimeoutSec
    Optional wall-clock limit; on expiry the child tree is killed and exit 124
    is returned.
.PARAMETER KeepTemporary
    Keep the generated temp runner/payload for inspection.

.EXAMPLE
    & dsh-shell.ps1                      # runs <DSH_HOME>/tasks/main.ps1
.EXAMPLE
    & dsh-shell.ps1 -Name build
.EXAMPLE
    & dsh-shell.ps1 -Shell cmd -Name deploy
.EXAMPLE
    & dsh-shell.ps1 -ScriptFile D:/work/task.ps1 -WorkDir D:/work
.EXAMPLE
    & dsh-shell.ps1 -Command 'Get-Date; python -c "print(1)"'
#>
[CmdletBinding()]
param(
    [string]$Name,
    [string]$ScriptFile,
    [string]$Command,
    [ValidateSet('pwsh', 'cmd')]
    [string]$Shell = 'pwsh',
    [string]$WorkDir,
    [ValidateRange(0, 2147483)]
    [int]$TimeoutSec = 0,
    [switch]$KeepTemporary
)

$ErrorActionPreference = 'Stop'

function Get-DshHome {
    if ($env:DSH_HOME) { return $env:DSH_HOME }
    if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE '.dsh') }
    return (Join-Path $HOME '.dsh')
}

# Resolve the child shell executable.
if ($Shell -eq 'cmd') {
    $shellExe = if ($env:ComSpec) { $env:ComSpec } else { Join-Path $env:SystemRoot 'System32\cmd.exe' }
} else {
    $shellExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if (-not $shellExe) { $shellExe = 'pwsh' }
}

# Resolve the working directory (defaults to the caller's location).
if ($WorkDir) {
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) {
        throw "dsh-shell: WorkDir is not a directory: $WorkDir"
    }
    $WorkDir = (Resolve-Path -LiteralPath $WorkDir).ProviderPath
} else {
    $WorkDir = (Get-Location).ProviderPath
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dsh-shell-' + [guid]::NewGuid().ToString('n'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force
$utf8Bom = [Text.UTF8Encoding]::new($true)
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$nl = [string][char]13 + [string][char]10

try {
    $payload = $null

    if ($ScriptFile) {
        if (-not (Test-Path -LiteralPath $ScriptFile -PathType Leaf)) {
            throw "dsh-shell: script file not found: $ScriptFile"
        }
        $payload = (Resolve-Path -LiteralPath $ScriptFile).ProviderPath
    } elseif ($Command) {
        if ($Shell -eq 'cmd') {
            $payload = Join-Path $tempRoot 'payload.cmd'
            [IO.File]::WriteAllText($payload, $Command, $utf8NoBom)
        } else {
            $payload = Join-Path $tempRoot 'payload.ps1'
            [IO.File]::WriteAllText($payload, $Command, $utf8Bom)
        }
    } else {
        if (-not $Name) { $Name = 'main' }
        if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "dsh-shell: task name may contain only letters, digits, dot, underscore and dash: $Name"
        }
        $extension = if ($Shell -eq 'cmd') { '.cmd' } else { '.ps1' }
        $candidate = Join-Path (Join-Path (Get-DshHome) 'tasks') ($Name + $extension)
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "dsh-shell: task not found: $candidate"
        }
        $payload = (Resolve-Path -LiteralPath $candidate).ProviderPath
    }

    # Runner: pin the hidden console to 65001, then run the payload. The payload
    # path travels through the environment so the runner file itself stays ASCII.
    if ($Shell -eq 'cmd') {
        $runner = Join-Path $tempRoot 'runner.cmd'
        $runnerText = '@echo off' + $nl + 'chcp 65001 >nul' + $nl + 'call "%DSH_BRIDGE_PAYLOAD%"' + $nl + 'exit /b %errorlevel%' + $nl
        [IO.File]::WriteAllText($runner, $runnerText, [Text.ASCIIEncoding]::new())
        $argv = @('/d', '/s', '/c', $runner)
    } else {
        $runner = Join-Path $tempRoot 'runner.ps1'
        $runnerText = @'
chcp.com 65001 > $null 2>&1
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
& $env:DSH_BRIDGE_PAYLOAD
if ($null -ne $LASTEXITCODE) { exit [int]$LASTEXITCODE }
if ($?) { exit 0 } else { exit 1 }
'@
        [IO.File]::WriteAllText($runner, $runnerText, $utf8Bom)
        $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner)
    }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $shellExe
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkDir
    $psi.Environment['DSH_BRIDGE_PAYLOAD'] = $payload
    # The harness hands us its stdout/stderr through pipes it created without
    # inheritance, so redirect the child and pump its raw bytes to our streams:
    # raw bytes preserve UTF-8 exactly and stream live.
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($item in $argv) { $null = $psi.ArgumentList.Add([string]$item) }

    $exitCode = 0
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
    $errTask = $proc.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
    $timedOut = $false
    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            $timedOut = $true
            try { $proc.Kill($true) } catch { }
        }
    } else {
        $proc.WaitForExit()
    }
    $null = $outTask.GetAwaiter().GetResult()
    $null = $errTask.GetAwaiter().GetResult()
    if ($timedOut) {
        [Console]::Error.WriteLine('[dsh-shell] timed out after ' + $TimeoutSec + 's')
        $exitCode = 124
    } else {
        $exitCode = $proc.ExitCode
    }
} finally {
    if (-not $KeepTemporary -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit $exitCode
