function Get-LearnMessageText {
    param($Message)
    return (@($Message.parts | Where-Object { $_.type -eq 'text' -and $_.text -and -not $_.ignored } | ForEach-Object { [string]$_.text }) -join "`n")
}

function Find-LearnSelection {
    param([object[]]$Messages, [string]$SelectedText)
    $needle = [regex]::Replace($SelectedText, '\s+', ' ').Trim()
    if (-not $needle) { return -1 }
    for ($i = $Messages.Count - 1; $i -ge 0; $i--) {
        $text = [regex]::Replace((Get-LearnMessageText $Messages[$i]), '\s+', ' ')
        if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
    }
    return -1
}

function New-LearnContext {
    param([object[]]$Messages = @(), [string]$SelectedText = '', [int]$MaxChars = 12000,
        [ValidateSet('relevant','recent','none')][string]$Mode = 'relevant')
    $items = @($Messages | Where-Object { $_.info.role -in @('user','assistant') -and (Get-LearnMessageText $_) })
    $anchor = Find-LearnSelection $items $SelectedText
    $match = if ($anchor -ge 0) { 'exact' } else { 'recent' }
    if ($Mode -eq 'relevant' -and $anchor -lt 0 -and $SelectedText) {
        $terms = @([regex]::Matches($SelectedText, '[A-Za-z_][A-Za-z0-9_]{2,}|[\p{IsCJKUnifiedIdeographs}]{2,}') |
            ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique -First 32)
        $best = 0
        for ($i = 0; $i -lt $items.Count; $i++) {
            $text = (Get-LearnMessageText $items[$i]).ToLowerInvariant()
            $score = @($terms | Where-Object { $text.Contains($_) }).Count
            if ($score -gt 0 -and $score -ge $best) { $best = $score; $anchor = $i }
        }
        if ($best -gt 0) { $match = 'related' }
    }
    $priority = New-Object 'System.Collections.Generic.List[int]'
    if ($Mode -eq 'relevant' -and $anchor -ge 0) {
        $priority.Add($anchor)
        for ($i = $anchor - 1; $i -ge [Math]::Max(0,$anchor-4); $i--) {
            if ($items[$i].info.role -eq 'user') { $priority.Add($i); break }
        }
        if ($anchor -gt 0) { $priority.Add($anchor-1) }
        if ($anchor+1 -lt $items.Count) { $priority.Add($anchor+1) }
    }
    $recentCount = if ($Mode -eq 'recent') { 8 } else { 4 }
    for ($i = $items.Count-1; $i -ge [Math]::Max(0,$items.Count-$recentCount); $i--) { $priority.Add($i) }
    $selected = @{}; $length = 0; $skipped = 0
    if ($Mode -ne 'none' -and $MaxChars -gt 0) {
        foreach ($index in @($priority | Select-Object -Unique)) {
            $text = [string]$items[$index].info.role + ': ' + (Get-LearnMessageText $items[$index])
            $cost = $text.Length; if ($selected.Count) { $cost += 2 }
            if ($length+$cost -gt $MaxChars) { $skipped++; continue }
            $selected[$index] = $text; $length += $cost
        }
    }
    $background = (@($selected.Keys | Sort-Object | ForEach-Object { $selected[$_] }) -join "`n`n")
    return [pscustomobject]@{ text=$background; chars=$background.Length; messages=$selected.Count;
        available=$items.Count; omitted=($items.Count-$selected.Count); oversized=$skipped;
        match=$match; mode=$Mode; budget=$MaxChars }
}

function Get-LearnContextMessages {
    param([string]$BaseUrl, [string]$SessionId, [string]$Directory, [string]$SelectedText,
        [int]$PageSize = 40, [int]$MaxMessages = 200,
        [ValidateSet('relevant','recent','none')][string]$Mode = 'relevant', [scriptblock]$Checkpoint)
    if ($Mode -eq 'none') { return }
    $all = @(); $seen = @{}; $before = ''
    while ($all.Count -lt $MaxMessages) {
        if ($Checkpoint) { & $Checkpoint }
        $take = [Math]::Min($PageSize,$MaxMessages-$all.Count)
        $nextCursor = ''
        $page = @(Get-LearnMessages -BaseUrl $BaseUrl -SessionId $SessionId -Directory $Directory -Limit $take -Before $before -NextCursor ([ref]$nextCursor))
        # Bound even servers that ignore the limit/before query parameters.
        $page = @($page | Select-Object -Last $take)
        $fresh = @($page | Where-Object { $_.info.id -and -not $seen.ContainsKey([string]$_.info.id) })
        if (-not $fresh.Count) { break }
        foreach ($message in $fresh) { $seen[[string]$message.info.id] = $true }
        $all = @($fresh) + @($all)
        if ($Mode -eq 'recent' -or -not $nextCursor -or $nextCursor -eq $before) { break }
        $items = @($all | Where-Object { $_.info.role -in @('user','assistant') -and (Get-LearnMessageText $_) })
        $anchor = Find-LearnSelection $items $SelectedText
        if ($anchor -ge 0) {
            # Match New-LearnContext's four-message lookbehind, including page boundaries.
            $hasQuestion = $false
            for ($i = $anchor-1; $i -ge [Math]::Max(0,$anchor-4); $i--) {
                if ($items[$i].info.role -eq 'user') { $hasQuestion = $true; break }
            }
            if ($hasQuestion -or $anchor -ge 4 -or $items[$anchor].info.role -eq 'user') { break }
        }
        # before is opaque. Older servers without a cursor stay on the bounded first page.
        $before = $nextCursor
    }
    return $all
}
