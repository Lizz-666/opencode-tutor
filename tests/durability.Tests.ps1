$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'scripts\explain.lib.ps1')
. (Join-Path $repo 'scripts\jsonc.ps1')

Describe 'Durable state and explicit main selection' {
    It 'merges stale snapshots without losing unrelated sessions and preserves a backup' {
        $file = Join-Path $TestDrive 'state.json'
        Write-LearnState -Path $file -Lines @{}
        $a = Read-LearnState $file; $b = Read-LearnState $file
        $a.lines['mainA']='learnA'; $b.lines['mainB']='learnB'
        Write-LearnState -Path $file -Lines $a.lines
        Write-LearnState -Path $file -Lines $b.lines
        $state = Read-LearnState $file
        $state.lines.Count | Should Be 2
        (Read-LearnState ($file+'.bak')).lines['mainA'] | Should Be 'learnA'
    }
    It 'serializes real processes writing different mappings' {
        $file = Join-Path $TestDrive 'parallel.json'
        $jobs = @()
        for ($i=0;$i -lt 6;$i++) {
            $code = ". '" + (Join-Path $repo 'scripts\explain.lib.ps1').Replace("'","''") + "'; Write-LearnState -Path '" + $file.Replace("'","''") + "' -Lines @{ 'main$i'='learn$i' }"
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
            $jobs += Start-Process powershell.exe -ArgumentList ('-NoProfile -EncodedCommand '+$encoded) -WindowStyle Hidden -PassThru
        }
        try {
            foreach ($job in $jobs) { $job.WaitForExit(20000) | Should Be $true }
            (Read-LearnState $file).lines.Count | Should Be 6
            @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should Be 0
        } finally { foreach($job in $jobs) { if(-not $job.HasExited){$job.Kill()} } }
    }
    It 'excludes child and archived sessions and rejects an invalid explicit binding' {
        $items=@(
            [pscustomobject]@{id='main';directory='C:\project';title='Main';time=@{updated=1}},
            [pscustomobject]@{id='child';parentID='main';directory='C:\project';title='Child';time=@{updated=9}},
            [pscustomobject]@{id='archived';directory='C:\project';title='Archived';time=@{updated=10;archived=10}}
        )
        (Select-MainSession -Sessions $items -Directory 'C:\project').id | Should Be 'main'
        Select-MainSession -Sessions $items -Directory 'C:\project' -MainSessionId 'child' | Should BeNullOrEmpty
    }
    It 'does not overwrite an invalid schema' {
        $file=Join-Path $TestDrive 'invalid.json'
        [IO.File]::WriteAllText($file,'{"lines":[]}')
        { Write-LearnState $file @{a='b'} } | Should Throw
        [IO.File]::ReadAllText($file) | Should Be '{"lines":[]}'
    }
}

Describe 'JSONC edits' {
    It 'preserves target array order through replacements insertions deletions and duplicates' {
        $cases = @(
            @{ old='[1,2]'; next='[2,1]' },
            @{ old='[1,3]'; next='[1,2,3]' },
            @{ old='[1,2,3]'; next='[2,3,1]' },
            @{ old='[1,2,1]'; next='[1,1,2,1]' },
            @{ old='[1,2,3,]'; next='[3]' },
            @{ old='[]'; next='[1,2]' },
            @{ old='[1,2]'; next='[]' },
            @{ old='[1]'; next='[0,1,2]' },
            @{ old='[[1,2],{"items":[3,4]}]'; next='[[2,1],{"items":[4,3]}]' }
        )
        foreach ($case in $cases) {
            [TutorJsonc]::Clean([TutorJsonc]::Patch($case.old,$case.next)) | Should Be $case.next
        }
    }
    It 'keeps comments and unchanged entries when replacing an array entry in place' {
        $old = "// header`n[`n// ours`n{`"command`":`"old`"}, /* between */`n// custom`n{ `"command`" : `"custom`" },`n// footer`n]"
        $next = '[{"command":"new"},{"command":"custom"}]'
        $patched = [TutorJsonc]::Patch($old,$next)
        [TutorJsonc]::Clean($patched) | Should Be $next
        foreach ($comment in @('// header','// ours','/* between */','// custom','// footer')) {
            $patched.Contains($comment) | Should Be $true
        }
        $patched.Contains('{ "command" : "custom" }') | Should Be $true
        [TutorJsonc]::Patch($patched,$next) | Should Be $patched
    }
    It 'compares object values independent of property order but keeps array order significant' {
        [TutorJsonc]::Equivalent('[{"key":"alt+l","command":"custom"}]','[{"command":"custom","key":"alt+l"}]') | Should Be $true
        [TutorJsonc]::Equivalent('[1,2]','[2,1]') | Should Be $false
    }
    It 'keeps URLs comment-like strings and comments during nested edits' {
        $old='{/* top */"agent":{"explain":{/* model */"model":"https://example/a//b",}},"other":"/*not comment*/",}'
        $new='{"agent":{"explain":{"model":"https://example/a//b","mode":"subagent"}},"other":"/*not comment*/"}'
        $patched=[TutorJsonc]::Patch($old,$new)
        $patched.Contains('/* model */') | Should Be $true
        (ConvertFrom-TutorJsonc $patched).other | Should Be '/*not comment*/'
        (ConvertFrom-TutorJsonc $patched).agent.explain.mode | Should Be 'subagent'
    }
    It 'handles removal of all array entries and all object properties' {
        [TutorJsonc]::Clean([TutorJsonc]::Patch('[1,2,3,]','[]')) | Should Be '[]'
        [TutorJsonc]::Clean([TutorJsonc]::Patch('{"a":1,"b":2,}','{}')) | Should Be '{}'
    }
    It 'does not rewrite malformed JSONC' {
        $file=Join-Path $TestDrive 'malformed.json'
        [IO.File]::WriteAllText($file,'{/*unclosed')
        { Write-TutorJsonc -Path $file -Value @{a=1} } | Should Throw
        [IO.File]::ReadAllText($file) | Should Be '{/*unclosed'
    }
}

Describe 'Hidden prewarm executable' {
    It 'compiles with Windows GUI subsystem and an encoded hidden child launch' {
        $exe=Join-Path $TestDrive 'launcher.exe'
        Add-Type -Path (Join-Path $repo 'scripts\HiddenLauncher.cs') -OutputAssembly $exe -OutputType WindowsApplication
        $bytes=[IO.File]::ReadAllBytes($exe)
        $pe=[BitConverter]::ToInt32($bytes,0x3c)
        [BitConverter]::ToInt16($bytes,$pe+24+68) | Should Be 2
    }
}
