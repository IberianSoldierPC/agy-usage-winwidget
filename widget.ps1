#requires -version 5
<#
  agy-usage-winwidget - a floating window + tray icon showing current Antigravity quota.
  Data comes from `agy -p "/usage" --output-format json`. No third-party dependencies.
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace Win32 -Name IconUtil -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(System.IntPtr hIcon);
'@

$WidgetVersion = '1.0.1'
$script:Dot    = [char]0x00B7

$script:Root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:Root 'config.json'

$ErrorActionPreference = 'Stop'
$ConfirmPreference     = 'None'

trap {
    try {
        "$(Get-Date -Format s)`tstart: $($_.Exception.Message)`t$($_.InvocationInfo.PositionMessage)" |
            Out-File (Join-Path $script:Root 'widget-error.log') -Append -Encoding utf8
    } catch {}
    exit 1
}

# One instance per user
$isNew = $false
try {
    $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\agy-usage-winwidget', [ref]$isNew)
} catch { exit 0 }
if (-not $isNew) { exit 0 }

# Fix TEMP path for accented profiles
if ([string]::IsNullOrEmpty($env:TEMP) -or -not (Test-Path -LiteralPath $env:TEMP)) {
    $fixTemp = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp'
    try { New-Item -ItemType Directory -Path $fixTemp -Force | Out-Null } catch {}
    if (Test-Path -LiteralPath $fixTemp) { $env:TEMP = $fixTemp; $env:TMP = $fixTemp }
}

try { Remove-Item (Join-Path $env:TEMP 'agyw-*') -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue } catch {}

# ================================================================ CONFIG ====

$DefaultConfig = [ordered]@{
    refreshSeconds       = 10
    usageIntervalSeconds = 120
    expanded             = $false
    scale                = 1.35
    warnPercent          = 60
    critPercent          = 85
    showRemaining        = $false # false: shows % used (fills up); true: shows % remaining
    opacity              = 1.0
    topmost              = $false
    left                 = $null
    top                  = $null
}

function Load-Config {
    $cfg = [ordered]@{}
    foreach ($k in $DefaultConfig.Keys) { $cfg[$k] = $DefaultConfig[$k] }
    if (Test-Path $script:ConfigPath) {
        try {
            $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $raw.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        } catch {}
    }
    return $cfg
}

function Save-Config($cfg) {
    try {
        $out = [ordered]@{}
        if (Test-Path $script:ConfigPath) {
            try {
                $raw = Get-Content $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $raw.PSObject.Properties) { $out[$p.Name] = $p.Value }
            } catch {}
        }
        foreach ($k in $cfg.Keys) { $out[$k] = $cfg[$k] }
        [PSCustomObject]$out | ConvertTo-Json -Depth 3 | Out-File $script:ConfigPath -Encoding utf8
    } catch {}
}

$script:Cfg = Load-Config

# ================================================================ PALETTE ====

$Palette = @{
    ok   = @{ Wpf = '#FF4ADE80'; Drawing = [System.Drawing.Color]::FromArgb(74,222,128) }
    warn = @{ Wpf = '#FFFBBF24'; Drawing = [System.Drawing.Color]::FromArgb(251,191,36) }
    crit = @{ Wpf = '#FFF87171'; Drawing = [System.Drawing.Color]::FromArgb(248,113,113) }
    dead = @{ Wpf = '#FF6B7280'; Drawing = [System.Drawing.Color]::FromArgb(107,114,128) }
}

function Get-Level([double]$pct) {
    # pct here is percent used (100 - remaining)
    if ($pct -ge $script:Cfg.critPercent) { return 'crit' }
    if ($pct -ge $script:Cfg.warnPercent) { return 'warn' }
    return 'ok'
}

# ================================================================ USAGE PROBE ====

$script:AgyExe     = $null
try { $script:AgyExe = (Get-Command agy -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source } catch {
    [System.Windows.MessageBox]::Show(
        "Cannot find 'agy' in PATH. Make sure Antigravity CLI is installed.",
        'agy-usage-winwidget', 'OK', 'Error') | Out-Null
    exit 1
}

$script:UsageProc  = $null
$script:UsageFile  = Join-Path $env:TEMP "agyw-usage-$PID.txt"
$script:UsageErr   = Join-Path $env:TEMP "agyw-usage-err-$PID.txt"
$script:Usage      = $null
$script:UsageAt    = [datetime]::MinValue
$script:UsageTry   = [datetime]::MinValue
$script:UsageDesc  = ''

# History: an array of @{ time; gemini; thirdp } samples
$script:History    = [System.Collections.ArrayList]@()

function Start-UsageProbe {
    if ($script:UsageProc -and -not $script:UsageProc.HasExited) { return }
    $script:UsageTry = Get-Date
    try {
        $script:UsageProc = Start-Process -FilePath $script:AgyExe `
            -ArgumentList '-p','/usage','--output-format','json' `
            -RedirectStandardOutput $script:UsageFile `
            -RedirectStandardError $script:UsageErr `
            -NoNewWindow -PassThru
    } catch {
        $script:UsageProc = $null
    }
}

function Collect-UsageProbe {
    if (-not $script:UsageProc -or -not $script:UsageProc.HasExited) { return }
    $script:UsageProc = $null
    if (-not (Test-Path $script:UsageFile)) { return }
    try {
        $text = [System.IO.File]::ReadAllText($script:UsageFile, [System.Text.Encoding]::UTF8)
    } catch { return }

    try {
        $json = $text | ConvertFrom-Json
    } catch { return }

    if (-not $json.command -or -not $json.command.data) { return }
    $data = $json.command.data

    $u = @{
        description = [string]$data.description
        groups      = @()
    }

    foreach ($g in $data.groups) {
        $group = @{
            name        = [string]$g.name
            description = [string]$g.description
            buckets     = @()
        }
        foreach ($b in $g.buckets) {
            $group.buckets += @{
                id                 = [string]$b.id
                name               = [string]$b.name
                description        = [string]$b.description
                window             = [string]$b.window
                remaining_fraction = [double]$b.remaining_fraction
                reset_time         = [string]$b.reset_time
            }
        }
        $u.groups += $group
    }

    $script:Usage     = $u
    $script:UsageAt   = Get-Date
    $script:UsageDesc = $u.description

    # Add history sample
    $sample = @{ time = Get-Date }
    foreach ($g in $u.groups) {
        foreach ($b in $g.buckets) {
            $used = [math]::Round((1 - $b.remaining_fraction) * 100, 1)
            if ($b.id -eq 'gemini-weekly') { $sample.gemini = $used }
            if ($b.id -eq '3p-weekly')     { $sample.thirdp = $used }
        }
    }
    [void]$script:History.Add($sample)
    # Keep last 24 hours
    $cutoff = (Get-Date).AddHours(-24)
    while ($script:History.Count -gt 0 -and $script:History[0].time -lt $cutoff) {
        $script:History.RemoveAt(0)
    }
}

# ================================================================ FORMAT ====

function Format-Span([datetime]$endUtc) {
    $span = $endUtc.ToUniversalTime() - [datetime]::UtcNow
    if ($span.TotalSeconds -le 0) { return $null }
    if ($span.TotalHours -ge 24) { return '{0}d {1}h' -f $span.Days, $span.Hours }
    if ($span.TotalHours -ge 1)  { return '{0}h {1}m' -f [math]::Floor($span.TotalHours), $span.Minutes }
    return '{0}m' -f $span.Minutes
}

# ================================================================ WINDOW ====

$xamlText = Get-Content -Raw -Encoding UTF8 (Join-Path $script:Root 'widget.xaml')
[xml]$xaml = $xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

$UI = @{}
foreach ($n in @('BtnRefresh','BtnToggle','BtnHide','BtnExit',
                 'GeminiPct','GeminiDesc','BarGemini','GeminiReset',
                 'ThirdPct','ThirdDesc','BarThird','ThirdReset',
                 'Details','LineDescription','GeminiModels','GeminiBucketDesc',
                 'ThirdModels','ThirdBucketDesc',
                 'HistChart','HistCaption','LineVersion',
                 'LineAccount','LineStamp')) {
    $UI[$n] = $win.FindName($n)
}

$win.Opacity = [double]$script:Cfg.opacity
$win.Topmost = [bool]$script:Cfg.topmost
$BarWidth    = 248.0

function Set-Scale([double]$k) {
    if ($k -lt 0.6) { $k = 0.6 }
    if ($k -gt 4.0) { $k = 4.0 }
    $win.Content.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $k, $k
}
Set-Scale ([double]$script:Cfg.scale)

$win.WindowStartupLocation = 'Manual'
if ($null -ne $script:Cfg.left -and $null -ne $script:Cfg.top) {
    $win.Left = [double]$script:Cfg.left
    $win.Top  = [double]$script:Cfg.top
} else {
    $area = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $area.Right - 292
    $win.Top  = $area.Top + 20
}

# ================================================================ TRAY ====

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Text    = 'agy-usage-winwidget'
$notify.Visible = $true

$script:LastIconHandle = [IntPtr]::Zero

function Set-TrayIcon([string]$text, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap 32,32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode     = 'AntiAlias'
        $g.TextRenderingHint = 'ClearTypeGridFit'
        $g.Clear([System.Drawing.Color]::Transparent)

        # Hexagonal shape (approximation with a filled polygon)
        $cx = 16; $cy = 16; $r = 15
        $pts = @()
        for ($i = 0; $i -lt 6; $i++) {
            $angle = [math]::PI / 3 * $i - [math]::PI / 6
            $pts += New-Object System.Drawing.PointF (($cx + $r * [math]::Cos($angle)), ($cy + $r * [math]::Sin($angle)))
        }
        $brush = New-Object System.Drawing.SolidBrush $color
        $g.FillPolygon($brush, $pts)
        $brush.Dispose()

        if ($text.Length -ge 3) { $size = 13 } else { $size = 16 }
        $font = New-Object System.Drawing.Font 'Segoe UI', $size, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $fmt  = New-Object System.Drawing.StringFormat
        $fmt.Alignment     = 'Center'
        $fmt.LineAlignment = 'Center'
        $rect = New-Object System.Drawing.RectangleF 0,0,32,32
        $g.DrawString($text, $font, [System.Drawing.Brushes]::Black, $rect, $fmt)
        $font.Dispose(); $fmt.Dispose()
    } finally {
        $g.Dispose()
    }
    $h = $bmp.GetHicon()
    $notify.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:LastIconHandle -ne [IntPtr]::Zero) {
        [Win32.IconUtil]::DestroyIcon($script:LastIconHandle) | Out-Null
    }
    $script:LastIconHandle = $h
    $bmp.Dispose()
}

function Update-TrayTooltip {
    $lines = @('Antigravity Usage')
    if ($script:Usage) {
        foreach ($g in $script:Usage.groups) {
            foreach ($b in $g.buckets) {
                $pctRemaining = [math]::Round($b.remaining_fraction * 100)
                $pctUsed      = 100 - $pctRemaining
                $lines += "$($g.name): ${pctUsed}% used (${pctRemaining}% left)"
            }
        }
    }
    $tip = ($lines -join "`n")
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $notify.Text = $tip
}

# ================================================================ HISTORY CHART ====

function Draw-HistChart {
    $UI.HistChart.Children.Clear()
    if ($script:History.Count -lt 2) {
        $UI.HistCaption.Text = 'Collecting data...'
        return
    }

    $w = $UI.HistChart.ActualWidth
    if ($w -le 0) { $w = 248 }
    $h = $UI.HistChart.ActualHeight
    if ($h -le 0) { $h = 44 }

    $count = $script:History.Count
    $step  = $w / [math]::Max($count - 1, 1)

    # Draw gemini line
    $geminiPts = New-Object System.Windows.Media.PointCollection
    $thirdPts  = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $count; $i++) {
        $x = $i * $step
        $s = $script:History[$i]
        $gy = if ($null -ne $s.gemini) { $h - ($s.gemini / 100.0 * $h) } else { $h }
        $ty = if ($null -ne $s.thirdp) { $h - ($s.thirdp / 100.0 * $h) } else { $h }
        $geminiPts.Add((New-Object System.Windows.Point $x, $gy))
        $thirdPts.Add((New-Object System.Windows.Point $x, $ty))
    }

    $geminiLine = New-Object System.Windows.Shapes.Polyline
    $geminiLine.Points = $geminiPts
    $geminiLine.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF4ADE80'))
    $geminiLine.StrokeThickness = 1.5
    $geminiLine.IsHitTestVisible = $false
    [void]$UI.HistChart.Children.Add($geminiLine)

    $thirdLine = New-Object System.Windows.Shapes.Polyline
    $thirdLine.Points = $thirdPts
    $thirdLine.Stroke = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString('#FF60A5FA'))
    $thirdLine.StrokeThickness = 1.5
    $thirdLine.IsHitTestVisible = $false
    [void]$UI.HistChart.Children.Add($thirdLine)

    # Legend
    $latest = $script:History[$count - 1]
    $parts = @()
    if ($null -ne $latest.gemini) { $parts += "Gemini: $($latest.gemini)%" }
    if ($null -ne $latest.thirdp) { $parts += "Claude/GPT: $($latest.thirdp)%" }
    $UI.HistCaption.Text = ($parts -join " $script:Dot ") + " $script:Dot $count samples"
}

# ================================================================ UPDATE ====

function Update-Widget {
    $now = Get-Date

    # Start a new probe if enough time passed
    $elapsed = ($now - $script:UsageTry).TotalSeconds
    if ($elapsed -ge $script:Cfg.usageIntervalSeconds -or $null -eq $script:Usage) {
        Start-UsageProbe
    }

    Collect-UsageProbe

    $u = $script:Usage

    # -- Gemini bar --
    $geminiUsed = $null
    $geminiRemaining = $null
    $geminiReset = $null
    $geminiBucketDesc = ''
    $geminiGroupDesc = ''

    $thirdUsed = $null
    $thirdRemaining = $null
    $thirdReset = $null
    $thirdBucketDesc = ''
    $thirdGroupDesc = ''

    if ($u) {
        foreach ($g in $u.groups) {
            foreach ($b in $g.buckets) {
                $pctRemaining = [math]::Round($b.remaining_fraction * 100)
                $pctUsed      = 100 - $pctRemaining

                if ($b.id -eq 'gemini-weekly') {
                    $geminiUsed      = $pctUsed
                    $geminiRemaining = $pctRemaining
                    $geminiReset     = $b.reset_time
                    $geminiBucketDesc = $b.description
                    $geminiGroupDesc  = $g.description
                }
                if ($b.id -eq '3p-weekly') {
                    $thirdUsed      = $pctUsed
                    $thirdRemaining = $pctRemaining
                    $thirdReset     = $b.reset_time
                    $thirdBucketDesc = $b.description
                    $thirdGroupDesc  = $g.description
                }
            }
        }
    }

    $useRemaining = [bool]$script:Cfg.showRemaining

    # Gemini
    if ($null -ne $geminiUsed) {
        $geminiDisplay = if ($useRemaining) { $geminiRemaining } else { $geminiUsed }
        $UI.GeminiPct.Text = [string]$geminiDisplay
        $level = Get-Level $geminiUsed
        $UI.BarGemini.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($Palette[$level].Wpf))
        $UI.BarGemini.Width = [math]::Min([math]::Max(($geminiDisplay / 100.0) * $BarWidth, 0), $BarWidth)

        $resetSpan = $null
        if ($geminiReset) {
            try {
                $resetDt = [datetime]::Parse($geminiReset).ToUniversalTime()
                $resetSpan = Format-Span $resetDt
            } catch {}
        }
        if ($geminiUsed -ge 100) {
            $UI.GeminiReset.Text = if ($resetSpan) { "limit reached $script:Dot resets in $resetSpan" } else { "limit reached" }
        } elseif ($resetSpan) {
            $UI.GeminiReset.Text = "resets in $resetSpan"
        } else {
            $UI.GeminiReset.Text = if ($useRemaining) { "${geminiRemaining}% left" } else { "${geminiUsed}% used" }
        }
        $UI.GeminiDesc.Text = "Flash, Pro"
    } else {
        $UI.GeminiPct.Text  = '--'
        $UI.GeminiReset.Text = 'loading...'
    }

    # Third-party (Claude & GPT)
    if ($null -ne $thirdUsed) {
        $thirdDisplay = if ($useRemaining) { $thirdRemaining } else { $thirdUsed }
        $UI.ThirdPct.Text = [string]$thirdDisplay
        $level = Get-Level $thirdUsed
        $UI.BarThird.Background = New-Object System.Windows.Media.SolidColorBrush(
            [System.Windows.Media.ColorConverter]::ConvertFromString($Palette[$level].Wpf))
        $UI.BarThird.Width = [math]::Min([math]::Max(($thirdDisplay / 100.0) * $BarWidth, 0), $BarWidth)

        $resetSpan = $null
        if ($thirdReset) {
            try {
                $resetDt = [datetime]::Parse($thirdReset).ToUniversalTime()
                $resetSpan = Format-Span $resetDt
            } catch {}
        }
        if ($thirdUsed -ge 100) {
            $UI.ThirdReset.Text = if ($resetSpan) { "limit reached $script:Dot resets in $resetSpan" } else { "limit reached" }
        } elseif ($resetSpan) {
            $UI.ThirdReset.Text = "resets in $resetSpan"
        } else {
            $UI.ThirdReset.Text = if ($useRemaining) { "${thirdRemaining}% left" } else { "${thirdUsed}% used" }
        }
        $UI.ThirdDesc.Text = "Opus, Sonnet, GPT"
    } else {
        $UI.ThirdPct.Text  = '--'
        $UI.ThirdReset.Text = 'loading...'
    }

    # Tray icon: show primary bottleneck (highest usage in default mode, lowest remaining in remaining mode)
    $trayPct  = '--'
    $trayLvl  = 'dead'
    if ($useRemaining) {
        if ($null -ne $geminiRemaining -and $null -ne $thirdRemaining) {
            $lowest = [math]::Min($geminiRemaining, $thirdRemaining)
            $trayPct = [string]$lowest
            $trayLvl = Get-Level (100 - $lowest)
        } elseif ($null -ne $thirdRemaining) {
            $trayPct = [string]$thirdRemaining
            $trayLvl = Get-Level $thirdUsed
        } elseif ($null -ne $geminiRemaining) {
            $trayPct = [string]$geminiRemaining
            $trayLvl = Get-Level $geminiUsed
        }
    } else {
        if ($null -ne $geminiUsed -and $null -ne $thirdUsed) {
            $highest = [math]::Max($geminiUsed, $thirdUsed)
            $trayPct = [string]$highest
            $trayLvl = Get-Level $highest
        } elseif ($null -ne $thirdUsed) {
            $trayPct = [string]$thirdUsed
            $trayLvl = Get-Level $thirdUsed
        } elseif ($null -ne $geminiUsed) {
            $trayPct = [string]$geminiUsed
            $trayLvl = Get-Level $geminiUsed
        }
    }
    Set-TrayIcon $trayPct $Palette[$trayLvl].Drawing
    Update-TrayTooltip

    # Details
    if ($u) {
        $UI.LineDescription.Text = $u.description
        $UI.GeminiModels.Text    = $geminiGroupDesc
        $UI.GeminiBucketDesc.Text = $geminiBucketDesc
        $UI.ThirdModels.Text     = $thirdGroupDesc
        $UI.ThirdBucketDesc.Text = $thirdBucketDesc
    }

    # History chart
    Draw-HistChart

    # Version & timestamp
    $UI.LineVersion.Text = "agy-usage-winwidget v$WidgetVersion"
    $UI.LineAccount.Text = 'Antigravity'
    $UI.LineStamp.Text   = $now.ToString('HH:mm')
}

# ================================================================ EVENTS ====

$border = $win.Content
$border.add_MouseLeftButtonDown({
    try {
        $win.DragMove()
        $script:Cfg.left = [math]::Round($win.Left)
        $script:Cfg.top  = [math]::Round($win.Top)
        Save-Config $script:Cfg
    } catch {}
})

$UI.BtnToggle.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    if ($UI.Details.Visibility -eq 'Visible') {
        $UI.Details.Visibility = 'Collapsed'
        $UI.BtnToggle.Text     = [char]0x25BE
        $script:Cfg.expanded   = $false
    } else {
        $UI.Details.Visibility = 'Visible'
        $UI.BtnToggle.Text     = [char]0x25B4
        $script:Cfg.expanded   = $true
    }
    Save-Config $script:Cfg
})

$UI.BtnRefresh.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:UsageTry = [datetime]::MinValue
    Update-Widget
})

$UI.BtnHide.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $win.Hide()
})

$UI.BtnExit.add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    try {
        $script:Cfg.left = [math]::Round($win.Left)
        $script:Cfg.top  = [math]::Round($win.Top)
        Save-Config $script:Cfg
    } catch {}
    try { Remove-Item $script:UsageFile -ErrorAction Stop } catch {}
    try { Remove-Item $script:UsageErr  -ErrorAction Stop } catch {}
    $notify.Visible = $false
    $notify.Dispose()
    if ($script:LastIconHandle -ne [IntPtr]::Zero) {
        [Win32.IconUtil]::DestroyIcon($script:LastIconHandle) | Out-Null
    }
    $win.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# Tray icon: click to show/hide window
$notify.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        if ($win.IsVisible) { $win.Hide() }
        else {
            $win.Show()
            $win.Activate()
        }
    }
})

# Right-click tray menu
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$itemShow = $trayMenu.Items.Add('Show / Hide')
$itemShow.add_Click({ if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() } })
$itemRefresh = $trayMenu.Items.Add('Refresh Now')
$itemRefresh.add_Click({ $script:UsageTry = [datetime]::MinValue; Update-Widget })
$trayMenu.Items.Add('-')
$itemExit = $trayMenu.Items.Add('Exit')
$itemExit.add_Click({
    try { $script:Cfg.left = [math]::Round($win.Left); $script:Cfg.top = [math]::Round($win.Top); Save-Config $script:Cfg } catch {}
    $notify.Visible = $false; $notify.Dispose()
    if ($script:LastIconHandle -ne [IntPtr]::Zero) { [Win32.IconUtil]::DestroyIcon($script:LastIconHandle) | Out-Null }
    $win.Close()
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})
$notify.ContextMenuStrip = $trayMenu

# Mouse wheel to resize
$border.add_MouseWheel({
    param($s, $e)
    $delta = $e.Delta / 1200.0
    $script:Cfg.scale = [math]::Round($script:Cfg.scale + $delta, 2)
    Set-Scale $script:Cfg.scale
    Save-Config $script:Cfg
})

# Expand if config says so
if ($script:Cfg.expanded) {
    $UI.Details.Visibility = 'Visible'
    $UI.BtnToggle.Text     = [char]0x25B4
}

# Error handler: don't crash
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
    param($s, $e)
    $e.Handled = $true
    try {
        "$(Get-Date -Format s)`tui: $($e.Exception.Message)" |
            Out-File (Join-Path $script:Root 'widget-error.log') -Append -Encoding utf8
    } catch {}
})

$win.Show()
Update-Widget

# Timer for regular updates
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([double]$script:Cfg.refreshSeconds)
$timer.add_Tick({
    try { Update-Widget } catch {
        $UI.LineStamp.Text = 'error'
        try {
            "$(Get-Date -Format s)`t$($_.Exception.Message)`t$($_.InvocationInfo.PositionMessage)" |
                Out-File (Join-Path $script:Root 'widget-error.log') -Append -Encoding utf8
        } catch {}
    }
})
$timer.Start()

# Quick pick-up after probe finishes
$kick = New-Object System.Windows.Threading.DispatcherTimer
$kick.Interval = [TimeSpan]::FromSeconds(1)
$kick.add_Tick({
    Collect-UsageProbe
    if (-not $script:UsageProc) {
        $kick.Stop()
        try { Update-Widget } catch {}
    }
})
$kick.Start()

[System.Windows.Threading.Dispatcher]::Run()
