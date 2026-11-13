#Requires -Version 5.1
<#
  TaskbarContrast.ps1  ---  透明任务栏自动黑白字
  ---------------------------------------------------------------------------
  问题：TranslucentTB 让任务栏变透明/半透明后，文字颜色仍由「Windows 模式」决定
        （浅色模式=黑字，深色模式=白字），底色一变就看不见。

  做法：每隔 1.2 秒截取"任务栏这一条"本身，取亮度中位数（不受图标文字干扰），
        中位数偏亮 → 切浅色模式（黑字）；偏暗 → 切深色模式（白字）。
        带死区(0.45~0.55)+EMA 平滑+冷却时间，避免来回闪烁。

  只改 SystemUsesLightTheme（任务栏 / 开始菜单 / 通知中心），
  不改 AppsUseLightTheme，所有应用配色不受影响。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File TaskbarContrast.ps1          常驻
    ... -Once      只判断一次并生效
    ... -Force light | -Force dark     强制固定模式
    ... -Stop      停止常驻实例

  日志：同目录 taskbar-contrast.log
#>
param(
    [switch]$Once,
    [switch]$Stop,
    [ValidateSet('light', 'dark')][string]$Force
)

$ErrorActionPreference = 'Stop'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Root 'taskbar-contrast.log'
$PidFile = Join-Path $Root 'taskbar-contrast.pid'

# ----------------------------- 可调参数 ------------------------------------
$Cfg = @{
    IntervalMs  = 1200   # 采样间隔(ms)
    CooldownMs  = 6000   # 两次实际切换的最小间隔(ms)
    BrightAbove = 0.55   # 亮度中位数高于它 -> 用黑字(浅色模式)
    DarkBelow   = 0.45   # 亮度中位数低于它 -> 用白字(深色模式)
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

function Get-TaskbarBand {
    <#  截取任务栏那一条(不含 2px 边缘)，返回 Bitmap 或 $null  #>
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $b = $screen.Bounds
    $w = $screen.WorkingArea

    if (($b.Height - $w.Height) -ge 8) {            # 底部任务栏
        $top = $w.Bottom + 2
        $h   = $b.Bottom - $top - 2
    }
    elseif (($w.Top - $b.Top) -ge 8) {              # 顶部任务栏
        $top = $b.Top + 2
        $h   = $w.Top - $top - 2
    }
    else {                                          # 自动隐藏 / 竖排：取底部默认高度
        $h   = 44
        $top = $b.Bottom - $h - 2
    }
    if ($h -lt 8) { return $null }

    $x  = $b.Left + 2
    $wd = $b.Width - 4
    if ($wd -lt 8) { return $null }

    $bmp = New-Object System.Drawing.Bitmap($wd, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($x, $top, 0, 0, (New-Object System.Drawing.Size($wd, $h))) }
    catch { $g.Dispose(); $bmp.Dispose(); return $null }
    $g.Dispose()
    return $bmp
}

function Get-LumaStats {
    <#  返回 @{ P25; P50; P75; Mean }，亮度范围 0..1  #>
    param([System.Drawing.Bitmap]$Bmp)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Bmp.Width, $Bmp.Height)
    $data = $Bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
                          [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $hist  = New-Object 'int[]' 256
    $total = 0
    $sum   = 0.0
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
                $sum += $l
                $total++
            }
        }
    }
    finally { $Bmp.UnlockBits($data) }

    if ($total -eq 0) { return $null }

    $P = {
        param($pct)
        $target = [int][math]::Ceiling($total * $pct / 100.0)
        $cum = 0
        for ($i = 0; $i -lt 256; $i++) {
            $cum += $hist[$i]
            if ($cum -ge $target) { return $i / 255.0 }
        }
        return 1.0
    }
    return @{
        P25  = (& $P 25)
        P50  = (& $P 50)
        P75  = (& $P 75)
        Mean = ($sum / $total / 255.0)
    }
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
        $bmp = Get-TaskbarBand
        if (-not $bmp) { Write-Host '采样失败'; return }
        $st = Get-LumaStats -Bmp $bmp
        $bmp.Dispose()
        if (-not $st) { Write-Host '采样失败'; return }
        $light = $st.P50 -ge 0.5
        $changed = Set-SystemTheme -Light $light
        Write-Host ("任务栏亮度: P25={0:N3} 中位数={1:N3} P75={2:N3} -> {3} (changed={4})" -f `
            $st.P25, $st.P50, $st.P75, $(if ($light) { '浅色模式/黑字' } else { '深色模式/白字' }), $changed)
        Write-Log ("ONCE P50={0:N3} -> {1} changed={2}" -f $st.P50, $(if ($light) { 'light' } else { 'dark' }), $changed)
        return
    }

    Write-Log '===== watcher started ====='
    $ema      = $null
    $dec      = $null
    $pending  = 0
    $lastFlip = [DateTime]::MinValue

    while ($true) {
        try {
            $bmp = Get-TaskbarBand
            if ($bmp) {
                $st = Get-LumaStats -Bmp $bmp
                $bmp.Dispose()

                if ($st) {
                    if ($null -eq $ema) { $ema = $st.P50 }
                    else { $ema = 0.6 * $ema + 0.4 * $st.P50 }

                    $want = $dec
                    if     ($ema -ge $Cfg.BrightAbove) { $want = 'light' }
                    elseif ($ema -le $Cfg.DarkBelow)   { $want = 'dark' }

                    if ($want -ne $dec) { $dec = $want; $pending = 1 }
                    elseif ($pending -lt $Cfg.NeedSamples) { $pending++ }

                    $elapsed = ([DateTime]::Now - $lastFlip).TotalMilliseconds
                    if ($dec -and $pending -ge $Cfg.NeedSamples -and
                        ($elapsed -ge $Cfg.CooldownMs -or $lastFlip -eq [DateTime]::MinValue)) {

                        if (Set-SystemTheme -Light ($dec -eq 'light')) {
                            $lastFlip = [DateTime]::Now
                            $pending  = 0
                            Write-Log ("SWITCH -> {0}  P50={1:N3} ema={2:N3}" -f $dec, $st.P50, $ema)
                        }
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
