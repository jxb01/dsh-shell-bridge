<#
.SYNOPSIS
    Install the dsh-shell bridge into a DSH home.
.DESCRIPTION
    Copies dsh-shell.ps1 and the revert helper into <DSH_HOME>/tools, creates
    <DSH_HOME>/tasks with a sample main.ps1, and adds or replaces the
    DSH-SHELL-BRIDGE block in <DSH_HOME>/AGENTS.md so every DSH session routes
    shell work through the bridge.
.PARAMETER DshHome
    DSH home directory. Defaults to $env:DSH_HOME, else ~/.dsh.
.PARAMETER SkipInstructions
    Do not touch AGENTS.md.
.PARAMETER Force
    Overwrite an existing tools/dsh-shell.ps1 and tasks/main.ps1.
.EXAMPLE
    ./install.ps1
.EXAMPLE
    ./install.ps1 -DshHome D:/dsh-home -Force
#>
[CmdletBinding()]
param(
    [string]$DshHome,
    [switch]$SkipInstructions,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $DshHome) {
    if ($env:DSH_HOME) { $DshHome = $env:DSH_HOME }
    elseif ($env:USERPROFILE) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
    else { $DshHome = Join-Path $HOME '.dsh' }
}
$DshHome = [IO.Path]::GetFullPath($DshHome)
$toolsDir = Join-Path $DshHome 'tools'
$tasksDir = Join-Path $DshHome 'tasks'
$null = New-Item -ItemType Directory -Path $toolsDir -Force
$null = New-Item -ItemType Directory -Path $tasksDir -Force

$bridgeTarget = Join-Path $toolsDir 'dsh-shell.ps1'
Copy-Item -LiteralPath (Join-Path $scriptDir 'dsh-shell.ps1') -Destination $bridgeTarget -Force
Copy-Item -LiteralPath (Join-Path $scriptDir 'revert.ps1') -Destination (Join-Path $toolsDir 'revert-dsh-shell.ps1') -Force
Write-Host ('bridge  -> ' + $bridgeTarget)

$sample = Join-Path $scriptDir 'samples\main.ps1'
$mainTask = Join-Path $tasksDir 'main.ps1'
if ((Test-Path -LiteralPath $sample) -and ($Force -or -not (Test-Path -LiteralPath $mainTask))) {
    Copy-Item -LiteralPath $sample -Destination $mainTask -Force
    Write-Host ('sample  -> ' + $mainTask)
}

if (-not $SkipInstructions) {
    $template = [IO.File]::ReadAllText((Join-Path $scriptDir 'docs\instructions-block.md'))
    $block = $template.Replace('@@BRIDGE@@', $bridgeTarget).Replace('@@TASKS@@', $tasksDir)
    $agents = Join-Path $DshHome 'AGENTS.md'
    $pattern = '(?s)\r?\n?<!-- DSH-SHELL-BRIDGE:BEGIN -->.*?<!-- DSH-SHELL-BRIDGE:END -->\r?\n?'
    $text = if (Test-Path -LiteralPath $agents) { [IO.File]::ReadAllText($agents) } else { '' }
    $text = [regex]::Replace($text, $pattern, '').TrimEnd()
    $nl = [Environment]::NewLine
    if ($text.Length -gt 0) { $text += $nl + $nl }
    [IO.File]::WriteAllText($agents, $text + $block + $nl, [Text.UTF8Encoding]::new($false))
    Write-Host ('rules   -> ' + $agents)
}

Write-Host ''
Write-Host 'Installed. Start a new DSH session (or reload a profile) before using the bridge.'
