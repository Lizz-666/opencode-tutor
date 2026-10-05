$ErrorActionPreference = 'Stop'

# 扩展 JS 语法门禁（无 node 时跳过并提示）
$extJs = Join-Path (Split-Path -Parent $PSScriptRoot) 'extension\extension.js'
if (Test-Path -LiteralPath $extJs) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
        & node --check $extJs
        if ($LASTEXITCODE -ne 0) { Write-Output 'extension.js 语法检查失败'; exit 1 }
        Write-Output 'extension.js syntax OK'
        $nodeTests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.test.cjs' | Select-Object -ExpandProperty FullName)
        & node --test @nodeTests
        if ($LASTEXITCODE -ne 0) { exit 1 }
    } else {
        Write-Output 'node 不在 PATH，跳过 extension.js 语法门禁'
    }
}

$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' | Select-Object -ExpandProperty FullName)
if ($tests.Count -eq 0) { Write-Output 'no test files found'; exit 1 }
Import-Module (Join-Path $PSScriptRoot 'sandbox.psm1') -Force
$result = Invoke-Pester -Script $tests -PassThru
Write-Output ('passed: ' + $result.PassedCount + '  failed: ' + $result.FailedCount)
if ($result.FailedCount -gt 0) { exit 1 }
exit 0
