//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Press/release of the fn + control live session shortcut. Shares this
    /// event tap so the app only needs one system-wide keyboard listener.
    let liveSessionShortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()
    /// Fires when command is double tapped, which switches a live session
    /// between push-to-talk and hands-free. (Not option: double-tapping
    /// option is a common shortcut for opening other apps, such as Claude.)
    let commandDoubleTapPublisher = PassthroughSubject<Void, Never>()
    /// Mutated only from the CGEvent tap callback (main thread).
    private var commandDoubleTapDetector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false
    /// Mutated only from the CGEvent tap callback (main thread), like isShortcutCurrentlyPressed.
    private var isLiveSessionShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        isShortcutCurrentlyPressed = false
        isLiveSessionShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        // CGEvent timestamps use different units across Mac hardware, so time
        // the taps with the system uptime clock at the moment the event arrives.
        let eventArrivalTimestamp = ProcessInfo.processInfo.systemUptime
        if eventType == .flagsChanged {
            let deviceIndependentModifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
                .intersection(.deviceIndependentFlagsMask)
            let didDoubleTapCommand = commandDoubleTapDetector.handleModifierFlagsChanged(
                modifierFlags: deviceIndependentModifierFlags,
                timestamp: eventArrivalTimestamp
            )
            if didDoubleTapCommand {
                commandDoubleTapPublisher.send()
            }
        } else if eventType == .keyDown {
            commandDoubleTapDetector.handleKeyPressed()
        }

        let liveSessionShortcutTransition = LiveSessionToggleShortcut.shortcutTransition(
            for: eventType,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isLiveSessionShortcutCurrentlyPressed
        )

        switch liveSessionShortcutTransition {
        case .none:
            break
        case .pressed:
            isLiveSessionShortcutCurrentlyPressed = true
            liveSessionShortcutTransitionPublisher.send(.pressed)
        case .released:
            isLiveSessionShortcutCurrentlyPressed = false
            liveSessionShortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }
}
