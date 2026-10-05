. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\explain.lib.ps1')

function New-ContextFixture {
    param([string]$Id, [string]$Text, [string]$Role = 'assistant')
    [pscustomobject]@{ info=[pscustomobject]@{id=$Id;role=$Role}; parts=@(@{type='text';text=$Text}) }
}

Describe 'Bounded relevant context' {
    It 'keeps an older selected message and its question before unrelated recent text' {
        $messages = @((New-ContextFixture '1' 'Why do we need a mutex?' 'user'),(New-ContextFixture '2' 'A mutex protects shared state.'))
        3..20 | ForEach-Object { $messages += New-ContextFixture ([string]$_) ('unrelated '+('x'*80)) }
        $ctx = New-LearnContext $messages 'mutex protects shared state' 100
        $ctx.match | Should Be 'exact'
        $ctx.text.Contains('Why do we need a mutex?') | Should Be $true
        $ctx.text.Contains('A mutex protects shared state.') | Should Be $true
        ($ctx.chars -le 100) | Should Be $true
        $ctx.text.Contains('unrelated') | Should Be $false
        ($ctx.text.IndexOf('user:') -lt $ctx.text.IndexOf('assistant:')) | Should Be $true
    }
    It 'matches wrapped selections and does not split a message or Unicode character' {
        $messages = @((New-ContextFixture '1' "alpha`n beta"),(New-ContextFixture '2' ([char]::ConvertFromUtf32(0x1F4D8)*100)))
        $ctx = New-LearnContext $messages 'alpha beta' 35
        $ctx.text | Should Be "assistant: alpha`n beta"
        $ctx.match | Should Be 'exact'
        $ctx.oversized | Should Be 1
    }
    It 'keeps all text parts of a message together and excludes tool output' {
        $message = New-ContextFixture '1' 'part one'
        $message.parts += @{type='text';text='part two'},@{type='tool';text='secret tool output'}
        (New-LearnContext @($message) '' 200).text | Should Be "assistant: part one`npart two"
        (New-LearnContext @($message) '' 20).text | Should Be ''
    }
    It 'supports recent-only and selection-only contexts without changing the selection' {
        $messages = @(1..12 | ForEach-Object { New-ContextFixture ([string]$_) ('message-'+$_) })
        $ctx = New-LearnContext $messages 'message-1' 1000 -Mode recent
        $ctx.messages | Should Be 8
        $ctx.text.Contains('message-1' + "`n") | Should Be $false
        (New-LearnContext $messages 'message-1' 1000 -Mode none).text | Should Be ''
        (New-LearnContext $messages 'message-1' 0).text | Should Be ''
        foreach ($style in @('brief','detailed','example')) {
            $body = New-LearnPromptBody 'raw selection' -Style $style
            $body.parts[0].text | Should Be 'raw selection'
            $body.system.Contains('本次') | Should Be $true
        }
    }
    It 'clamps unsafe context and history limits while retaining custom budgets' {
        $file = Join-Path $TestDrive 'config.json'
        [IO.File]::WriteAllText($file,'{"backgroundMaxChars":20000,"contextPageSize":-1,"contextMaxMessages":99999,"learningMaxMessages":-1}')
        $cfg = Get-LearnConfig $file
        $cfg.backgroundMaxChars | Should Be 20000
        $cfg.contextPageSize | Should Be 1
        $cfg.contextMaxMessages | Should Be 500
        $cfg.learningMaxMessages | Should Be 2
    }
}

Describe 'Bounded history retrieval' {
    It 'fetches the preceding question when the selected answer starts a page' {
        Mock Get-LearnMessages {
            if ($Before) { $NextCursor.Value='even-older'; @(New-ContextFixture '1' 'Why use a mutex?' 'user') }
            else { $NextCursor.Value='older'; @((New-ContextFixture '2' 'selected answer'),(New-ContextFixture '3' 'unrelated topic' 'user')) }
        }
        $messages = @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'selected answer' -PageSize 2 -MaxMessages 10)
        (New-LearnContext $messages 'selected answer' 1000).text.Contains('Why use a mutex?') | Should Be $true
        Assert-MockCalled Get-LearnMessages -Times 2 -Exactly -Scope It
    }
    It 'stops supplementing after four preceding text messages or the scan cap' {
        Mock Get-LearnMessages {
            $NextCursor.Value='cursor-'+$Limit+'-'+$Before
            if (-not $Before) { @(New-ContextFixture '9' 'selected answer'); return }
            if ($Before -eq 'cursor-2-') { @((New-ContextFixture '7' 'before 7'),(New-ContextFixture '8' 'before 8')) }
            else { @((New-ContextFixture '5' 'before 5'),(New-ContextFixture '6' 'before 6')) }
        }
        @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'selected answer' -PageSize 2 -MaxMessages 20).Count | Should Be 5
        Assert-MockCalled Get-LearnMessages -Times 3 -Exactly -Scope It
        @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'selected answer' -PageSize 2 -MaxMessages 2).Count | Should Be 2
    }
    It 'follows before cursors only until the selected older message is found' {
        Mock Get-LearnMessages {
            if ($Before) { @(New-ContextFixture '1' 'older selected phrase') }
            else { $NextCursor.Value='opaque-cursor'; @((New-ContextFixture '2' 'middle'),(New-ContextFixture '3' 'latest')) }
        }
        $messages = @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'older selected phrase' -PageSize 2 -MaxMessages 6)
        ($messages.info.id -join ',') | Should Be '1,2,3'
        Assert-MockCalled Get-LearnMessages -Times 1 -Exactly -Scope It -ParameterFilter { $Before -eq 'opaque-cursor' -and $Limit -eq 2 }
    }
    It 'deduplicates and stops if a server ignores the before cursor' {
        Mock Get-LearnMessages { $NextCursor.Value='ignored-cursor'; @((New-ContextFixture '1' 'one'),(New-ContextFixture '2' 'two')) }
        @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'missing' -PageSize 2 -MaxMessages 8).Count | Should Be 2
        Assert-MockCalled Get-LearnMessages -Times 2 -Exactly -Scope It
    }
    It 'does not fetch background in selection-only mode' {
        Mock Get-LearnMessages { throw 'Must not read context' }
        @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -Mode none).Count | Should Be 0
        Assert-MockCalled Get-LearnMessages -Times 0 -Exactly -Scope It
    }
    It 'checks cancellation between pages' {
        Mock Get-LearnMessages { $NextCursor.Value='next-page'; @((New-ContextFixture '1' 'one'),(New-ContextFixture '2' 'two')) }
        $script:checkpoints = 0
        { Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -PageSize 2 -Checkpoint { $script:checkpoints++; if($script:checkpoints -gt 1){throw 'cancelled'} } } | Should Throw
        Assert-MockCalled Get-LearnMessages -Times 1 -Exactly -Scope It
    }
    It 'stops at the first page when an older server has no pagination cursor' {
        Mock Get-LearnMessages { @((New-ContextFixture '1' 'one'),(New-ContextFixture '2' 'two')) }
        @(Get-LearnContextMessages -BaseUrl 'http://test' -SessionId 's' -SelectedText 'missing' -PageSize 2).Count | Should Be 2
        Assert-MockCalled Get-LearnMessages -Times 1 -Exactly -Scope It
    }
}

Describe 'Learning history rollover' {
    BeforeEach {
        $script:state = Join-Path $TestDrive ('state-'+[Guid]::NewGuid().ToString('N')+'.json')
        $script:lineDir = Join-Path $TestDrive 'lines'
        Write-LearnState $script:state @{main='learn_old'}
        Mock Get-LearnMessages { @((New-ContextFixture '1' 'one'),(New-ContextFixture '2' 'two')) }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/session/status*') { return [pscustomobject]@{} }
            return [pscustomobject]@{id='learn_old';directory=$script:lineDir;title='[LEARN] old'}
        }
        Mock Invoke-LearnCreate { [pscustomobject]@{id='learn_new'} }
        Mock Remove-LearnSession { throw 'Never delete history' }
    }
    It 'rolls an over-limit line forward while returning the retained prior session' {
        $previous = ''
        Get-OrCreateLearnLine 'http://test' $script:state $script:lineDir @{id='main';title='main'} -MaxMessages 2 -PreviousId ([ref]$previous) | Should Be 'learn_new'
        $previous | Should Be 'learn_old'
        (Read-LearnState $script:state).lines.main | Should Be 'learn_new'
        Assert-MockCalled Remove-LearnSession -Times 0 -Exactly -Scope It
    }
    It 'keeps the old mapping if cancellation arrives during session creation' {
        $script:cancelled = $false
        Mock Invoke-LearnCreate { $script:cancelled=$true; [pscustomobject]@{id='learn_new'} }
        { Get-OrCreateLearnLine 'http://test' $script:state $script:lineDir @{id='main';title='main'} -NewLine -Checkpoint { if ($script:cancelled) { throw 'cancelled' } } } | Should Throw
        (Read-LearnState $script:state).lines.main | Should Be 'learn_old'
        Assert-MockCalled Remove-LearnSession -Times 0 -Exactly -Scope It
    }
    It 'allows the caller to defer mapping publication until the send boundary' {
        Get-OrCreateLearnLine 'http://test' $script:state $script:lineDir @{id='main';title='main'} -NewLine -DeferStateWrite | Should Be 'learn_new'
        (Read-LearnState $script:state).lines.main | Should Be 'learn_old'
    }
    It 'does not move the mapping while the old learning line is busy' {
        Mock Invoke-RestMethod {
            if ($Uri -like '*/session/status*') { return [pscustomobject]@{learn_old=@{type='busy'}} }
            [pscustomobject]@{id='learn_old';directory=$script:lineDir;title='[LEARN] old'}
        }
        $previous = ''
        { Get-OrCreateLearnLine 'http://test' $script:state $script:lineDir @{id='main';title='main'} -NewLine -PreviousId ([ref]$previous) } | Should Throw
        $previous | Should Be 'learn_old'
        (Read-LearnState $script:state).lines.main | Should Be 'learn_old'
        Assert-MockCalled Invoke-LearnCreate -Times 0 -Exactly -Scope It
    }
    It 'rolls over oversized text history even before the message count limit' {
        Mock Get-LearnMessages { @((New-ContextFixture '1' ('x'*150)),(New-ContextFixture '2' ('y'*150))) }
        Get-OrCreateLearnLine 'http://test' $script:state $script:lineDir @{id='main';title='main'} -MaxMessages 40 -MaxChars 200 | Should Be 'learn_new'
        Assert-MockCalled Remove-LearnSession -Times 0 -Exactly -Scope It
    }
}
