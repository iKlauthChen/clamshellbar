// clamshell — 在有外接显示器时真正关闭 MacBook 内置屏（等同合盖效果），盖子保持打开。
// 原理：CoreGraphics 私有符号 CGSConfigureDisplayEnabled 装进标准显示器重配置事务。
// 用法：clamshell status | off | on | watch | doctor

import CoreGraphics
import Foundation

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

func builtinDisplay() -> CGDirectDisplayID? {
    if let b = onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) { return b }
    // 内置屏被关掉后会从 online 列表消失，但 CGDisplayIsBuiltin 仍认它
    for id in UInt32(1)...UInt32(32) where CGDisplayIsBuiltin(id) != 0 && CGDisplayPixelsWide(id) > 0 {
        return id
    }
    if let v = ProcessInfo.processInfo.environment["CLAMSHELL_BUILTIN_ID"], let id = UInt32(v) { return id }
    return rememberedBuiltin
}

func externalDisplays() -> [CGDirectDisplayID] {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
}

func describe() -> String {
    let all = onlineDisplays()
    var out = "在线显示器 \(all.count) 台：\n"
    for id in all {
        let kind = CGDisplayIsBuiltin(id) != 0 ? "内置" : "外接"
        let state = CGDisplayIsActive(id) != 0 ? "active" : "inactive(已关闭)"
        out += "  ID=\(id) \(kind) \(state) \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
        out += CGDisplayIsMain(id) != 0 ? " main\n" : "\n"
    }
    return out
}

@discardableResult
func setDisplayEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Int32 {
    guard let fn = configureEnabledFn() else { return -999 }
    var cfg: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&cfg)
    guard begin == .success else { return begin.rawValue }
    let e = fn(cfg, id, enabled)
    if e != .success {
        CGCancelDisplayConfiguration(cfg)
        return e.rawValue
    }
    let done = CGCompleteDisplayConfiguration(cfg, .forSession)
    return done.rawValue
}

// MARK: - 安全护栏

/// 记住内置屏 ID，因为被禁用后它可能从 online 列表消失，届时仍需要它来恢复。
var rememberedBuiltin: CGDirectDisplayID? = {
    if let v = ProcessInfo.processInfo.environment["CLAMSHELL_BUILTIN_ID"], let id = UInt32(v) { return id }
    return nil
}()

func currentBuiltin() -> CGDirectDisplayID? {
    if let b = builtinDisplay() { rememberedBuiltin = b; return b }
    return rememberedBuiltin
}

@discardableResult
func disableBuiltin() -> String {
    guard configureEnabledFn() != nil else { return "API 不可用：本系统未导出 CGSConfigureDisplayEnabled" }
    guard let b = currentBuiltin() else { return "未找到内置屏（可能已关闭且 ID 未知）" }
    guard !externalDisplays().isEmpty else { return "SAFETY：没有外接显示器，拒绝关闭内置屏（否则全黑）" }
    if CGDisplayIsActive(b) == 0 { return "内置屏已经是关闭状态" }
    let e = setDisplayEnabled(b, false)
    return e == 0 ? "已关闭内置屏 ID=\(b)（active=\(CGDisplayIsActive(b) != 0)）"
                  : "关闭失败 CGError=\(e)"
}

@discardableResult
func enableBuiltin() -> String {
    guard configureEnabledFn() != nil else { return "API 不可用" }
    guard let b = currentBuiltin() else { return "未找到内置屏" }
    if CGDisplayIsActive(b) != 0 { return "内置屏本来就是开的" }
    let e = setDisplayEnabled(b, true)
    return e == 0 ? "已恢复内置屏 ID=\(b)（active=\(CGDisplayIsActive(b) != 0)）"
                  : "恢复失败 CGError=\(e)"
}

// MARK: - watch：跟随外接屏插拔自动开关

let work = DispatchQueue(label: "clamshell.watch")
var generation = 0
let logPath = NSString(string: "~/Library/Logs/clamshell.log").expandingTildeInPath

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(s)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

func evaluate() {
    guard let b = currentBuiltin() else { return }
    let hasExternal = !externalDisplays().isEmpty
    let active = CGDisplayIsActive(b) != 0
    if hasExternal && active {
        log("外接屏 \(externalDisplays()) 在线 → 关闭内置屏：\(disableBuiltin())")
    } else if !hasExternal && !active {
        log("外接屏已断开 → 恢复内置屏：\(enableBuiltin())")
    }
}

func scheduleEvaluate(delay: Double) {
    work.async {
        generation += 1
        let mine = generation
        work.asyncAfter(deadline: .now() + delay) {
            if mine == generation { evaluate() }
        }
    }
}

let callback: CGDisplayReconfigurationCallBack = { _, _, _ in
    scheduleEvaluate(delay: 0.7)
}

func runWatch() {
    // 初始化时记录内置屏 ID
    _ = currentBuiltin()
    CGDisplayRegisterReconfigurationCallback(callback, nil)
    log("watch 启动，内置屏 ID=\(String(describing: rememberedBuiltin))")
    evaluate()
    // 看门狗：某些机型会以最小亮度"唤醒"面板，2 秒后重新关掉
    let timer = DispatchSource.makeTimerSource(queue: work)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler { evaluate() }
    timer.resume()
    withExtendedLifetime(timer) { RunLoop.main.run() }
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "status"

switch cmd {
case "status":
    print(describe())
    print("私有 API：\(configureEnabledFn() != nil ? "可用" : "不可用")")
case "off":
    print(disableBuiltin())
case "on":
    print(enableBuiltin())
case "watch":
    runWatch()
case "doctor":
    print("dlsym CGSConfigureDisplayEnabled：\(configureEnabledFn() != nil ? "FOUND" : "missing")")
    print(describe())
    print("内置屏 ID：\(String(describing: builtinDisplay()))")
    print("外接屏：\(externalDisplays())")
default:
    print("用法：clamshell status|off|on|watch|doctor")
    exit(2)
}
