<#
.SYNOPSIS
    Remove the dsh-shell bridge, its tasks and its AGENTS.md block.
.PARAMETER DshHome
    DSH home directory. Defaults to $env:DSH_HOME, else ~/.dsh.
.PARAMETER KeepTasks
    Keep <DSH_HOME>/tasks.
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$KeepTasks
)

$ErrorActionPreference = 'Stop'
if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
    elseif ($env:USERPROFILE) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
    else { $DshHome = Join-Path $HOME '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
$toolsDir = Join-Path $DshHome 'tools'
$tasksDir = Join-Path $DshHome 'tasks'

$agents = Join-Path $DshHome 'AGENTS.md'
if (Test-Path -LiteralPath $agents) {
    $pattern = '(?s)\r?\n?<!-- DSH-SHELL-BRIDGE:BEGIN -->.*?<!-- DSH-SHELL-BRIDGE:END -->\r?\n?'
    $next = [regex]::Replace([IO.File]::ReadAllText($agents), $pattern, '')
    if ($next.Trim().Length -eq 0) { Remove-Item -LiteralPath $agents -Force }
    else { [IO.File]::WriteAllText($agents, $next, [Text.UTF8Encoding]::new($false)) }
    Write-Host 'AGENTS.md block removed.'
}

foreach ($p in @((Join-Path $toolsDir 'dsh-shell.ps1'), (Join-Path $toolsDir 'revert-dsh-shell.ps1'))) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host ('removed ' + $p) }
}
if (-not $KeepTasks -and (Test-Path -LiteralPath $tasksDir)) {
    Remove-Item -LiteralPath $tasksDir -Recurse -Force
    Write-Host ('removed ' + $tasksDir)
}
Write-Host 'Done.'
