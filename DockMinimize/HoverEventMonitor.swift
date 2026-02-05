//
//  HoverEventMonitor.swift
//  DockMinimize
//
//  鼠标悬停事件监听器 - 监听 Dock 图标悬停
//

import Cocoa
import ApplicationServices

protocol HoverEventMonitorDelegate: AnyObject {
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didHoverOnApp bundleId: String, at position: CGPoint)
    func hoverEventMonitorDidExitDock(_ monitor: HoverEventMonitor)
    func hoverEventMonitor(_ monitor: HoverEventMonitor, didMoveInPreviewBar position: CGPoint)
    func hoverEventMonitorDidExitPreviewBar(_ monitor: HoverEventMonitor)
}

class HoverEventMonitor {
    weak var delegate: HoverEventMonitorDelegate?
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hoverTimer: DispatchWorkItem?
    private var lastHoveredApp: String?
    private var lastMousePosition: CGPoint = .zero
    
    var previewBarFrame: CGRect = .zero
    var isPreviewBarVisible: Bool = false
    private let hoverDelay: TimeInterval = 0.02 // 降低延迟实现丝滑响应
    private let hoverSwitchCooldown: TimeInterval = 0.09 // 防止快速滑过时预览条“乱跳”
    
    private let log = DebugLogger.shared
    
    func start() {
        guard eventTap == nil else { return }

        let eventMask = (1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HoverEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // event tap 被系统禁用时（timeout/userInput），这里会收到对应的 type。
                // 之前代码里有 `exit(0)`，会让用户觉得“软件突然自动退出”。
                // 改为：尝试重新启用 tap，并放通事件。
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.handleTapDisabled(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                }

                monitor.handleMouseMoved(event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        
        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    func stop() {
        hoverTimer?.cancel()
        hoverTimer = nil
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
    
    private func handleTapDisabled(type: CGEventType, event: CGEvent) {
        let reason = (type == .tapDisabledByTimeout) ? "timeout" : "userInput"
        log.log("Hover event tap disabled (\(reason)); attempting to re-enable.")

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            start()
        }
    }
    
    /// 最后一次触发悬停的时间（用于防抖）
    private var lastHoverTriggerTime: Date = Date.distantPast

    private func handleMouseMoved(event: CGEvent) {
        let location = event.location
        lastMousePosition = location
        
        // ⭐️ 终极修复：交互冷冻锁定 (Frozen Lock)
        // 如果系统正在搬运窗口（还原/最小化程序动画中），彻底忽略所有鼠标移动。
        // 这能保证在 5-10 秒的长动画过程中，代码不会去尝试刷新或销毁正在使用的数据，彻底杜绝崩溃。
        if WindowManager.shared.isTransitioning {
            return
        }
        
        // 2. --- 核心：10毫秒超时保险箱 ---
        let semaphore = DispatchSemaphore(value: 0)
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { 
                semaphore.signal()
                return 
            }
            
            do {
                // A. 如果预览条正在显示
                if self.isPreviewBarVisible && !self.previewBarFrame.isEmpty {
                    // 如果鼠标在预览条内，维持现状
                    if self.previewBarFrame.contains(location) {
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitor(self, didMoveInPreviewBar: location) }
                        semaphore.signal()
                        return
                    }
                    
                    // ⭐️ 核心改进：精确的“上升走廊”锁定
                    let screenHeight = NSScreen.main?.frame.height ?? 800
                    
                    // 仅当鼠标处于当前图标正上方窄幅区域（±40px）时锁定，防误触的同时允许横移切换
                    if let iconPos = self.getDockIconPosition(for: self.lastHoveredApp ?? "") {
                        let lockWidth: CGFloat = 40
                        let isWithinCorridor = location.x > (iconPos.x - lockWidth) && 
                                             location.x < (iconPos.x + lockWidth)
                        
                        if isWithinCorridor && location.y < (screenHeight - 45) && location.y > (screenHeight - 200) {
                            semaphore.signal()
                            return
                        }
                    }
                }
                
                // ⭐️ 命中测试：是否悬停在 Dock 图标上（纯内存操作）。
                // 旧版本用“屏幕底部 100px”判定 Dock 区域，Dock 在左/右侧或在副屏时会导致悬停预览完全失效。
                if let bundleId = DockIconCacheManager.shared.getBundleId(at: location) {
                    if bundleId != self.lastHoveredApp {
                        // ⭐️ 切换冷却（90ms），防止快速滑过时预览条“乱跳”
                        let now = Date()
                        if now.timeIntervalSince(self.lastHoverTriggerTime) < self.hoverSwitchCooldown {
                            semaphore.signal()
                            return
                        }
                        
                        self.cancelHoverTimer()
                        self.startHoverTimer(for: bundleId, at: location)
                        self.lastHoverTriggerTime = now
                    }
                } else {
                    self.cancelHoverTimer()
                    if self.lastHoveredApp != nil {
                        self.lastHoveredApp = nil
                        DispatchQueue.main.async { self.delegate?.hoverEventMonitorDidExitDock(self) }
                    }
                    semaphore.signal()
                    return
                }
            }
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 0.01)
    }
    
    private func startHoverTimer(for bundleId: String, at position: CGPoint) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lastHoveredApp = bundleId
            self.delegate?.hoverEventMonitor(self, didHoverOnApp: bundleId, at: position)
        }
        hoverTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: workItem)
    }
    
    private func cancelHoverTimer() {
        hoverTimer?.cancel()
        hoverTimer = nil
    }
    
    func getDockIconPosition(for bundleId: String) -> CGPoint? {
        if let icon = DockIconCacheManager.shared.cachedIcons.first(where: { $0.bundleId == bundleId }) {
            return CGPoint(x: icon.frame.midX, y: icon.frame.midY)
        }
        return nil
    }
}
