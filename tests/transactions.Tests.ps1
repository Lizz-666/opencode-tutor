$transactionRepo=Split-Path -Parent $PSScriptRoot
. (Join-Path $transactionRepo 'scripts\explain.lib.ps1')
Import-Module (Join-Path $PSScriptRoot 'sandbox.psm1') -Force

Describe 'Cross-process learning line creation' {
    $script:transactionSandbox=New-Sandbox -Name 'learn-transaction-test'
    AfterAll { if($script:transactionSandbox){Remove-Sandbox -Sandbox $script:transactionSandbox} }

    It 'creates exactly one learning line for two simultaneous requests' {
        $box=$script:transactionSandbox
        $main=New-SandboxSession -BaseUrl $box.BaseUrl -Title 'Concurrent main'
        $state=Join-Path $box.Directory 'state.json'
        $lineDir=Join-Path $box.Directory 'lines'
        $children=@()
        for($i=0;$i -lt 2;$i++) {
            $output=Join-Path $box.Directory ('result-'+$i+'.txt')
            $body=". '"+(Join-Path $transactionRepo 'scripts\explain.lib.ps1').Replace("'","''")+"'; "
            $body+='$main=[pscustomobject]@{id=' + "'"+$main.id+"';title='Concurrent main'}; "
            $body+="Get-OrCreateLearnLine -BaseUrl '"+$box.BaseUrl+"' -StateFile '"+$state.Replace("'","''")+"' -LineDir '"+$lineDir.Replace("'","''")+"' -Main `$main | Set-Content -LiteralPath '"+$output.Replace("'","''")+"'"
            $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
            $children+=Start-Process powershell.exe -ArgumentList ('-NoProfile -EncodedCommand '+$encoded) -WindowStyle Hidden -PassThru
        }
        try {
            foreach($child in $children){$child.WaitForExit(30000) | Should Be $true}
            $first=[IO.File]::ReadAllText((Join-Path $box.Directory 'result-0.txt')).Trim()
            $second=[IO.File]::ReadAllText((Join-Path $box.Directory 'result-1.txt')).Trim()
            $first | Should Not BeNullOrEmpty
            $first | Should Be $second
            @(Get-LearnSessions -BaseUrl $box.BaseUrl -Directory $lineDir).Count | Should Be 1
            (Read-LearnState $state).lines[$main.id] | Should Be $first
        } finally {foreach($child in $children){if(-not $child.HasExited){$child.Kill()}}}
    }
}
