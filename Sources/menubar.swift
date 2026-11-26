// ClamshellBar — 菜单栏控制：外接屏在线时真正关闭内置屏（等同合盖），盖子可继续开着。
import AppKit
import CoreGraphics
import IOKit.pwr_mgt

typealias CfgEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!

func configureEnabledFn() -> CfgEnabledFn? {
    guard let sym = dlsym(rtldDefault, "CGSConfigureDisplayEnabled") else { return nil }
    return unsafeBitCast(sym, to: CfgEnabledFn.self)
}

func onlineDisplays() -> [CGDirectDisplayID] {
    var n: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    guard CGGetOnlineDisplayList(n, &ids, &n) == .success else { return [] }
    return Array(ids.prefix(Int(n)))
}

func externalDisplays() -> [CGDirectDisplayID] {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
}

/// 拔线瞬间外接屏还会在 online 列表里挂一会儿（电视尤其如此），所以看 active 而不是 online。
func activeExternals() -> [CGDirectDisplayID] {
    externalDisplays().filter { CGDisplayIsActive($0) != 0 }
}

/// 有信号的外接屏：active 且有可用模式。自动关闭内屏只认这个。
func signalExternals() -> [CGDirectDisplayID] {
    externalDisplays().filter { signalPresent($0) }
}

let logPath = NSString(string: "~/Library/Logs/clamshell.log").expandingTildeInPath

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] [app] \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

/// 内置屏被关掉后会从 online 列表里消失，三层兜底：
/// 在线列表 → 按 display id 全量扫描（CGDisplayIsBuiltin 对已关闭的面板仍返回 1）→ 上次用过的 id。
func builtinDisplay() -> CGDirectDisplayID? {
    if let b = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) { return b }
    for id in UInt32(1)...UInt32(32) where CGDisplayIsBuiltin(id) != 0 && CGDisplayPixelsWide(id) > 0 {
        return id
    }
    if let saved = UserDefaults.standard.object(forKey: "builtinDisplayID") as? Int, saved > 0 {
        return CGDirectDisplayID(saved)
    }
    return nil
}

@discardableResult
func setDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Int32 {
    guard let fn = configureEnabledFn() else { return -999 }
    var cfg: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&cfg)
    guard begin == .success else { return begin.rawValue }
    let e = fn(cfg, id, enabled)
    if e != .success { CGCancelDisplayConfiguration(cfg); return e.rawValue }
    return CGCompleteDisplayConfiguration(cfg, .forSession).rawValue
}

/// 解掉内置屏上可能残留的镜像；单独成一个事务，和 enable 合在一起提交会回 1001。
@discardableResult
func clearMirror(_ id: CGDirectDisplayID) -> Int32 {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return -1 }
    _ = CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
    return CGCompleteDisplayConfiguration(cfg, .forSession).rawValue
}

/// 空事务提交：配置本身是否健康。拔线后 WindowServer 常留下一份指向不存在显示器的脏配置，
/// 这时任何提交都回 1001；用它当探针，比猜 active 可靠。
func configIsSane() -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success else { return false }
    return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
}

/// 内置屏当前模式是否"不是它自己的"：被镜像进外接屏时会跟着跑 1920×1080，而面板自身最高 2560。
func modeLooksForeign(_ id: CGDirectDisplayID) -> Bool {
    guard let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode],
          let cur = CGDisplayCopyDisplayMode(id), !modes.isEmpty else { return false }
    let maxW = modes.map { $0.pixelWidth }.max() ?? 0
    return maxW > 0 && cur.pixelWidth < Int(Double(maxW) * 0.9)
}

/// 外接屏是否真的有信号：面板 active、有可用模式、刷新率大于 0。
/// 投影仪只插线不通电时，它会以 online 状态挂在列表里但没有任何可用模式，
/// 这时不能当作"可以放心关内屏"的外接。
func signalPresent(_ id: CGDirectDisplayID) -> Bool {
    guard CGDisplayIsActive(id) != 0, CGDisplayIsOnline(id) != 0 else { return false }
    guard let mode = CGDisplayCopyDisplayMode(id) else { return false }
    return mode.pixelWidth > 0 && mode.pixelHeight > 0 && mode.refreshRate > 0
}

func isMirrored(_ id: CGDirectDisplayID) -> Bool {
    CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
}

/// 合盖状态：合盖时内置屏本来就该黑着，不能去"恢复"它，更不能为此声明用户活动。
func lidClosed() -> Bool {
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard svc != 0 else { return false }
    defer { IOObjectRelease(svc) }
    let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
    return (v?.takeRetainedValue() as? Bool) ?? false
}

func displaysAsleep() -> Bool {
    let ids = onlineDisplays()
    return !ids.isEmpty && ids.allSatisfy { CGDisplayIsAsleep($0) != 0 }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var rememberedBuiltin: CGDirectDisplayID?
    var timer: Timer?

    /// App Nap 会冻住无窗口的菜单栏应用（实测静置 16 分钟零动作），用活动断言钉住；不阻止系统睡眠。
    var activityToken: NSObjectProtocol?

    var manualOverrideUntil: Date?
    var distrustUntil: Date?
    var disableFails = 0
    var lastSever = Date.distantPast
    var signalStreak = 0
    var sleeping = false
    var userActivityAssertion: IOPMAssertionID?
    var lastWakeDeclare = Date.distantPast
    /// 内置屏是否由我们关掉。息屏时 CGDisplayIsActive 对每块屏都返回 0，「关着」与「只是睡着」
    /// 因此无法区分；没有这条自己记的账，普通息屏会被当成拔线后的黑屏而反复点亮。
    var disabledByUs: Bool {
        get { UserDefaults.standard.bool(forKey: "disabledByUs") }
        set { UserDefaults.standard.set(newValue, forKey: "disabledByUs") }
    }
    /// 恢复失败后的退避：err=1014 会一直失败，不能每轮都拿声明用户活动去换一次亮屏。
    var restoreFails = 0
    var nextRestoreAt = Date.distantPast
    /// 关闭失败被回退后的冷静期。期间不再自动关内屏，避免「刚救回来又关掉」的拉锯。
    var noCloseUntil = Date.distantPast
    /// 上一次看到的在线外接集合，用来分辨「真的插了新东西」和「同一块屏在抖」
    var lastExternalSet: Set<CGDirectDisplayID> = []
    var lastProbe = Date.distantPast
    var lastHeartbeat = Date.distantPast
    var lastLogKey = ""
    var lastLogAt = Date.distantPast
    var inFlight = false

    var autoMode: Bool {
        get { UserDefaults.standard.bool(forKey: "autoMode") }
        set { UserDefaults.standard.set(newValue, forKey: "autoMode") }
    }

    func logThrottled(_ s: String) {
        let now = Date()
        if s == lastLogKey, now.timeIntervalSince(lastLogAt) < 20 { return }
        lastLogKey = s
        lastLogAt = now
        log(s)
    }

    func currentBuiltin() -> CGDirectDisplayID? {
        if let b = builtinDisplay() {
            rememberedBuiltin = b
            UserDefaults.standard.set(Int(b), forKey: "builtinDisplayID")
            return b
        }
        if let b = rememberedBuiltin { return b }
        if let saved = UserDefaults.standard.object(forKey: "builtinDisplayID") as? Int, saved > 0 {
            rememberedBuiltin = CGDirectDisplayID(saved)
            return rememberedBuiltin
        }
        return nil
    }

    /// 声明用户活动会创建 UserIsActive 断言：它既阻止显示休眠，也能把机器从睡眠里叫醒。
    /// 之前每轮轮询都调一次，断言叠到六条，机器合盖休眠时被反复唤醒。
    /// 现在只在"真的要唤醒面板"时调，一分钟最多一次，并且先释放上一条。
    func wakeDisplays() {
        guard !sleeping, !lidClosed() else { return }
        // 只在屏确实睡着、或内屏被我们关掉后离线（此时 online 列表为空）时才需要声明活动。
        // 屏亮着还去声明，只会平白重置空闲计时、把息屏推后。
        guard displaysAsleep() || disabledByUs else { return }
        guard Date().timeIntervalSince(lastWakeDeclare) > 60 else { return }
        lastWakeDeclare = Date()
        if let a = userActivityAssertion { IOPMAssertionRelease(a); userActivityAssertion = nil }
        var a: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("ClamshellBar" as CFString, kIOPMUserActiveLocal, &a)
        userActivityAssertion = a
    }

    // MARK: - 两个方向的动作

    @discardableResult
    func disableBuiltinNow(_ id: CGDirectDisplayID, reason: String) -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        var e = setDisplayEnabled(id, false)
        var ok = CGDisplayIsActive(id) == 0
        if !ok {
            let d = clearMirror(id)          // 镜像挂住时关闭同样回 1001
            e = setDisplayEnabled(id, false)
            ok = CGDisplayIsActive(id) == 0
            logThrottled("\(reason)：先解镜像(commit=\(d))再关闭 err=\(e) → off=\(ok)")
        }
        inFlight = false
        if ok { disabledByUs = true }
        logThrottled(ok ? "\(reason)：关闭内置屏 ID=\(id) 成功"
                        : "\(reason)：关闭内置屏 ID=\(id) 失败 err=\(e)")
        return ok
    }

    @discardableResult
    func restoreBuiltinNow(_ id: CGDirectDisplayID, reason: String) -> Bool {
        if CGDisplayIsActive(id) != 0 && !isMirrored(id) && !modeLooksForeign(id) {
            disabledByUs = false
            return true
        }
        guard !inFlight else { return false }
        wakeDisplays()
        usleep(400_000)
        inFlight = true
        let d = clearMirror(id)
        inFlight = false
        usleep(700_000)
        if CGDisplayIsActive(id) != 0 && !isMirrored(id) {
            disabledByUs = false
            logThrottled("\(reason)：解镜像后内置屏已恢复 commit=\(d)")
            return true
        }
        inFlight = true
        var e = setDisplayEnabled(id, true)
        var ok = CGDisplayIsActive(id) != 0
        if !ok {
            // 刚醒来的面板对第一次 enable 有时不回位，隔一下再来一次
            inFlight = false
            usleep(900_000)
            inFlight = true
            e = setDisplayEnabled(id, true)
            ok = CGDisplayIsActive(id) != 0
        }
        inFlight = false
        if ok { disabledByUs = false }
        logThrottled(ok ? "\(reason)：启用内置屏 ID=\(id) 成功"
                        : "\(reason)：启用内置屏 ID=\(id) 失败 err=\(e)（退避后重试）")
        return ok
    }

    /// 面板可能处于「逻辑上已关闭、实际还亮着」的状态：它被塞进了外接屏的硬件镜像里
    /// （mirrorOf != 0，且当前模式跟着外接跑 1920，而不是自己的 2940）。这时单纯 enable/disable
    /// 都不动它，必须先解镜像——解开后面板会亮回原生分辨率，再关才真的黑下去。
    @discardableResult
    func severMirrorAndDisable(_ id: CGDirectDisplayID, reason: String) -> Bool {
        guard !inFlight, Date().timeIntervalSince(lastSever) > 10 else { return false }
        lastSever = Date()
        inFlight = true
        let d = clearMirror(id)
        inFlight = false
        usleep(600_000)
        let lit = CGDisplayIsActive(id) != 0
        logThrottled("\(reason)：面板挂在镜像里(mirrorOf=\(CGDisplayMirrorsDisplay(id))) → 解镜像 commit=\(d) → 亮起=\(lit)")
        guard lit else { return true }
        return disableBuiltinNow(id, reason: reason + " 解镜像后")
    }

    // MARK: - 轮询决策

    func poll(forceRestore: Bool = false) {
        guard autoMode, !sleeping else { return }
        if lidClosed() { return }                       // 合盖：内屏本来就该黑，别去"恢复"
        if let until = manualOverrideUntil, Date() < until { return }
        guard !inFlight, let b = currentBuiltin() else { return }

        let builtinOn = CGDisplayIsActive(b) != 0
        // 只认"有信号"的外接：投影仪只插线不通电时它会挂在列表里但没模式，
        // 这种情况不关内屏（关了就没画面），也不算"有外接"。
        let extIDs = signalExternals()
        // 息屏是正常状态：屏睡着时 CGDisplayIsActive 对每块屏都返回 0，
        // 「内屏被关掉」与「内屏只是睡着」无从区分。只有确实由我们关过内屏、
        // 且外接已整个离开在线列表，才可能是拔线后的黑屏；其余一律不做声——
        // 声明用户活动会点亮屏幕，正是每次息屏后自己把自己叫醒的来源。
        if displaysAsleep(), !forceRestore {
            guard disabledByUs, externalDisplays().isEmpty else { return }
        }
        let extText = extIDs.map(String.init).joined(separator: ",")
        signalStreak = extIDs.isEmpty ? 0 : signalStreak + 1
        var externalUsable = !extIDs.isEmpty && !(distrustUntil.map { Date() < $0 } ?? false)
        // 信号连续两轮（约 4 秒）才算稳定，避免接触不良的一闪就关掉内屏
        if externalUsable && signalStreak < 2 { return }

        // 外接报 active 但配置已脏（拔掉的电视常这样）→ 当它不在
        if !builtinOn, externalUsable, Date().timeIntervalSince(lastProbe) > 20 {
            lastProbe = Date()
            if !configIsSane() {
                distrustUntil = Date().addingTimeInterval(120)
                externalUsable = false
                logThrottled("探针：显示配置不健康（提交失败）→ 暂不信任外接 [\(extText)]")
            }
        }

        if externalUsable {
            if Date() < noCloseUntil {
                if builtinOn { return }   // 冷静期：宁可多亮一块屏，也不再折腾
            }
            if !builtinOn, isMirrored(b) || modeLooksForeign(b) {
                _ = severMirrorAndDisable(b, reason: "有活动外接 [\(extText)]")
                refresh()
                return
            }
            guard builtinOn else { return }
            if disableBuiltinNow(b, reason: "有活动外接 [\(extText)]") {
                disableFails = 0
                distrustUntil = nil
                if signalExternals().isEmpty {
                    _ = restoreBuiltinNow(b, reason: "关闭后外接无信号 → 安全回退")
                }
            } else if disableFails >= 2 {
                disableFails = 0
                distrustUntil = Date().addingTimeInterval(120)
                noCloseUntil = Date().addingTimeInterval(60)
                logThrottled("连续关闭失败 → 暂不信任这块外接，保留内置屏 60 秒")
                _ = restoreBuiltinNow(b, reason: "关闭失败回退")
            } else {
                disableFails += 1
            }
            refresh()
            return
        }

        // 没有可用外接：内置屏必须亮着，且不能是跟着已拔掉的屏跑的黑镜像
        if !builtinOn || forceRestore || modeLooksForeign(b) || isMirrored(b) {
            if forceRestore { nextRestoreAt = .distantPast }
            guard Date() >= nextRestoreAt else { return }
            if restoreBuiltinNow(b, reason: "无活动外接 → 恢复内置屏") {
                restoreFails = 0
                nextRestoreAt = .distantPast
                refresh()
            } else {
                // err=1014 之类的失败会一直失败：退避 60/120/240/480/960 秒，别每分钟拿亮屏换一次重试
                restoreFails = min(restoreFails + 1, 5)
                nextRestoreAt = Date().addingTimeInterval(pow(2, Double(restoreFails)) * 30)
            }
        }
    }

    // MARK: - 生命周期

    func displayChanged() {
        manualOverrideUntil = nil
        disableFails = 0
        restoreFails = 0
        nextRestoreAt = .distantPast
        let now = Set(externalDisplays())
        let appeared = !now.subtracting(lastExternalSet).isEmpty
        lastExternalSet = now
        // 只有"新冒出来一块外接"才算真的插了东西，才清掉不信任与冷静期；
        // 否则同一块电视在抖（id 2→7→8 反复出现）会把锁存一次次抹掉，变成关-救-关的拉锯。
        if appeared {
            distrustUntil = nil
            noCloseUntil = Date.distantPast
        }
        poll(forceRestore: true)
        refresh()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rememberedBuiltin = builtinDisplay()
        if let b = rememberedBuiltin { UserDefaults.standard.set(Int(b), forKey: "builtinDisplayID") }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "监视显示器拓扑，自动开关内置屏")
        log("启动：内置屏 ID=\(rememberedBuiltin.map(String.init) ?? "未找到")，auto=\(autoMode)")
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                (NSApp.delegate as? AppDelegate)?.displayChanged()
            }
        }, nil)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.sleeping = false
            self.poll(forceRestore: true)
        }

        // 2 秒轮询：不排队、不递归、不做锁存，每一轮都从当前拓扑重新算一次该做什么
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let b = self.currentBuiltin(), Date().timeIntervalSince(self.lastHeartbeat) > 600 {
                self.lastHeartbeat = Date()
                log("心跳：外接活动=\(activeExternals().count) 内置屏=\(CGDisplayIsActive(b) != 0 ? "开着" : "关着")")
            }
            self.poll()
        }
        poll(forceRestore: true)
        refresh()
    }

    // MARK: - 手动操作

    func disableManually() {
        guard let b = currentBuiltin() else { log("手动关闭：找不到内置屏"); return }
        guard !activeExternals().isEmpty else {
            alert("没有外接显示器，拒绝关闭内置屏（否则会全黑）")
            return
        }
        manualOverrideUntil = Date().addingTimeInterval(120)
        _ = disableBuiltinNow(b, reason: "手动关闭内置屏")
        refresh()
    }

    func enableManually() {
        guard let b = currentBuiltin() else { log("手动恢复：找不到内置屏"); return }
        manualOverrideUntil = Date().addingTimeInterval(120)
        _ = restoreBuiltinNow(b, reason: "手动恢复内置屏")
        refresh()
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func refresh() {
        let hasExternal = !externalDisplays().isEmpty
        let active = currentBuiltin().map { CGDisplayIsActive($0) != 0 } ?? false

        if let button = statusItem.button {
            let name = hasExternal ? (active ? "laptopcomputer.and.display" : "laptopcomputer") : "laptopcomputer"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Clamshell")
                    ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Clamshell")
            img?.isTemplate = true
            button.image = img
            button.title = hasExternal && !active ? " 仅外接" : ""
        }

        let menu = NSMenu()
        let signalCount = signalExternals().count
        let extDesc: String = signalCount > 0 ? "外接屏有信号" : (hasExternal ? "外接屏无信号" : "无外接屏")
        let info = NSMenuItem(title: "\(extDesc) · 内置屏\(active ? "开着" : "已关闭")", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        let off = NSMenuItem(title: "关闭内置屏", action: #selector(menuOff), keyEquivalent: "")
        off.target = self
        off.isEnabled = hasExternal && active
        menu.addItem(off)

        let on = NSMenuItem(title: "恢复内置屏", action: #selector(menuOn), keyEquivalent: "")
        on.target = self
        on.isEnabled = !active
        menu.addItem(on)

        menu.addItem(.separator())
        let auto = NSMenuItem(title: "自动：接外接屏即关", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc func menuOff() { disableManually() }
    @objc func menuOn() { enableManually() }
    @objc func toggleAuto() {
        autoMode.toggle()
        log("自动开关 → \(autoMode)")
        distrustUntil = nil
        disableFails = 0
        poll(forceRestore: true)
        refresh()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
