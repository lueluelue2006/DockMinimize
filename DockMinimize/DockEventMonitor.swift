//
//  DockEventMonitor.swift
//  DockMinimize
//
//  Created by Dock Minimize
//

import Cocoa
import ApplicationServices
import os.lock

// --- 嵌入式 Dock 图标缓存管理器 ---
class DockIconCacheManager {
    static let shared = DockIconCacheManager()

    private enum DockOrientation: String {
        case bottom
        case left
        case right
    }
    
    struct DockIconInfo {
        let frame: CGRect
        let bundleId: String
    }
    
    // Thread-safe snapshots (read by event taps / monitors from non-main threads).
    private var lock = os_unfair_lock_s()
    private var cachedIconsStorage: [DockIconInfo] = []
    private var dockOrientationStorage: DockOrientation = .bottom
    private var lastUpdateStorage: TimeInterval = 0

    var cachedIcons: [DockIconInfo] {
        snapshot().icons
    }

    private func snapshot() -> (icons: [DockIconInfo], orientation: DockOrientation, lastUpdate: TimeInterval) {
        os_unfair_lock_lock(&lock)
        let icons = cachedIconsStorage
        let orientation = dockOrientationStorage
        let lastUpdate = lastUpdateStorage
        os_unfair_lock_unlock(&lock)
        return (icons, orientation, lastUpdate)
    }

    private func updateSnapshot(icons: [DockIconInfo], orientation: DockOrientation, updatedAt: TimeInterval) {
        os_unfair_lock_lock(&lock)
        cachedIconsStorage = icons
        dockOrientationStorage = orientation
        lastUpdateStorage = updatedAt
        os_unfair_lock_unlock(&lock)
    }

    private let queue = DispatchQueue(label: "com.dockminimize.dockcache", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let minUpdateInterval: TimeInterval = 5.0
    private let periodicUpdateInterval: TimeInterval = 15.0
    private var lastAttempt: TimeInterval = 0
    private var isUpdating = false
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    
    private init() {
        installObservers()
        startPeriodicUpdates()
        requestUpdate(force: true, reason: "startup")
    }
    
    deinit {
        timer?.cancel()
        timer = nil
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }
    
    private func installObservers() {
        // Screen/workspace changes can move Dock icons; update on these to reduce polling pressure.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.requestUpdate(force: true, reason: "screen-params")
            }
        )

        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            ws.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let reason = (app?.bundleIdentifier == "com.apple.dock") ? "dock-launch" : "app-launch"
                self?.requestUpdate(force: app?.bundleIdentifier == "com.apple.dock", reason: reason)
            }
        )
        workspaceObservers.append(
            ws.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let reason = (app?.bundleIdentifier == "com.apple.dock") ? "dock-terminate" : "app-terminate"
                self?.requestUpdate(force: app?.bundleIdentifier == "com.apple.dock", reason: reason)
            }
        )
    }

    private func startPeriodicUpdates() {
        timer?.cancel()

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.2, repeating: periodicUpdateInterval, leeway: .seconds(2))
        t.setEventHandler { [weak self] in
            self?.updateCacheIfNeeded(force: false, reason: "periodic")
        }
        t.resume()
        timer = t
    }

    func requestUpdate(force: Bool = false, reason: String) {
        queue.async { [weak self] in
            self?.updateCacheIfNeeded(force: force, reason: reason)
        }
    }

    private func updateCacheIfNeeded(force: Bool, reason: String) {
        let now = Date().timeIntervalSince1970
        let state = snapshot()

        if !force, now - state.lastUpdate < minUpdateInterval { return }
        // Avoid bursty updates when multiple notifications arrive together.
        if !force, now - lastAttempt < 1.0 { return }

        lastAttempt = now
        updateCache(reason: reason)
    }

    func updateCache(reason: String = "unknown") {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }

        let startedAt = DispatchTime.now()
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
            if elapsed > 0.25 {
                DebugLogger.shared.log(String(format: "Dock cache update (%@) took %.3fs", reason, elapsed))
            }
        }

        autoreleasepool {
            let orientationValue = (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom").lowercased()
            let orientation = DockOrientation(rawValue: orientationValue) ?? .bottom
            
            // --- 核心：所有系统调用都在后台线程，避免卡住 UI ---
            guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
            let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
            
            var childrenRef: CFTypeRef?
            // 如果这里卡住，也只是后台线程卡住，不会卡死 UI
            guard AXUIElementCopyAttributeValue(dockElement, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { return }
            
            var newIcons: [DockIconInfo] = []
            let blacklisted = Set(UserDefaults.standard.stringArray(forKey: "blacklistedBundleIDs") ?? [])
            let downloadsPath = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? "/Downloads/"

            for child in children {
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                if let role = roleRef as? String, role == "AXList" {
                    var listChildrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &listChildrenRef) == .success,
                       let listChildren = listChildrenRef as? [AXUIElement] {
                        for iconElement in listChildren {
                            var positionRef: CFTypeRef?
                            var sizeRef: CFTypeRef?
                            if AXUIElementCopyAttributeValue(iconElement, kAXPositionAttribute as CFString, &positionRef) == .success,
                               AXUIElementCopyAttributeValue(iconElement, kAXSizeAttribute as CFString, &sizeRef) == .success {
                                var position = CGPoint.zero
                                var size = CGSize.zero
                                AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
                                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
                                
                                var bundleId: String? = nil
                                
                                // 1. 优先尝试直接从 AXUIElement 获取标识符 (最快最安全，不触碰文件系统)
                                var bidRef: CFTypeRef?
                                if AXUIElementCopyAttributeValue(iconElement, "AXBundleIdentifier" as CFString, &bidRef) == .success,
                                   let bid = bidRef as? String {
                                    bundleId = bid
                                }
                                
                                // 2. 如果失败，尝试通过 URL 获取，但要避开敏感路径
                                if bundleId == nil {
                                    var urlRef: CFTypeRef?
                                    if AXUIElementCopyAttributeValue(iconElement, "AXURL" as CFString, &urlRef) == .success,
                                       let url = urlRef as? URL {
                                        
                                        // 检查是否在“下载”文件夹中 (避雷针)
                                        let isSensitive = url.path.contains(downloadsPath) || url.path.contains("/Downloads/")
                                        
                                        if isSensitive {
                                            // 敏感路径：仅匹配运行中的应用，绝不调用 Bundle(path:)
                                            bundleId = NSWorkspace.shared.runningApplications.first(where: {
                                                $0.bundleURL?.path == url.path || $0.executableURL?.path == url.path
                                            })?.bundleIdentifier
                                        } else {
                                            // 安全路径：可以使用 Bundle(path:)
                                            bundleId = Bundle(path: url.path)?.bundleIdentifier
                                        }
                                    }
                                }
                                
                                if let bid = bundleId {
                                    // 检查黑名单，如果是黑名单软件，则不将其加入缩略图缓存，彻底不碰它
                                    if !blacklisted.contains(bid) {
                                        newIcons.append(DockIconInfo(frame: CGRect(origin: position, size: size), bundleId: bid))
                                    }
                                }
                            }
                        }
                    }
                    // Dock usually exposes a single AXList containing tiles; avoid scanning other children.
                    break
                }
            }
            
            updateSnapshot(icons: newIcons, orientation: orientation, updatedAt: Date().timeIntervalSince1970)
        }
    }

    func getBundleId(at point: CGPoint) -> String? {
        // 纯内存操作，绝对安全（不做任何同步 AX/Workspace 调用）
        let state = snapshot()
        let orientation = state.orientation
        var bestBundleId: String?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        for icon in state.icons {
            let originalFrame = icon.frame
            var hitFrame = originalFrame

            // 解决“鼠标在 Dock 图标附近仍选中，但 frame.contains 不命中”的问题：
            // - 沿 Dock 排列方向稍微放宽（覆盖图标间距/浮动）
            // - 往 Dock 外侧也放宽（覆盖边缘仍可选中区域）
            //
            // 注意：扩展 frame 后，多个 icon 的 hitFrame 可能会重叠。
            // 这里不能“命中第一个就返回”，否则容易把正在悬停的 icon 误判成别的（甚至是未运行的 App）
            // 导致看起来“悬停完全没反应”。我们改为选“离原始 icon frame 中心最近”的那个。
            let alongAxisPadding: CGFloat = 8
            let outsidePadding: CGFloat
            let insidePadding: CGFloat
            switch orientation {
            case .bottom:
                outsidePadding = 10
                insidePadding = max(24, min(60, hitFrame.height * 0.8))
                hitFrame.origin.x -= alongAxisPadding
                hitFrame.size.width += alongAxisPadding * 2
                hitFrame.origin.y -= insidePadding
                hitFrame.size.height += insidePadding + outsidePadding
            case .right:
                outsidePadding = 40
                insidePadding = max(24, min(60, hitFrame.width * 0.8))
                hitFrame.origin.y -= alongAxisPadding
                hitFrame.size.height += alongAxisPadding * 2
                hitFrame.origin.x -= insidePadding
                hitFrame.size.width += insidePadding + outsidePadding
            case .left:
                outsidePadding = 40
                insidePadding = max(24, min(60, hitFrame.width * 0.8))
                hitFrame.origin.y -= alongAxisPadding
                hitFrame.size.height += alongAxisPadding * 2
                hitFrame.origin.x -= outsidePadding
                hitFrame.size.width += insidePadding + outsidePadding
            }

            guard hitFrame.contains(point) else { continue }

            let dx = point.x - originalFrame.midX
            let dy = point.y - originalFrame.midY
            let distance2 = dx * dx + dy * dy
            let penalty: CGFloat = originalFrame.contains(point) ? 0 : 1_000_000
            let score = penalty + distance2

            if score < bestScore {
                bestScore = score
                bestBundleId = icon.bundleId
            }
        }

        return bestBundleId
    }
}

class DockEventMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastProcessedTime: Date = Date.distantPast
    
    private let log = DebugLogger.shared

    private var debugDockClicksEnabled: Bool {
        SettingsManager.shared.enableDockClickDebugLogs
    }
    
    func start() {
        guard eventTap == nil else { return }

        // 监听左键、右键、中键点击，用于拦截和隐藏预览
        let eventMask = (1 << CGEventType.leftMouseDown.rawValue) | 
                         (1 << CGEventType.rightMouseDown.rawValue) | 
                         (1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DockEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // --- 深度稳定性加固：严禁在回调中进行任何阻塞式系统调用 ---
        
        // 1. 系统禁用检查 (HID 链条安全检查)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 事件 tap 可能因“回调超时”或“用户输入”被系统临时禁用。
            // 之前这里直接 `exit(0)` 会导致用户感知为“软件突然自动退出”。
            // 改为：尝试立即重新启用 tap（必要时重建），并继续放通事件。
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "userInput"
            log.log("Dock event tap disabled (\(reason)); attempting to re-enable.")

            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            } else {
                start()
            }

            return Unmanaged.passUnretained(event)
        }
        
        // 2. 避免在系统设置窗口活跃时进行任何操作
        // 如果这里卡住，通过 NSEvent 检查 frontmostApplication 可能也会锁
        // 所以我们只在非常确定的情况下继续
        
        // 核心：使用尝试性权限检查。如果权限没了，说明我们要退出了。
        // 但是 AXIsProcessTrusted() 本身在权限切换时可能也会死锁！！！
        // 解决方案：不在此处检查权限，只检查内存中的缓存
        
        // 2. 右键/中键点击立刻关闭预览 (Dock 的右键菜单优先级最高)
        if type == .rightMouseDown || type == .otherMouseDown {
            let location = event.location
            // 旧版本用“屏幕底部 100px”判定 Dock 区域，Dock 在左/右侧或在副屏时会失效。
            // 这里改为：命中任意 Dock 图标就认为在 Dock 区域（纯内存操作）。
            if DockIconCacheManager.shared.getBundleId(at: location) != nil {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("HidePreviewBarForcefully"), object: nil)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
        
        let location = event.location
        
        // 3. 快速命中测试：是否点在 Dock 图标上（纯内存操作，不触碰任何系统调用）
        // 旧版本用“屏幕底部 100px”判定 Dock 区域，Dock 在左/右侧或在副屏时会完全失效。
        guard let clickedBundleId = DockIconCacheManager.shared.getBundleId(at: location) else {
            if debugDockClicksEnabled {
                log.log("🧭 DockClick passthrough: no bundle hit at point=(\(Int(location.x)),\(Int(location.y)))")
            }
            return Unmanaged.passUnretained(event)
        }
        
        // 防抖：缩短至 0.1s，适应快速连击。
        // 命中防抖时吞掉事件，避免回落到系统默认点击行为。
        if Date().timeIntervalSince(lastProcessedTime) < 0.1 {
            if debugDockClicksEnabled {
                log.log("🧭 DockClick swallowed: debounce hit for \(clickedBundleId)")
            }
            return nil
        }
        
        // 4. --- 终极防御：给所有的业务逻辑加一个“超时保险箱” ---
        // 我们在后台线程执行业务代码，如果 10ms 内没跑完（说明系统 AX 或 Workspace 锁住了），
        // 那么主线程立即直接放通事件，不等待，不卡死系统。
        
        let semaphore = DispatchSemaphore(value: 0)
        var resultEvent: Unmanaged<CGEvent>? = Unmanaged.passUnretained(event)
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { 
                semaphore.signal()
                return 
            }
            
            // 下面的逻辑如果卡住了，也只卡在这个后台线程，主线程 10ms 后会直接跳过。
            do {
                // 不需要在这里额外检查黑名单，因为 DockIconCacheManager.updateCache 已经排除了黑名单应用。
                // 只要 clickedBundleId 有值，就说明它是我们负责的应用。
                
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: clickedBundleId)
                if let targetApp = runningApps.first {
                    self.lastProcessedTime = Date()
                    
                    // ⭐️ 核心通用修复：无论前台还是后台，只要判定为“无窗口且非隐藏”，必须放行。
                    // 这解决了 Finder/QSpace 在后台时点击需要两下（第一次被拦截）的问题。
                    
                    var hasVisibleWindows = false
                    // 如果 App 是隐藏的，我们认为它可能有窗口（只是不可见），所以不放行，让 EnsureVisible 处理
                    // 如果 App 不是隐藏的，我们检查屏幕上是否有窗口
                    if !targetApp.isHidden {
                        if let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                            for info in windowList {
                                guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, ownerPID == targetApp.processIdentifier else { continue }
                                guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
                                guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.1 else { continue }
                                
                                if let bounds = info[kCGWindowBounds as String] as? [String: Double] {
                                    let w = bounds["Width"] ?? 0
                                    let h = bounds["Height"] ?? 0
                                    if w < 100 || h < 100 { continue }
                                }
                                
                                hasVisibleWindows = true
                                break
                            }
                        }
                        
                        // ⭐️ 核心修复：如果是 Finder，即便没有可见窗口也要继续逻辑（去恢复被缩小的窗口）。
                        // 如果是其他应用，确实没有窗口时，仍交由系统 Reopen 流程处理。
                        if !hasVisibleWindows && clickedBundleId != "com.apple.finder" {
                            if debugDockClicksEnabled {
                                log.log("🧭 DockClick passthrough: no visible windows for \(clickedBundleId), let system reopen")
                            }
                            semaphore.signal()
                            return
                        }
                    }
                    
                    // ⭐️ UI 瞬间响应：先发通知，后调逻辑。保证指示条第一秒就变。
                    // 如果已经在前台，意图是 Toggle (最小化/恢复)
                    // 如果在后台，意图是 Activate (提升至最前)
                    let isAlreadyActive = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == clickedBundleId
                    let action = isAlreadyActive ? "toggle" : "activate"

                    if self.debugDockClicksEnabled {
                        self.log.log("🧭 DockClick intercepted: bundle=\(clickedBundleId), action=\(action), hidden=\(targetApp.isHidden), visibleWindows=\(hasVisibleWindows)")
                    }
                    
                    NotificationCenter.default.post(
                        name: NSNotification.Name("DockIconClicked"),
                        object: nil,
                        userInfo: ["bundleId": clickedBundleId, "action": action]
                    )
                    
                    DispatchQueue.main.async {
                        if action == "toggle" {
                            WindowManager.shared.toggleWindows(for: targetApp)
                        } else {
                            WindowManager.shared.ensureWindowsVisible(for: targetApp)
                        }
                    }
                    resultEvent = nil
                } else {
                    // 2. 该应用未运行...
                }
            }
            semaphore.signal()
        }
        
        // 最多等 40 毫秒。若仍超时则吞掉事件，避免回落系统默认行为。
        let waitResult = semaphore.wait(timeout: .now() + 0.04)
        if waitResult == .timedOut {
            if debugDockClicksEnabled {
                log.log("🧭 DockClick swallowed: worker timeout for intercepted click")
            }
            return nil
        }
        
        return resultEvent
    }
}
