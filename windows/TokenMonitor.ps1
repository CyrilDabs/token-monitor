# ---------------------------------------------------------------
#  Token Monitor
#  A small always-on-top window that shows how many tokens are being
#  used, and what for.
#   - Claude Code: read from Claude Code's own log files on this PC.
#   - Other sources (OpenAI, Claude API, or any service with a usage
#     link): added with the "+ Add source" button.
#  It only READS. It never changes anything.
# ---------------------------------------------------------------

# --- Settings you can change ---
$WarnAt          = 120000   # pop-up when a Claude Code session re-reads this many tokens per message
$RefreshSeconds  = 5        # how often the window updates
$SourceMinutes   = 5        # how often to ask the other sources for fresh numbers
# --------------------------------

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Web.Extensions

$Root       = Join-Path $env:USERPROFILE '.claude\projects'
$AppDir     = Join-Path $env:APPDATA 'ClaudeTokenMonitor'
$SrcFile    = Join-Path $AppDir 'sources.json'
$LogFile    = Join-Path $AppDir 'sources-log.txt'
$OldKeyFile = Join-Path $AppDir 'openai.key'

$ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength  = [int]::MaxValue
$ser.RecursionLimit = 1000
$bc  = New-Object System.Windows.Media.BrushConverter
$script:Files    = @{}
$script:Busy     = $false
$script:Small    = $false
$script:SrcJob   = $null
$script:SrcData  = $null
$script:SrcError = $null
$script:SrcLast  = [datetime]::MinValue
$script:CopiedAt = $null

function Brush($hex) { $bc.ConvertFromString($hex) }

function Fmt($n) {
    $n = [double]$n
    if ($n -ge 1000000) { return ('{0:0.0}M' -f ($n / 1000000)) }
    if ($n -ge 1000)    { return ('{0:0.0}k' -f ($n / 1000)) }
    return ('{0:0}' -f $n)
}

function Add-Note($panel, $text, $color) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Foreground = (Brush $color); $t.FontSize = 11
    $t.TextWrapping = 'Wrap'
    $t.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
    [void]$panel.Children.Add($t)
}

# The prompt you paste into an old session so Claude writes a hand-off note
# for a fresh session. That way you never lose your progress by starting over.
$WrapUp = @'
We're moving to a fresh session to save tokens. Write a short hand-off note (under 250 words) that I can paste into a new Claude Code session. Include:
1. What we're building and which folder/files matter
2. What we finished
3. Decisions we made, and why
4. Anything broken or half-done
5. The exact next step
Write it as instructions to a new Claude, not to me. Don't change any files.
'@

function Copy-WrapUp {
    try {
        [System.Windows.Clipboard]::SetText($WrapUp)
        $ui.BtnWrap.Content = 'Copied! Now paste it into the old session'
        $script:CopiedAt = Get-Date
    } catch {}
}

# ================= Sources (saved encrypted, only on this PC) =================

function Protect-Text($t) {
    if (-not $t) { return '' }
    return (ConvertTo-SecureString $t -AsPlainText -Force | ConvertFrom-SecureString)
}

function Unprotect-Text($t) {
    if (-not $t) { return '' }
    try {
        $ss = $t | ConvertTo-SecureString
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { return '' }
}

function Save-Sources {
    New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
    $arr = @(foreach ($s in $script:Sources) {
        [pscustomobject]@{ Type = $s.Type; Name = $s.Name; Key = (Protect-Text $s.Key)
                           Url = $s.Url; Header = $s.Header; Prefix = $s.Prefix; Fields = $s.Fields }
    })
    $json = if ($arr.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $arr -Depth 4 }
    Set-Content -Path $SrcFile -Value $json
}

function Load-Sources {
    $list = New-Object System.Collections.ArrayList
    $migrated = $false
    if (Test-Path $SrcFile) {
        try {
            foreach ($x in @(Get-Content -Path $SrcFile -Raw | ConvertFrom-Json)) {
                if (-not $x) { continue }
                [void]$list.Add(@{ Type = [string]$x.Type; Name = [string]$x.Name; Key = (Unprotect-Text ([string]$x.Key))
                                   Url = [string]$x.Url; Header = [string]$x.Header; Prefix = [string]$x.Prefix; Fields = [string]$x.Fields })
            }
        } catch {}
    }
    elseif (Test-Path $OldKeyFile) {
        # Bring over the OpenAI key saved by the earlier version
        $k = Unprotect-Text ((Get-Content -Path $OldKeyFile -Raw).Trim())
        if ($k) {
            [void]$list.Add(@{ Type = 'openai'; Name = 'OpenAI'; Key = $k; Url = ''; Header = ''; Prefix = ''; Fields = '' })
            $migrated = $true
        }
    }
    $script:Sources = $list
    if ($migrated) { Save-Sources }
}

$script:Sources = New-Object System.Collections.ArrayList
Load-Sources

# This runs in the background so the window never freezes while services answer.
$FetchAll = {
    param($sources, $logFile)
    function Log($m) { try { Add-Content -Path $logFile -Value ('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss'), $m) } catch {} }
    try { Set-Content -Path $logFile -Value ('Check started ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) } catch {}

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $now        = Get-Date
    $midLocal   = $now.Date
    $monthLocal = $now.Date.AddDays(1 - $now.Day)
    $mid      = ([DateTimeOffset]$midLocal).ToUnixTimeSeconds()
    $month    = ([DateTimeOffset]$monthLocal).ToUnixTimeSeconds()
    $nowUnix  = ([DateTimeOffset]$now).ToUnixTimeSeconds()
    $midIso   = $midLocal.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $monthIso = $monthLocal.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $nowIso   = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    function Add-Count($table, $key, $value) { $table[$key] = [long]$table[$key] + [long]$value }

    function Get-OpenAI($s, $o) {
        $h = @{ Authorization = "Bearer $($s.Key)" }
        $base = 'https://api.openai.com/v1/organization'
        $names = @{}
        try {
            Log '  getting project names'
            $pr = Invoke-RestMethod -Uri "$base/projects?limit=100&include_archived=true" -Headers $h -TimeoutSec 30
            foreach ($p in $pr.data) { $names[[string]$p.id] = [string]$p.name }
        } catch { Log "  project names failed: $($_.Exception.Message)" }

        $url = "$base/usage/completions?start_time=$mid&bucket_width=1h&limit=24&group_by=model&group_by=project_id"
        $page = $null; $n = 0
        do {
            $u = $url; if ($page) { $u += '&page=' + [uri]::EscapeDataString($page) }
            Log "  getting token usage (page $($n + 1))"
            $r = Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec 30
            foreach ($b in $r.data) {
                foreach ($x in $b.results) {
                    $in = [long]$x.input_tokens; $ca = [long]$x.input_cached_tokens; $ot = [long]$x.output_tokens
                    $o.Fresh += [math]::Max(0, $in - $ca); $o.Cached += $ca; $o.Output += $ot
                    $o.Requests += [long]$x.num_model_requests
                    $m = if ($x.model) { [string]$x.model } else { 'unknown model' }
                    Add-Count $o.Models $m ($in + $ot)
                    $pj = [string]$x.project_id
                    $pn = if ($pj -and $names[$pj]) { $names[$pj] } elseif ($pj) { $pj } else { 'Default project' }
                    Add-Count $o.Projects $pn ($in + $ot)
                }
            }
            $page = if ($r.has_more -and $r.next_page) { [string]$r.next_page } else { $null }
            $n++
        } while ($page -and $n -lt 10)

        try {
            Log '  getting speech-to-text usage'
            $r = Invoke-RestMethod -Uri "$base/usage/audio_transcriptions?start_time=$mid&bucket_width=1h&limit=24" -Headers $h -TimeoutSec 30
            foreach ($b in $r.data) { foreach ($x in $b.results) { $o.AudioSeconds += [double]$x.seconds } }
        } catch { Log "  speech-to-text failed: $($_.Exception.Message)" }

        try {
            Log '  getting this month''s bill'
            $r = Invoke-RestMethod -Uri "$base/costs?start_time=$month&bucket_width=1d&limit=31" -Headers $h -TimeoutSec 30
            foreach ($b in $r.data) { foreach ($x in $b.results) { $o.CostMonth += [double]$x.amount.value } }
            $o.CostOk = $true
        } catch { Log "  bill failed: $($_.Exception.Message)" }

        $o.Total = $o.Fresh + $o.Cached + $o.Output
    }

    function Get-Anthropic($s, $o) {
        $h = @{ 'x-api-key' = $s.Key; 'anthropic-version' = '2023-06-01' }
        $url = 'https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at=' + [uri]::EscapeDataString($midIso) + '&bucket_width=1h&limit=24&group_by%5B%5D=model'
        $page = $null; $n = 0
        do {
            $u = $url; if ($page) { $u += '&page=' + [uri]::EscapeDataString($page) }
            Log "  getting token usage (page $($n + 1))"
            $r = Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec 30
            foreach ($b in $r.data) {
                foreach ($x in $b.results) {
                    $f  = [long]$x.uncached_input_tokens
                    $c  = [long]$x.cache_read_input_tokens
                    $w  = [long]$x.cache_creation.ephemeral_5m_input_tokens + [long]$x.cache_creation.ephemeral_1h_input_tokens
                    $ot = [long]$x.output_tokens
                    $o.Fresh += $f; $o.Cached += $c; $o.CacheWrite += $w; $o.Output += $ot
                    $m = if ($x.model) { [string]$x.model } else { 'unknown model' }
                    Add-Count $o.Models $m ($f + $c + $w + $ot)
                }
            }
            $page = if ($r.has_more -and $r.next_page) { [string]$r.next_page } else { $null }
            $n++
        } while ($page -and $n -lt 10)
        $o.Total = $o.Fresh + $o.Cached + $o.CacheWrite + $o.Output
    }

    # Adds up every number found at a path like "data[].results[].output_tokens"
    function Sum-Path($obj, $path) {
        $cur = @(, $obj)
        foreach ($part in ($path.Trim() -split '\.')) {
            $iter = $part.EndsWith('[]')
            $name = $part.TrimEnd('[', ']')
            $next = New-Object System.Collections.ArrayList
            foreach ($c in $cur) {
                if ($null -eq $c) { continue }
                $v = if ($name) { $c.$name } else { $c }
                if ($iter) { foreach ($x in @($v)) { [void]$next.Add($x) } } else { [void]$next.Add($v) }
            }
            $cur = $next
        }
        $sum = 0.0
        foreach ($c in $cur) { try { $sum += [double]$c } catch {} }
        return $sum
    }

    function Get-Custom($s, $o) {
        $u = [string]$s.Url
        $u = $u.Replace('{today_unix}', "$mid").Replace('{today_iso}', $midIso).Replace('{month_unix}', "$month").Replace('{month_iso}', $monthIso).Replace('{now_unix}', "$nowUnix").Replace('{now_iso}', $nowIso)
        $h = @{}
        if ($s.Key) {
            $hn = if ($s.Header) { [string]$s.Header } else { 'Authorization' }
            $h[$hn] = "$($s.Prefix)$($s.Key)"
        }
        Log "  calling $($u -replace '\?.*$', '?...')"
        $r = Invoke-RestMethod -Uri $u -Headers $h -TimeoutSec 30
        $tot = 0.0
        foreach ($path in ([string]$s.Fields -split ',')) { if ($path.Trim()) { $tot += (Sum-Path $r $path) } }
        $o.Total = $tot
    }

    foreach ($s in $sources) {
        $o = @{ Name = $s.Name; Type = $s.Type; Ok = $false; Error = ''
                Fresh = [long]0; Cached = [long]0; CacheWrite = [long]0; Output = [long]0; Total = [double]0
                Requests = [long]0; AudioSeconds = [double]0; CostMonth = [double]0; CostOk = $false
                Models = @{}; Projects = @{}; At = (Get-Date) }
        try {
            Log "Checking $($s.Name) ($($s.Type))"
            switch ($s.Type) {
                'openai'    { [void](Get-OpenAI $s $o) }
                'anthropic' { [void](Get-Anthropic $s $o) }
                default     { [void](Get-Custom $s $o) }
            }
            $o.Ok = $true
            Log "  done: $($o.Total) tokens today"
        }
        catch {
            $m = $_.Exception.Message
            Log "  FAILED: $m"
            if ($m -match '401|403|Unauthorized|Forbidden') { $m = 'The key was not accepted. Check it is the right kind of key (usually an Admin key).' }
            elseif ($m -match '404|Not Found') { $m = 'That address was not found (404). Check the usage link.' }
            elseif ($m -match 'remote name|could not be resolved|Unable to connect') { $m = 'No internet connection right now.' }
            elseif ($m -match 'timed out|timeout') { $m = 'The service took too long to answer.' }
            $o.Error = $m
        }
        $o
    }
    Log 'Check finished'
}

function Update-Sources {
    if ($script:SrcJob) {
        if ($script:SrcJob.Handle.IsCompleted) {
            $list = New-Object System.Collections.ArrayList
            try {
                $r = $script:SrcJob.PS.EndInvoke($script:SrcJob.Handle)
                foreach ($x in $r) {
                    $d = $x
                    if ($d -is [System.Management.Automation.PSObject]) { $d = $d.BaseObject }
                    if ($d -is [hashtable]) { [void]$list.Add($d) }
                }
                if ($list.Count -eq 0) {
                    $em = 'No answer came back.'
                    if ($script:SrcJob.PS.Streams.Error.Count -gt 0) { $em = $script:SrcJob.PS.Streams.Error[0].ToString() }
                    $script:SrcError = $em
                } else { $script:SrcError = $null }
            } catch { $script:SrcError = $_.Exception.Message }
            if ($list.Count -gt 0) { $script:SrcData = $list }
            try { $script:SrcJob.PS.Dispose() } catch {}
            $script:SrcJob = $null
        }
        elseif (((Get-Date) - $script:SrcJob.Started).TotalSeconds -gt 90) {
            try { [void]$script:SrcJob.PS.BeginStop($null, $null) } catch {}
            $script:SrcJob = $null
            $script:SrcError = 'It took too long to answer (over 90 seconds). Click Sources, then Open log, to see where it got stuck.'
        }
    }
    if ($script:Sources.Count -gt 0 -and -not $script:SrcJob -and ((Get-Date) - $script:SrcLast).TotalMinutes -ge $SourceMinutes) {
        $script:SrcLast = Get-Date
        $plain = @(foreach ($s in $script:Sources) {
            @{ Type = $s.Type; Name = $s.Name; Key = $s.Key; Url = $s.Url; Header = $s.Header; Prefix = $s.Prefix; Fields = $s.Fields }
        })
        New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
        $ps = [powershell]::Create()
        [void]$ps.AddScript($FetchAll.ToString()).AddArgument($plain).AddArgument($LogFile)
        $script:SrcJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = (Get-Date) }
    }
    Render-Sources
}

function Render-One($p, $d) {
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = "$($d.Name)  -  $(Fmt $d.Total) tokens today"
    $h.Foreground = (Brush '#E8E6E3'); $h.FontSize = 12; $h.FontWeight = 'SemiBold'
    $h.TextTrimming = 'CharacterEllipsis'
    $h.Margin = New-Object System.Windows.Thickness(0, 8, 0, 0)
    [void]$p.Children.Add($h)

    if (-not $d.Ok) { Add-Note $p $d.Error '#FBBF24'; return }
    if ($d.Type -eq 'custom') { return }
    if ($d.Total -le 0 -and $d.AudioSeconds -le 0) { Add-Note $p 'No usage yet today.' '#8A8783'; return }

    $den = [math]::Max(1, $d.Total)
    [void]$p.Children.Add((New-Row 'New text sent in'       (Fmt $d.Fresh)  ($d.Fresh / $den)  '#F472B6' 'Text sent in that the service had not seen recently.'))
    [void]$p.Children.Add((New-Row 'Re-used text (cheaper)' (Fmt $d.Cached) ($d.Cached / $den) '#60A5FA' 'Text the service had seen moments ago, like the same instructions every time. Charged at a discount.'))
    if ($d.CacheWrite -gt 0) {
        [void]$p.Children.Add((New-Row 'Saved for re-use'   (Fmt $d.CacheWrite) ($d.CacheWrite / $den) '#A78BFA' 'Text stored so it can be re-used cheaply later.'))
    }
    [void]$p.Children.Add((New-Row 'Replies'                (Fmt $d.Output) ($d.Output / $den) '#FB923C' 'What the AI wrote back. The priciest kind per token.'))

    if ($d.Type -eq 'openai') {
        if ($d.Projects.Count -gt 1) {
            Add-Note $p 'By app:' '#8A8783'
            $apps = $d.Projects.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4
            $maxA = [math]::Max(1, ($apps | Measure-Object -Property Value -Maximum).Maximum)
            foreach ($a in $apps) {
                [void]$p.Children.Add((New-Row $a.Key (Fmt $a.Value) ($a.Value / $maxA) '#22D3EE' 'Tokens used by this OpenAI project today.'))
            }
        } elseif ($d.Projects.Count -eq 1) {
            Add-Note $p 'Your apps share one OpenAI project, so they show up together. Give each app its own project in OpenAI to see them separately.' '#8A8783'
        }
    }

    $models = $d.Models.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3
    if ($models) { Add-Note $p ('Models: ' + (($models | ForEach-Object { "$($_.Key) $(Fmt $_.Value)" }) -join '  |  ')) '#8A8783' }
    $bits = @()
    if ($d.Requests -gt 0)     { $bits += "$('{0:N0}' -f $d.Requests) requests" }
    if ($d.AudioSeconds -gt 0) { $bits += "$('{0:0.0}' -f ($d.AudioSeconds / 60)) min of speech-to-text" }
    if ($bits.Count -gt 0) { Add-Note $p ($bits -join '  |  ') '#D6D3CF' }
    if ($d.CostOk) { Add-Note $p ("Bill this month so far: `$" + ('{0:0.00}' -f $d.CostMonth) + '  (can lag a few hours)') '#D6D3CF' }
}

function Render-Sources {
    $p = $ui.SourcesPanel
    $p.Children.Clear()
    $ui.BtnKey.Content = if ($script:Sources.Count -gt 0) { 'Sources' } else { '+ Add source' }

    if ($script:Sources.Count -eq 0) {
        Add-Note $p 'Add OpenAI, the Claude API, or any service with a usage link to see its tokens here.' '#8A8783'
        return
    }
    if (-not $script:SrcData) {
        if ($script:SrcError) { Add-Note $p ("Couldn't check: " + $script:SrcError) '#FBBF24' }
        elseif ($script:SrcJob) {
            $secs = [int]((Get-Date) - $script:SrcJob.Started).TotalSeconds
            Add-Note $p "Checking $($script:Sources.Count) source(s)... $($secs)s" '#8A8783'
        }
        else { Add-Note $p 'Waiting to check...' '#8A8783' }
        return
    }
    foreach ($d in $script:SrcData) { Render-One $p $d }
    $foot = "Checked at $($script:SrcData[0].At.ToString('h:mm tt')), every $SourceMinutes min"
    if ($script:SrcJob)   { $foot += '  -  checking again now...' }
    if ($script:SrcError) { $foot += "  -  last check failed: $($script:SrcError)" }
    Add-Note $p $foot '#6B6864'
}

function Restart-Sources {
    $script:SrcData = $null; $script:SrcError = $null; $script:SrcLast = [datetime]::MinValue
    if ($script:SrcJob) { try { [void]$script:SrcJob.PS.BeginStop($null, $null) } catch {}; $script:SrcJob = $null }
}

function Show-SourcesDialog {
    $dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Token sources" Width="440" SizeToContent="Height" WindowStartupLocation="CenterScreen"
        Topmost="True" ResizeMode="NoResize" Background="#1F1E1C" FontFamily="Segoe UI">
  <StackPanel Margin="18">
    <TextBlock Foreground="#E8E6E3" FontSize="13" FontWeight="SemiBold" Text="Your sources"/>
    <StackPanel x:Name="ListPanel" Margin="0,4,0,16"/>

    <TextBlock Foreground="#E8E6E3" FontSize="13" FontWeight="SemiBold" Text="Add a new source"/>
    <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,8,0,2" Text="Type"/>
    <ComboBox x:Name="TypeBox" SelectedIndex="0" Height="28">
      <ComboBoxItem Content="OpenAI"/>
      <ComboBoxItem Content="Claude API (Anthropic)"/>
      <ComboBoxItem Content="Custom (any service with a usage link)"/>
    </ComboBox>
    <TextBlock x:Name="HelpText" Foreground="#8A8783" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>

    <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="Name (what to call it in the window)"/>
    <TextBox x:Name="NameBox" Height="28" Padding="4,4" Text="OpenAI"/>
    <TextBlock x:Name="KeyLabel" Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="Key"/>
    <PasswordBox x:Name="KeyBox" Height="28" Padding="4,4"/>

    <StackPanel x:Name="CustomPanel" Visibility="Collapsed">
      <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="Usage link (URL)"/>
      <TextBox x:Name="UrlBox" Height="28" Padding="4,4"/>
      <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="The key goes in this header"/>
      <TextBox x:Name="HeaderBox" Height="28" Padding="4,4" Text="Authorization"/>
      <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="Put this in front of the key (keep the space)"/>
      <TextBox x:Name="PrefixBox" Height="28" Padding="4,4" Text="Bearer "/>
      <TextBlock Foreground="#A8A5A0" FontSize="11" Margin="0,10,0,2" Text="Where the token numbers are in the answer"/>
      <TextBox x:Name="FieldsBox" Height="28" Padding="4,4"/>
      <TextBlock Foreground="#6B6864" FontSize="10" TextWrapping="Wrap" Margin="0,6,0,0"
                 Text="Example: data[].total_tokens. Add several with commas. In the link you can use {today_unix}, {today_iso}, {month_unix} or {month_iso} for the start of today or this month."/>
    </StackPanel>

    <TextBlock x:Name="ErrText" Foreground="#FBBF24" FontSize="11" TextWrapping="Wrap" Margin="0,8,0,0"/>
    <Grid Margin="0,14,0,0">
      <Button x:Name="BtnLog" Content="Open log" HorizontalAlignment="Left" Padding="12,5"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnDone" Content="Close" Margin="0,0,8,0" Padding="12,5" IsCancel="True"/>
        <Button x:Name="BtnAdd" Content="Add source" Padding="16,5" IsDefault="True"/>
      </StackPanel>
    </Grid>
  </StackPanel>
</Window>
'@
    $dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$dx)))
    $c = @{}
    foreach ($n in 'ListPanel','TypeBox','HelpText','NameBox','KeyLabel','KeyBox','CustomPanel','UrlBox','HeaderBox','PrefixBox','FieldsBox','ErrText','BtnLog','BtnDone','BtnAdd') {
        $c[$n] = $dlg.FindName($n)
    }
    $types  = @('openai', 'anthropic', 'custom')
    $labels = @{ openai = 'OpenAI'; anthropic = 'Claude API'; custom = 'Custom' }
    $helps  = @{
        openai    = 'Needs an OpenAI Admin key (starts with sk-admin-). Make one at platform.openai.com/settings/organization/admin-keys.'
        anthropic = 'Needs a Claude Admin key (starts with sk-ant-admin). Make one in the Claude Console under Settings > Admin keys. Only works for organization accounts.'
        custom    = 'For any service that has a usage link. You need the link, where the key goes, and where the token number is in the answer. Ask Claude to help you fill these in for a specific service.'
    }

    $renderList = {
        $c.ListPanel.Children.Clear()
        if ($script:Sources.Count -eq 0) {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = 'None yet.'; $t.Foreground = (Brush '#8A8783'); $t.FontSize = 12
            $t.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
            [void]$c.ListPanel.Children.Add($t)
        }
        foreach ($s in @($script:Sources)) {
            $g = New-Object System.Windows.Controls.Grid
            $g.Margin = New-Object System.Windows.Thickness(0, 6, 0, 0)
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = "$($s.Name)   ($($labels[$s.Type]))"; $t.Foreground = (Brush '#D6D3CF'); $t.FontSize = 12
            $t.VerticalAlignment = 'Center'
            $btn = New-Object System.Windows.Controls.Button
            $btn.Content = 'Remove'; $btn.Padding = New-Object System.Windows.Thickness(10, 2, 10, 2)
            $btn.HorizontalAlignment = 'Right'; $btn.Tag = $s
            $btn.Add_Click({
                param($sender, $e)
                $script:Sources.Remove($sender.Tag)
                Save-Sources
                Restart-Sources
                & $renderList
            })
            [void]$g.Children.Add($t); [void]$g.Children.Add($btn)
            [void]$c.ListPanel.Children.Add($g)
        }
    }

    $onType = {
        $ty = $types[[math]::Max(0, $c.TypeBox.SelectedIndex)]
        $c.HelpText.Text = $helps[$ty]
        $c.CustomPanel.Visibility = if ($ty -eq 'custom') { 'Visible' } else { 'Collapsed' }
        $c.KeyLabel.Text = if ($ty -eq 'custom') { 'Key (leave empty if the link needs none)' } else { 'Admin key' }
        if (-not $c.NameBox.Text -or $c.NameBox.Text -in @('OpenAI', 'Claude API', 'My service')) {
            $c.NameBox.Text = @{ openai = 'OpenAI'; anthropic = 'Claude API'; custom = 'My service' }[$ty]
        }
        $c.ErrText.Text = ''
    }
    $c.TypeBox.Add_SelectionChanged({ & $onType })

    $c.BtnAdd.Add_Click({
        $ty   = $types[[math]::Max(0, $c.TypeBox.SelectedIndex)]
        $name = $c.NameBox.Text.Trim()
        $key  = $c.KeyBox.Password.Trim()
        if (-not $name) { $c.ErrText.Text = 'Please give it a name.'; return }
        if ($ty -ne 'custom' -and -not $key) { $c.ErrText.Text = 'Please paste the key.'; return }
        if ($ty -eq 'custom') {
            if (-not $c.UrlBox.Text.Trim()) { $c.ErrText.Text = 'Please add the usage link.'; return }
            if (-not $c.FieldsBox.Text.Trim()) { $c.ErrText.Text = 'Please say where the token numbers are.'; return }
        }
        [void]$script:Sources.Add(@{
            Type = $ty; Name = $name; Key = $key
            Url = $c.UrlBox.Text.Trim(); Header = $c.HeaderBox.Text.Trim(); Prefix = $c.PrefixBox.Text; Fields = $c.FieldsBox.Text.Trim()
        })
        Save-Sources
        Restart-Sources
        $c.KeyBox.Password = ''; $c.UrlBox.Text = ''; $c.FieldsBox.Text = ''
        $c.ErrText.Text = "Added '$name'. It will show in the window within a few seconds."
        & $renderList
    })

    $c.BtnLog.Add_Click({
        if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" }
        else { $c.ErrText.Text = 'No log yet. It appears after the first check.' }
    })
    $c.BtnDone.Add_Click({ $dlg.Close() })

    & $renderList
    & $onType
    [void]$dlg.ShowDialog()
    Update-Sources
}

# ================= Claude Code (local log files) =================

function New-State {
    [pscustomobject]@{
        Pos = [long]0
        Seen = (New-Object 'System.Collections.Generic.HashSet[string]')
        Input = [long]0; Output = [long]0; CacheRead = [long]0; CacheWrite = [long]0
        Context = [long]0; Messages = 0; Cwd = ''
        Days = @{}; Tools = @{}; ToolNames = @{}; Warned = $false
        FirstTs = $null; LastTs = $null; Rewarm = [long]0; RewarmCount = 0
    }
}

# Reads only the NEW part of a log file since last time.
function Update-File($path) {
    $st = $script:Files[$path]
    if (-not $st) { $st = New-State; $script:Files[$path] = $st }

    $buf = $null; $read = 0
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $st.Pos) { $st = New-State; $script:Files[$path] = $st }
        if ($fs.Length -gt $st.Pos) {
            [void]$fs.Seek($st.Pos, [System.IO.SeekOrigin]::Begin)
            $len = [int]($fs.Length - $st.Pos)
            $buf = New-Object byte[] $len
            while ($read -lt $len) {
                $n = $fs.Read($buf, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
        }
    } finally { $fs.Close() }
    if ($read -le 0) { return }

    $last = -1
    for ($k = $read - 1; $k -ge 0; $k--) { if ($buf[$k] -eq 10) { $last = $k; break } }
    if ($last -lt 0) { return }   # line still being written; try again next time

    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $last + 1)
    $st.Pos += ($last + 1)

    foreach ($line in $text.Split("`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $e = $null
        try { $e = $ser.DeserializeObject($line) } catch { continue }
        if ($e -isnot [System.Collections.IDictionary]) { continue }

        if ($e.ContainsKey('cwd') -and $e['cwd']) { $st.Cwd = [string]$e['cwd'] }
        $msg = $e['message']
        if ($msg -isnot [System.Collections.IDictionary]) { continue }
        $content = $msg['content']

        if ($e['type'] -eq 'assistant') {
            if ($content -is [array]) {
                foreach ($b in $content) {
                    if ($b -is [System.Collections.IDictionary] -and $b['type'] -eq 'tool_use') {
                        $st.ToolNames[[string]$b['id']] = [string]$b['name']
                    }
                }
            }
            $u = $msg['usage']
            if ($u -isnot [System.Collections.IDictionary]) { continue }
            $key = "$($msg['id'])|$($e['requestId'])"
            if (-not $st.Seen.Add($key)) { continue }   # same reply logged twice; count once

            $i  = [long]$u['input_tokens']
            $o  = [long]$u['output_tokens']
            $cr = [long]$u['cache_read_input_tokens']
            $cw = [long]$u['cache_creation_input_tokens']
            $st.Input += $i; $st.Output += $o; $st.CacheRead += $cr; $st.CacheWrite += $cw
            $st.Messages++
            $st.Context = $i + $cr + $cw

            $tsd = $null
            try { $tsd = [datetime]::Parse([string]$e['timestamp'], [Globalization.CultureInfo]::InvariantCulture) } catch {}
            $day = ''
            if ($tsd) {
                $day = $tsd.ToString('yyyy-MM-dd')
                if (-not $st.FirstTs) { $st.FirstTs = $tsd }
                # Came back after a long break: Claude has to re-save the whole chat again
                if ($st.LastTs -and ($tsd - $st.LastTs).TotalMinutes -gt 60 -and $cw -gt 20000) {
                    $st.Rewarm += $cw; $st.RewarmCount++
                }
                $st.LastTs = $tsd
            }
            if ($day) {
                if (-not $st.Days.ContainsKey($day)) { $st.Days[$day] = [long]0 }
                $st.Days[$day] += ($i + $o + $cr + $cw)
            }
        }
        elseif ($e['type'] -eq 'user' -and $content -is [array]) {
            foreach ($b in $content) {
                if ($b -is [System.Collections.IDictionary] -and $b['type'] -eq 'tool_result') {
                    $name = $st.ToolNames[[string]$b['tool_use_id']]
                    if (-not $name) { $name = 'Other tool' }
                    $c = $b['content']; $chars = 0
                    if ($c -is [string]) { $chars = $c.Length }
                    elseif ($c -is [array]) {
                        foreach ($x in $c) {
                            if ($x -is [System.Collections.IDictionary]) {
                                if ($x['text']) { $chars += ([string]$x['text']).Length }
                                elseif ($x['type'] -eq 'image') { $chars += 6000 }
                            }
                        }
                    }
                    if (-not $st.Tools.ContainsKey($name)) { $st.Tools[$name] = [long]0 }
                    $st.Tools[$name] += [long]($chars / 4)   # rough: ~4 characters per token
                }
            }
        }
    }
}

# Turns tool names into plain words.
function Friendly($name) {
    if ($name -match 'davinci')  { return 'DaVinci Resolve' }
    if ($name -match 'Chrome')   { return 'Chrome' }
    if ($name -like 'mcp__*')    { return ($name -split '__')[1] }
    switch ($name) {
        { $_ -in 'Read', 'NotebookRead' }                       { return 'Reading files' }
        { $_ -in 'Bash', 'PowerShell', 'BashOutput' }           { return 'Running commands' }
        { $_ -in 'Grep', 'Glob', 'LS' }                         { return 'Searching files' }
        { $_ -in 'Edit', 'Write', 'MultiEdit', 'NotebookEdit' } { return 'Editing files' }
        { $_ -in 'WebFetch', 'WebSearch' }                      { return 'Web lookups' }
        { $_ -in 'Task', 'Agent' }                              { return 'Helper agents' }
    }
    return $name
}

function New-Row($label, $value, $fraction, $color, $hint) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = New-Object System.Windows.Thickness(0, 5, 0, 0)
    if ($hint) { $sp.ToolTip = $hint }
    $g = New-Object System.Windows.Controls.Grid
    $t1 = New-Object System.Windows.Controls.TextBlock
    $t1.Text = $label; $t1.Foreground = (Brush '#D6D3CF'); $t1.FontSize = 12
    $t1.TextTrimming = 'CharacterEllipsis'; $t1.Margin = New-Object System.Windows.Thickness(0, 0, 50, 0)
    $t2 = New-Object System.Windows.Controls.TextBlock
    $t2.Text = $value; $t2.Foreground = (Brush '#FFFFFF'); $t2.FontSize = 12; $t2.FontWeight = 'SemiBold'
    $t2.HorizontalAlignment = 'Right'
    [void]$g.Children.Add($t1); [void]$g.Children.Add($t2)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 4; $track.Background = (Brush '#22FFFFFF')
    $track.CornerRadius = New-Object System.Windows.CornerRadius(2)
    $track.Margin = New-Object System.Windows.Thickness(0, 3, 0, 0)
    $fill = New-Object System.Windows.Controls.Border
    $fill.HorizontalAlignment = 'Left'; $fill.Background = (Brush $color)
    $fill.CornerRadius = New-Object System.Windows.CornerRadius(2)
    if ($fraction -lt 0) { $fraction = 0 }; if ($fraction -gt 1) { $fraction = 1 }
    $fill.Width = [math]::Max(2, 270 * $fraction)
    $track.Child = $fill
    [void]$sp.Children.Add($g); [void]$sp.Children.Add($track)
    return $sp
}

# Looks at how the session is going and gives plain-English advice.
function Get-Tips($st, $ctx, $agg) {
    $tips = New-Object System.Collections.ArrayList
    $fresh = $false
    $spanH = 0
    if ($st.FirstTs -and $st.LastTs) { $spanH = ($st.LastTs - $st.FirstTs).TotalHours }
    $days = $st.Days.Count

    if ($ctx -ge 100000) {
        [void]$tips.Add(@('#F87171', "This chat is long ($(Fmt $ctx) re-read every message). Finish your current step, then move to a new session."))
        $fresh = $true
    } elseif ($ctx -ge 60000) {
        [void]$tips.Add(@('#FBBF24', 'Getting long. Plan to start a new session once this task is done.'))
    }

    # Common mistake: one session used for days, for everything
    if ($days -ge 2 -or $spanH -ge 12) {
        $label = if ($days -ge 2) { "$days days" } else { "$([math]::Round($spanH)) hours" }
        [void]$tips.Add(@('#F87171', "This session has been running for $label. Use one session per task, not one per app."))
        if ($ctx -ge 40000) { $fresh = $true }
    }

    if ($st.RewarmCount -ge 1) {
        [void]$tips.Add(@('#FBBF24', "You came back after a break $($st.RewarmCount) time(s). Each time, Claude had to re-save the whole chat ($(Fmt $st.Rewarm) so far). After a long break, start fresh instead."))
    }

    if ($st.Messages -ge 150) {
        [void]$tips.Add(@('#FBBF24', "$($st.Messages) replies in one session. Smaller sessions stay cheaper."))
    }

    $toolTotal = [long]0
    foreach ($v in $agg.Values) { $toolTotal += [long]$v }
    $topTool = $agg.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    if ($topTool -and $topTool.Value -gt 30000 -and ($topTool.Value / [math]::Max(1, $toolTotal)) -gt 0.4) {
        [void]$tips.Add(@('#FBBF24', "'$($topTool.Key)' added the most ($(Fmt $topTool.Value)). Point Claude at specific files or smaller pieces instead of whole folders."))
    }

    if ($fresh) {
        [void]$tips.Add(@('#D6D3CF', "Easy switch: click the button below, paste it here, then paste Claude's answer into a new session. (Or type /compact to shrink this one.)"))
    }
    if ($tips.Count -eq 0) {
        [void]$tips.Add(@('#4ADE80', 'Looking good. Keep one session per task.'))
    }
    return @{ Tips = $tips; Fresh = $fresh }
}

function Update-Claude {
    if (-not (Test-Path $Root)) {
        $ui.ContextText.Text = '-'
        $ui.ProjectText.Text = 'No Claude Code sessions found on this PC yet'
        return
    }
    $now = Get-Date
    $today = $now.ToString('yyyy-MM-dd')
    $all = @(Get-ChildItem -Path $Root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue)
    $recent = @($all | Where-Object { $_.LastWriteTime -gt $now.AddDays(-2) })
    foreach ($f in $recent) { try { Update-File $f.FullName } catch {} }

    $cur = $all | Where-Object { $_.FullName -notmatch '\\subagents\\' } |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cur) {
        $ui.ContextText.Text = '-'
        $ui.ProjectText.Text = 'No Claude Code sessions found on this PC yet'
        return
    }
    if (-not $script:Files[$cur.FullName]) { try { Update-File $cur.FullName } catch {} }
    $st = $script:Files[$cur.FullName]
    if (-not $st) { return }

    # --- Session name & state ---
    $proj = if ($st.Cwd) { Split-Path $st.Cwd -Leaf } else { 'Session' }
    $idle = ($now - $cur.LastWriteTime).TotalMinutes -gt 30
    $ui.ProjectText.Text = if ($idle) { "Claude Code: $proj  -  last session (idle)" } else { "Claude Code: $proj  -  active now" }

    # --- How big the conversation is ---
    $ctx = $st.Context
    $limit = if ($ctx -gt 200000) { 1000000 } else { 200000 }
    $frac = $ctx / $limit
    $ui.ContextText.Text = (Fmt $ctx)
    $trackW = $ui.ContextTrack.ActualWidth; if ($trackW -le 0) { $trackW = 270 }
    $ui.ContextFill.Width = [math]::Max(3, $trackW * [math]::Min(1, $frac))
    if ($ctx -lt 50000)      { $col = '#4ADE80'; $msg = 'Light - fine to keep going' }
    elseif ($ctx -lt 120000) { $col = '#FBBF24'; $msg = 'Getting bigger - each message costs a bit more' }
    else                     { $col = '#F87171'; $msg = 'Heavy - starting a fresh session would be cheaper' }
    $ui.ContextFill.Background = (Brush $col)
    $ui.StatusText.Foreground  = (Brush $col)
    $ui.StatusText.Text = "$msg  ($([math]::Round($frac * 100))% full)"

    # --- Breakdown for this session ---
    $total = $st.Input + $st.Output + $st.CacheRead + $st.CacheWrite
    $ui.SessionHeader.Text = "THIS SESSION SO FAR  -  $(Fmt $total) total, $($st.Messages) replies"
    $ui.BreakdownPanel.Children.Clear()
    $den = [math]::Max(1, $total)
    [void]$ui.BreakdownPanel.Children.Add((New-Row 'Re-reading the chat so far'     (Fmt $st.CacheRead)  ($st.CacheRead / $den)  '#60A5FA' 'Claude looks back over everything said so far before each reply. This is the cheap kind (about 1/10th the price).'))
    [void]$ui.BreakdownPanel.Children.Add((New-Row 'Saving the chat for re-reading' (Fmt $st.CacheWrite) ($st.CacheWrite / $den) '#A78BFA' 'New parts of the chat get stored so Claude can re-read them cheaply later.'))
    [void]$ui.BreakdownPanel.Children.Add((New-Row 'Your new messages & results'    (Fmt $st.Input)      ($st.Input / $den)      '#F472B6' 'Fresh things sent to Claude that it had not seen before.'))
    [void]$ui.BreakdownPanel.Children.Add((New-Row "Claude's replies"               (Fmt $st.Output)     ($st.Output / $den)     '#FB923C' 'What Claude wrote back, including its thinking and tool requests. The priciest kind per token.'))

    # --- What the tools added ---
    $agg = @{}
    foreach ($k in @($st.Tools.Keys)) { $fn = Friendly $k; $agg[$fn] = [long]$agg[$fn] + [long]$st.Tools[$k] }
    $ui.ToolsPanel.Children.Clear()
    $top = $agg.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
    if (-not $top) {
        Add-Note $ui.ToolsPanel 'No tools used yet' '#8A8783'
    } else {
        $maxT = [math]::Max(1, ($top | Measure-Object -Property Value -Maximum).Maximum)
        foreach ($p in $top) {
            [void]$ui.ToolsPanel.Children.Add((New-Row $p.Key (Fmt $p.Value) ($p.Value / $maxT) '#34D399' 'How much text this tool handed back to Claude (a rough guess).'))
        }
    }

    # --- Today across all Claude Code sessions ---
    $todayTotal = [long]0; $todaySessions = 0
    foreach ($s in $script:Files.Values) {
        if ($s.Days.ContainsKey($today)) { $todayTotal += $s.Days[$today]; $todaySessions++ }
    }
    $ui.TodayText.Text = "Claude Code today: $(Fmt $todayTotal) tokens across $todaySessions session(s)"

    # --- Tips ---
    $tipRes = Get-Tips $st $ctx $agg
    $ui.CoachPanel.Children.Clear()
    foreach ($t in $tipRes.Tips) { Add-Note $ui.CoachPanel ('- ' + $t[1]) $t[0] }
    $ui.BtnWrap.Visibility = if ($tipRes.Fresh) { 'Visible' } else { 'Collapsed' }

    # --- Pop-up, once per session ---
    $longRunning = ($st.Days.Count -ge 2) -and $tipRes.Fresh
    if (-not $idle -and -not $st.Warned -and ($ctx -ge $WarnAt -or $longRunning)) {
        $st.Warned = $true
        $why = "has been running for $($st.Days.Count) days and keeps getting more expensive."
        if ($ctx -ge $WarnAt) { $why = "is now re-reading about $(Fmt $ctx) tokens with every message." }
        $ans = [System.Windows.MessageBox]::Show($window,
            "Your '$proj' session $why`n`nTo save tokens, move to a new session without losing your progress:`n`n  1. Click Yes to copy a wrap-up prompt.`n  2. Paste it into THIS session and send it.`n  3. Copy Claude's answer.`n  4. Click + New, paste it in, and carry on.`n`nCopy the wrap-up prompt now?",
            'Token Monitor - time for a fresh session', 'YesNo', 'Information')
        if ([string]$ans -eq 'Yes') { Copy-WrapUp }
    }
}

function Refresh {
    if ($script:Busy) { return }
    $script:Busy = $true
    try {
        try { Update-Sources } catch { $ui.FooterText.Text = "Sources: $($_.Exception.Message)" }
        if ($script:CopiedAt -and ((Get-Date) - $script:CopiedAt).TotalSeconds -gt 10) {
            $ui.BtnWrap.Content = 'Copy wrap-up prompt'; $script:CopiedAt = $null
        }
        Update-Claude
        $ui.FooterText.Text = "Updated $((Get-Date).ToString('h:mm:ss tt'))"
    }
    catch {
        $ui.FooterText.Text = "Couldn't update: $($_.Exception.Message)"
    }
    finally { $script:Busy = $false }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Token Monitor" Width="300" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True" FontFamily="Segoe UI">
  <Border x:Name="Card" Background="#F21F1E1C" CornerRadius="12" Padding="14"
          BorderBrush="#33FFFFFF" BorderThickness="1" Cursor="SizeAll">
    <StackPanel>
      <Grid>
        <TextBlock Text="Token Monitor" Foreground="#E8E6E3" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnSmall" Content="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="10" Width="26" Height="22"
                  Background="Transparent" Foreground="#AAAAAA" BorderThickness="0" Cursor="Hand" ToolTip="Show less / show more"/>
          <Button x:Name="BtnClose" Content="&#xE8BB;" FontFamily="Segoe MDL2 Assets" FontSize="10" Width="26" Height="22"
                  Background="Transparent" Foreground="#AAAAAA" BorderThickness="0" Cursor="Hand" ToolTip="Close"/>
        </StackPanel>
      </Grid>
      <TextBlock x:Name="ProjectText" Text="Loading..." Foreground="#8A8783" FontSize="11" Margin="0,2,0,8" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="ContextText" Text="..." Foreground="#FFFFFF" FontSize="26" FontWeight="Bold"/>
      <TextBlock Text="tokens Claude re-reads with every message" Foreground="#8A8783" FontSize="11"/>
      <Border x:Name="ContextTrack" Height="8" CornerRadius="4" Background="#33FFFFFF" Margin="0,8,0,4">
        <Border x:Name="ContextFill" HorizontalAlignment="Left" CornerRadius="4" Background="#4ADE80" Width="3"/>
      </Border>
      <TextBlock x:Name="StatusText" FontSize="11" Foreground="#4ADE80" TextWrapping="Wrap"/>
      <StackPanel x:Name="Details" Margin="0,12,0,0">
        <TextBlock Text="TIPS TO SAVE TOKENS" Foreground="#8A8783" FontSize="10" FontWeight="SemiBold"/>
        <StackPanel x:Name="CoachPanel"/>
        <Button x:Name="BtnWrap" Content="Copy wrap-up prompt" Margin="0,8,0,0" Padding="8,5" FontSize="12"
                Background="#2E3A4F" Foreground="#FFFFFF" BorderBrush="#60A5FA" BorderThickness="1" Cursor="Hand"
                Visibility="Collapsed"
                ToolTip="Copies a prompt that asks Claude to write a hand-off note, so you can carry your progress into a new session."/>
        <Border Height="1" Background="#22FFFFFF" Margin="0,12,0,10"/>
        <TextBlock x:Name="SessionHeader" Text="THIS SESSION SO FAR" Foreground="#8A8783" FontSize="10" FontWeight="SemiBold"/>
        <StackPanel x:Name="BreakdownPanel"/>
        <TextBlock Text="WHAT THE TOOLS ADDED (rough guess)" Foreground="#8A8783" FontSize="10" FontWeight="SemiBold" Margin="0,12,0,0"/>
        <StackPanel x:Name="ToolsPanel"/>
        <TextBlock x:Name="TodayText" Foreground="#D6D3CF" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,0"/>
        <Border Height="1" Background="#22FFFFFF" Margin="0,12,0,10"/>
        <Grid>
          <TextBlock Text="OTHER SOURCES - TODAY" Foreground="#8A8783" FontSize="10" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <Button x:Name="BtnKey" Content="+ Add source" HorizontalAlignment="Right" Background="Transparent" Foreground="#60A5FA"
                  BorderThickness="0" FontSize="11" Cursor="Hand" Padding="4,0" ToolTip="Add or remove services to monitor"/>
        </Grid>
        <StackPanel x:Name="SourcesPanel"/>
        <TextBlock x:Name="FooterText" Foreground="#6B6864" FontSize="10" Margin="0,10,0,0" TextWrapping="Wrap"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($n in 'Card','BtnSmall','BtnClose','BtnKey','BtnWrap','CoachPanel','ProjectText','ContextText','ContextTrack','ContextFill','StatusText',
                   'Details','SessionHeader','BreakdownPanel','ToolsPanel','TodayText','SourcesPanel','FooterText') {
        $ui[$n] = $window.FindName($n)
    }

    $work = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $work.Right - 320
    $window.Top  = $work.Top + 20

    $ui.Card.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} })
    $ui.BtnClose.Add_Click({ $window.Close() })
    $ui.BtnKey.Add_Click({ Show-SourcesDialog })
    $ui.BtnWrap.Add_Click({ Copy-WrapUp })
    $ui.BtnSmall.Add_Click({
        $script:Small = -not $script:Small
        $ui.Details.Visibility = if ($script:Small) { 'Collapsed' } else { 'Visible' }
    })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
    $timer.Add_Tick({ Refresh })
    $window.Add_ContentRendered({ Refresh; $timer.Start() })
    $window.Add_Closed({
        $timer.Stop()
        if ($script:SrcJob) { try { [void]$script:SrcJob.PS.BeginStop($null, $null) } catch {} }
    })

    [void]$window.ShowDialog()
}
catch {
    [System.Windows.MessageBox]::Show("Token Monitor couldn't start:`n`n$($_.Exception.Message)", 'Token Monitor') | Out-Null
}
