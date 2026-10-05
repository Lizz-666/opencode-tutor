$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'explain.lib.ps1')
$cfg = Get-LearnConfig
if (Start-LearnServer -Port $cfg.port -WorkDir $PSScriptRoot) { exit 0 }
exit 1
