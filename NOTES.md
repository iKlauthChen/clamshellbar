# 实现笔记

这套接口没有文档，以下每条都是在本机（Apple Silicon / macOS 27.x）实测出来的。如果哪天自动开关又失灵，先看最后一条「调试入口」。

## 关闭内置屏

用私有符号 `CGSConfigureDisplayEnabled`，包在标准的显示重配置事务里：

```swift
typealias CfgEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let fn = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2)!, "CGSConfigureDisplayEnabled")!, to: CfgEnabledFn.self)

var cfg: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&cfg)
let e = fn(cfg, builtinID, false)
if e == .success { CGCompleteDisplayConfiguration(cfg, .forSession) }
```

不需要关 SIP、不需要 entitlement、也不链接私有 framework。用 `.forSession` 提交，注销或重启后系统自己把屏还回来，这是最便宜的兜底。

## 内置屏会从在线列表里消失

关掉之后 `CGGetOnlineDisplayList` 里就没有它了，但 `CGDisplayIsBuiltin(id)` 对它仍返回 1。所以找内置屏要三层兜底：在线列表 → 扫 `id 1...32` → UserDefaults 里存的上次用过的 ID。只靠在线列表的写法，会在「启动时屏已经关着」的情况下把内置屏记成 nil，自动逻辑随之静默空转——手动按钮还能用，因此极难察觉。

## 硬件镜像会让 enable 静默失效

插上外接屏后，系统常把内置屏塞进对端的硬件镜像里（`system_profiler` 显示 `Mirror Status: Hardware Mirror`）。这个状态下：

- 面板可能报 `CGDisplayIsActive == false`，实际却仍在按外接的时序发光（「说关了却还亮着」）；
- `CGSConfigureDisplayEnabled(id, true)` 返回成功、commit 也回 0，面板纹丝不动。

判据是当前模式不是它自己的：面板原生 2940×1912，被拉去跟外接跑时是 1920×1080。处置必须**先解镜像、再关闭**，且两步要分成两个事务——合在一个事务里提交会回 `CGError 1001`：

```swift
CGBeginDisplayConfiguration(&cfg)
CGConfigureDisplayMirrorOfDisplay(cfg, builtinID, kCGNullDirectDisplay)
CGCompleteDisplayConfiguration(cfg, .forSession)   // 面板此时会先亮回原生分辨率
// 再单独发一次禁用，才真的黑下去
```

注意 `CGDisplayMirrorsDisplay` 对「硬件镜像」返回的是 `kCGNullDirectDisplay`，查不出来，只能靠模式尺寸判断。

## 显示器睡着时 enable 也是假成功

机器刚从睡眠醒来、或显示器处于息屏状态时，`enable` 会返回成功而面板不亮。先声明一次用户活动再操作：

```swift
var a: IOPMAssertionID = 0
IOPMAssertionDeclareUserActivity("ClamshellBar" as CFString, kIOPMUserActiveLocal, &a)
```

## 但别让「唤醒面板」变成「唤醒整机」

`IOPMAssertionDeclareUserActivity` 会留下一条 `UserIsActive` 断言，它阻止显示休眠，也能把系统从睡眠里叫醒。早期版本在每轮轮询里都调它，结果机器合盖休眠后每隔几十秒自己醒一下，`pmset -g assertions` 里能看到同一个进程叠了六七条 `UserIsActive`。

现在的规则：只在真要动面板时声明，一分钟最多一次，声明前释放上一条；轮询入口先过三道闸门——合盖（`AppleClamshellState`）、显示器全部 `CGDisplayIsAsleep`、收到 `NSWorkspace.willSleepNotification` 之后一律不做事，`didWakeNotification` 时再恢复。

息屏闸门有个例外：拔线后内屏关着、外接也不在，看起来和「普通息屏」一模一样（睡着时 `CGDisplayIsActive` 对每块屏都返回 0）。判据不能看屏的 active，只能看自己记的账：`disableBuiltinNow` 成功时把 `disabledByUs` 写进 UserDefaults，恢复成功时清掉。息屏时只有「确实由我们关过内屏、且外接已整个离开在线列表」才放行去救；显示器重配置事件（`displayChanged` → `poll(forceRestore:)`）可以跳过闸门。否则每轮轮询都会把一次普通息屏当成黑屏，声明用户活动、点亮屏、屏再睡、再点——2026-11-26 上午实测 66 秒一轮，九轮才停。

启用失败（`CGError 1014`）不再「下一轮再试」，而是 60/120/240/480/960 秒退避：屏没真正醒来时 enable 必然失败，拿亮屏换重试是最坏的交换。

## 同一时刻只能有一个写入者

菜单栏应用和 launchd 里的守护进程同时跑，两边各自开显示事务会互相作废，满屏 `CGError 1001`，开关全落不了地。进程内用 `inFlight` 保证串行；如果装了别的显示工具（Lunar、BetterDisplay、DisplayLink 之类），也要留意它们是否在同时改配置。

## 重试不要写成递归链

早先每个调用点各自 `asyncAfter` 递归重试，一次失败能扇出九次尝试。改成单一重试链后又会被「外接短暂又报 active」打断而静默死掉。最终形态是每 2 秒轮询、每轮从当前拓扑重算：不排队、不递归、不做锁存。显示状态是个无法完全观测的黑盒，只能反复核对。

关闭连续失败时倒向「保屏」——重新亮起内置屏并进入 60 秒冷静期，而不是继续尝试关屏。杀屏的代价远大于多亮一块屏。

## 调试入口

所有决策都写进 `~/Library/Logs/clamshell.log`，包括每十分钟一条心跳（区分「没事可做」和「根本没在跑」）、每次关闭/启用的 `CGError` 与执行后的真实状态。命令行工具也能直接查：

```bash
./build/clamshell status     # 列出在线显示器、内置屏状态、私有 API 是否可用
./build/clamshell doctor     # 符号是否找得到、内置屏 ID、外接屏列表
```
