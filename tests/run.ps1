$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Select-Object -ExpandProperty FullName)
if ($tests.Count -eq 0) { Write-Output 'no test files found'; exit 1 }
Import-Module (Join-Path $PSScriptRoot 'sandbox.psm1') -Force
$result = Invoke-Pester -Script $tests -PassThru
Write-Output ('passed: ' + $result.PassedCount + '  failed: ' + $result.FailedCount)
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
