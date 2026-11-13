# Taskbar Contrast · 透明任务栏自动黑白字

配合 [TranslucentTB](https://github.com/TranslucentTB/TranslucentTB) 之类让任务栏变透明的工具使用：
任务栏底色变亮时文字自动变**黑**，底色变暗时自动变**白**，解决"颜色相近看不见时钟/图标/按钮文字"的问题。

| 修改前：浅色模式黑字，压在深色玻璃底上 | 修改后：深色模式白字 |
|---|---|
| ![](docs/before.png) | ![](docs/after.png) |

*（同一张壁纸、同一条任务栏，2560×1440 实拍，唯一变化是文字颜色）*

## 原理

Windows 没有"任务栏文字颜色"这个设置项，文字颜色跟随 `SystemUsesLightTheme`：

| `SystemUsesLightTheme` | 任务栏文字 |
|---|---|
| `1`（浅色模式） | 黑色 |
| `0`（深色模式） | 白色 |

脚本每 1.2 秒截取**任务栏那一条本身**的像素（不是它上方的画面——任务栏带着色/磨砂时两者差别很大），
统计亮度直方图并取**中位数**作为判断值。中位数不受叠加在上面的图标和文字影响，能准确反映底色明暗。

```
中位数 >= 0.55  ->  浅色模式（黑字）
中位数 <= 0.45  ->  深色模式（白字）
介于两者之间     ->  维持现状（死区）
```

为了在动态壁纸（Wallpaper Engine、幻灯片）和窗口切换时保持稳定，还加了：

* 采样值的指数移动平均（EMA）；
* 连续 2 次判断一致才动作；
* 两次实际切换之间至少间隔 6 秒。

切换方式是写注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\SystemUsesLightTheme`
并广播 `WM_SETTINGCHANGE` / `ImmersiveColorSet`，资源管理器会**立即重绘任务栏，不需要重启 explorer.exe**，也不用注销。

### 不会影响什么

只改 `SystemUsesLightTheme`，**不动** `AppsUseLightTheme`——Chrome、VS Code、资源管理器窗口等应用配色保持原样。
唯一的副作用是开始菜单、通知中心、系统弹窗会跟着一起变深/变浅，因为 Windows 只提供了这一个开关，
无法单独给任务栏文字上色。

## 环境要求

* Windows 10 / 11
* Windows PowerShell 5.1（系统自带）
* 不需要管理员权限，不装任何模块，无编译产物

## 安装

```powershell
git clone https://github.com/Archettee/taskbar-contrast.git
cd taskbar-contrast
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

`install.ps1` 会先停掉已有实例，然后在启动文件夹
（`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\TaskbarContrast.lnk`）创建快捷方式，
调用 `wscript.exe start-hidden.vbs` 静默启动（无黑框），并立即运行一次。

## 使用

```powershell
$s = ".\TaskbarContrast.ps1"

# 只判断一次并立即生效，然后退出
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Once

# 停止后台实例
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Stop

# 强制某个模式（之后仍会被守护进程按底色纠正）
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Force light   # 黑字
powershell -NoProfile -ExecutionPolicy Bypass -File $s -Force dark    # 白字

# 重新启动后台守护
wscript .\start-hidden.vbs
```

日志：脚本同目录 `taskbar-contrast.log`（超过 512 KB 自动滚动）。

## 调参

打开 `TaskbarContrast.ps1` 顶部的 `$Cfg`：

| 参数 | 默认 | 说明 |
|---|---|---|
| `IntervalMs` | `1200` | 采样间隔（毫秒），越小反应越快、CPU 略高 |
| `CooldownMs` | `6000` | 两次切换的最小间隔，切换太频繁就加大 |
| `BrightAbove` | `0.55` | 中位数高于它视为亮底 → 黑字 |
| `DarkBelow` | `0.45` | 中位数低于它视为暗底 → 白字 |
| `NeedSamples` | `2` | 需要连续几次判断一致，加大更稳但更迟钝 |

改完执行 `-Stop`，再 `wscript .\start-hidden.vbs` 重启。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

会停止守护进程并删除开机自启快捷方式，不改动你当前的系统深浅色设置。

## 已知限制

* **只采样主显示器**。副屏任务栏若背景不同不会被处理。
* 采样的是"任务栏实际绘制出来的样子"，所以以后把 TranslucentTB 换成浅色/磨砂样式时脚本会自动跟随，无需改配置。
* 手动切换系统深浅色后，守护进程会在几秒内按任务栏底色纠正回来——这是预期行为，它以任务栏实际亮度为准。
* 资源占用约单核 1.5%、内存约 100 MB（PowerShell 宿主 + GDI+）。想更省可把 `IntervalMs` 调到 2000。

## 许可证

[MIT](LICENSE)

---

[English](README.md)
