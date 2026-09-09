$cfgPath = Join-Path $PSScriptRoot 'config.json'
$port = 4399
try {
    if (Test-Path -LiteralPath $cfgPath) {
        $obj = (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($obj.port) { $port = [int]$obj.port }
    }
} catch {}
$log = Join-Path $env:TEMP 'opencode\learn-serve.log'
$dir = Split-Path -Parent $log
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
& opencode serve --port $port --hostname 127.0.0.1 --print-logs *>> $log
