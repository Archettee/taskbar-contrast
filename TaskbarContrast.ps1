#Requires -Version 5.1
<#
  TaskbarContrast.ps1  ---  透明任务栏自动黑白字
  ---------------------------------------------------------------------------
  问题：TranslucentTB 让任务栏变透明/半透明后，文字颜色仍由「Windows 模式」决定
        （浅色模式=黑字，深色模式=白字），底色一变就看不见。

  做法：任务栏的文字只出现在右侧（时钟 / 日期 / 托盘 / 输入法指示），
        所以每 1.2 秒只截取右侧 ZoneWidth 像素宽的那一块，取亮度中位数，
        再对最近 WindowSize 次采样取中位数（抗抖动），判亮则黑字、判暗则白字。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File TaskbarContrast.ps1          常驻
    ... -Once      只判断一次并生效
    ... -Probe     只打印当前判断值，不切换（诊断用）
    ... -Force light | -Force dark     强制固定模式
    ... -Stop      停止常驻实例

  日志：同目录 taskbar-contrast.log
#>
param(
    [switch]$Once,
    [switch]$Stop,
    [switch]$Probe,
    [switch]$SelfTest,
    [ValidateSet('light', 'dark')][string]$Force
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Root 'taskbar-contrast.log'
$PidFile = Join-Path $Root 'taskbar-contrast.pid'

# ----------------------------- 可调参数 ------------------------------------
$Cfg = @{
    IntervalMs  = 1200   # 采样间隔(ms)
    CooldownMs  = 10000  # 两次实际切换的最小间隔(ms)，防来回闪
    WindowSize  = 5      # 用最近几次采样取中位数（稳定但不迟钝）
    ZoneWidth   = 460    # 只采样任务栏右侧这么宽（文字所在区）
    BrightAbove = 0.58   # 平滑后亮度 >= 它 -> 黑字(浅色模式)
    DarkBelow   = 0.44   # 平滑后亮度 <= 它 -> 白字(深色模式)
    NeedSamples = 2      # 连续几次判断一致才切换
}
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Msg)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Msg
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
}

if ($Stop) {
    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($oldPid -and ($oldPid -as [int])) {
            try { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction Stop; Write-Host "已停止 (PID $oldPid)" }
            catch { Write-Host "进程 $oldPid 已不存在" }
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    else { Write-Host '没有找到正在运行的实例' }
    return
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace TC -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll", CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam,
    string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@

[void][TC.Native]::SetProcessDPIAware()

function Set-SystemTheme {
    param([bool]$Light)          # $true = 浅色模式(黑字)
    $reg  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    $want = $(if ($Light) { 1 } else { 0 })
    $cur  = (Get-ItemProperty -Path $reg -Name SystemUsesLightTheme -ErrorAction SilentlyContinue).SystemUsesLightTheme
    if ($null -eq $cur) { return $false }
    if ([int]$cur -eq $want) { return $false }

    Set-ItemProperty -Path $reg -Name SystemUsesLightTheme -Value $want -Type DWord
    $r = [IntPtr]::Zero
    [void][TC.Native]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$r)
    Start-Sleep -Milliseconds 200
    [void][TC.Native]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 2, 1000, [ref]$r)
    return $true
}

function Get-BarZone {
    <#  截取任务栏，只保留右侧"文字区"，返回 Bitmap 或 $null  #>
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $b = $screen.Bounds
    $w = $screen.WorkingArea

    if (($b.Height - $w.Height) -ge 8) {            # 底部任务栏
        $top = $w.Bottom + 3
        $h   = $b.Bottom - $top - 3
    }
    elseif (($w.Top - $b.Top) -ge 8) {              # 顶部任务栏
        $top = $b.Top + 3
        $h   = $w.Top - $top - 3
    }
    else {                                          # 自动隐藏 / 竖排：取底部默认高度
        $h   = 42
        $top = $b.Bottom - $h - 3
    }
    if ($h -lt 8) { return $null }

    # 文字只在右侧：时钟 / 日期 / 托盘图标 / 输入法指示
    $zoneW = [math]::Min($Cfg.ZoneWidth, [int]($b.Width * 0.4))
    $x     = $b.Right - $zoneW - 4
    if ($x -lt $b.Left) { $x = $b.Left }

    $bmp = New-Object System.Drawing.Bitmap($zoneW, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($x, $top, 0, 0, (New-Object System.Drawing.Size($zoneW, $h))) }
    catch { $g.Dispose(); $bmp.Dispose(); return $null }
    $g.Dispose()
    return $bmp
}

function Get-LumaMedian {
    <#  返回该位图亮度的中位数 (0..1)  #>
    param([System.Drawing.Bitmap]$Bmp)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Bmp.Width, $Bmp.Height)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $hist  = New-Object 'int[]' 256
    $total = 0
    try {
        $stride = $data.Stride
        $bytes  = New-Object 'byte[]' ($stride * $data.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)

        for ($yy = 0; $yy -lt $data.Height; $yy += 2) {
            $row = $yy * $stride
            for ($xx = 0; $xx -lt $data.Width; $xx += 2) {
                $i = $row + ($xx -shl 2)      # 内存顺序 B G R A
                $l = 0.0722 * $bytes[$i] + 0.7152 * $bytes[$i + 1] + 0.2126 * $bytes[$i + 2]
                $idx = [int]$l
                if ($idx -gt 255) { $idx = 255 }
                if ($idx -lt 0)   { $idx = 0 }
                $hist[$idx]++
                $total++
            }
        }
    }
    finally { $Bmp.UnlockBits($data) }

    if ($total -eq 0) { return $null }
    $target = [int][math]::Ceiling($total / 2)
    $cum = 0
    for ($i = 0; $i -lt 256; $i++) {
        $cum += $hist[$i]
        if ($cum -ge $target) { return $i / 255.0 }
    }
    return 1.0
}

function Measure-Zone {
    $bmp = Get-BarZone
    if (-not $bmp) { return $null }
    $m = Get-LumaMedian -Bmp $bmp
    $bmp.Dispose()
    return $m
}

function Get-Median([double[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $s = $Values | Sort-Object
    if ($s.Count % 2 -eq 1) { return [double]$s[[int]($s.Count / 2)] }
    return ([double]$s[$s.Count / 2 - 1] + [double]$s[$s.Count / 2]) / 2.0
}

# ------------------------------ 自检 ----------------------------------------
if ($SelfTest) {
    foreach ($l in 20, 60, 100, 130, 160, 200, 240) {
        $b = New-Object System.Drawing.Bitmap(200, 40)
        $g = [System.Drawing.Graphics]::FromImage($b)
        $g.Clear([System.Drawing.Color]::FromArgb($l, $l, $l)); $g.Dispose()
        $m = Get-LumaMedian -Bmp $b
        $b.Dispose()
        $v = if ($m -ge $Cfg.BrightAbove) { '黑字(浅色模式)' } elseif ($m -le $Cfg.DarkBelow) { '白字(深色模式)' } else { '维持现状' }
        "底色 {0,3}  ->  中位数={1:N3}  ->  {2}" -f $l, $m, $v
    }
    return
}

# ------------------------------ 强制模式 ------------------------------------
if ($Force) {
    $light = ($Force -eq 'light')
    $changed = Set-SystemTheme -Light $light
    Write-Log ("FORCE {0} | changed={1}" -f $Force, $changed)
    $name = $(if ($light) { '浅色模式，黑字' } else { '深色模式，白字' })
    if ($changed) { Write-Host "已切换：$name" } else { Write-Host "已经是：$name" }
    return
}

# ------------------------------ 诊断模式 ------------------------------------
if ($Probe) {
    while ($true) {
        $m = Measure-Zone
        $t = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').SystemUsesLightTheme
        if ($null -ne $m) {
            $verdict = if ($m -ge $Cfg.BrightAbove) { '黑字' } elseif ($m -le $Cfg.DarkBelow) { '白字' } else { '维持' }
            "{0}  文字区亮度={1:N3}  当前模式={2}  判断={3}" -f (Get-Date -Format 'HH:mm:ss'), $m, $(if ($t -eq 1) { '浅色/黑字' } else { '深色/白字' }), $verdict
        }
        Start-Sleep -Milliseconds $Cfg.IntervalMs
    }
}

# ------------------------------ 单例互斥 ------------------------------------
$mutex = $null
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\TaskbarContrastWatcher')
    if (-not $mutex.WaitOne(0)) { Write-Log 'already running, exit'; return }
}
catch { }

try {
    Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII

    if ($Once) {
        $m = Measure-Zone
        if ($null -eq $m) { Write-Host '采样失败'; return }
        $light = $m -ge 0.5
        $changed = Set-SystemTheme -Light $light
        Write-Host ("文字区亮度={0:N3} -> {1} (changed={2})" -f $m, $(if ($light) { '浅色模式/黑字' } else { '深色模式/白字' }), $changed)
        Write-Log ("ONCE median={0:N3} -> {1} changed={2}" -f $m, $(if ($light) { 'light' } else { 'dark' }), $changed)
        return
    }

    Write-Log '===== watcher started ====='
    $samples  = New-Object System.Collections.Generic.List[double]
    $dec      = $null
    $pending  = 0
    $lastFlip = [DateTime]::MinValue

    while ($true) {
        try {
            $m = Measure-Zone
            if ($null -ne $m) {
                $samples.Add($m)
                while ($samples.Count -gt $Cfg.WindowSize) { $samples.RemoveAt(0) }
                $smooth = Get-Median $samples.ToArray()

                $want = $dec
                if     ($smooth -ge $Cfg.BrightAbove) { $want = 'light' }
                elseif ($smooth -le $Cfg.DarkBelow)   { $want = 'dark' }

                if ($want -ne $dec) { $dec = $want; $pending = 1 }
                elseif ($pending -lt $Cfg.NeedSamples) { $pending++ }

                $elapsed = ([DateTime]::Now - $lastFlip).TotalMilliseconds
                if ($dec -and $pending -ge $Cfg.NeedSamples -and
                    ($elapsed -ge $Cfg.CooldownMs -or $lastFlip -eq [DateTime]::MinValue)) {

                    if (Set-SystemTheme -Light ($dec -eq 'light')) {
                        $lastFlip = [DateTime]::Now
                        $pending  = 0
                        Write-Log ("SWITCH -> {0}  median={1:N3} smooth={2:N3} n={3}" -f `
                            $dec, $m, $smooth, $samples.Count)
                    }
                }
            }
        }
        catch { Write-Log ("ERROR: " + $_.Exception.Message) }

        try {
            if ((Test-Path -LiteralPath $LogFile) -and
                ((Get-Item -LiteralPath $LogFile).Length -gt 512KB)) {
                Move-Item -LiteralPath $LogFile -Destination ($LogFile + '.old') -Force
            }
        }
        catch { }

        Start-Sleep -Milliseconds $Cfg.IntervalMs
    }
}
finally {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if ($mutex) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
}
