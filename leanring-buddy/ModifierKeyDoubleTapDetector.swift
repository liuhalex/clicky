//
//  ModifierKeyDoubleTapDetector.swift
//  leanring-buddy
//
//  Detects a quick double tap of a single modifier key (command), used to
//  switch a live session between push-to-talk and hands-free.
//
//  Only clean taps count: the key pressed on its own and released quickly,
//  with no other modifier or key involved. That keeps normal uses of command
//  (command + c, command + tab, ...) from ever toggling the mode by accident.
//

import AppKit

nonisolated struct ModifierKeyDoubleTapDetector {
    /// A press held longer than this is a hold, not a tap.
    static let maximumTapDurationSeconds: TimeInterval = 0.35
    /// The second tap must start within this long after the first one ends.
    static let maximumGapBetweenTapsSeconds: TimeInterval = 0.4

    let tappedModifierFlag: NSEvent.ModifierFlags
    /// Modifiers that make a press "not a clean tap" if they're involved.
    /// Caps lock is deliberately left out so it being on doesn't block taps.
    private let otherModifierFlags: NSEvent.ModifierFlags

    private var isTappedModifierDown = false
    private var tappedModifierDownTimestamp: TimeInterval = 0
    private var wasCurrentPressCombinedWithSomethingElse = false
    /// When the last clean tap was released, while waiting for a second tap.
    private var lastCleanTapReleaseTimestamp: TimeInterval?

    init(tappedModifierFlag: NSEvent.ModifierFlags) {
        self.tappedModifierFlag = tappedModifierFlag
        self.otherModifierFlags = NSEvent.ModifierFlags([.shift, .control, .option, .command, .function])
            .subtracting(tappedModifierFlag)
    }

    /// Feed every modifier change (flagsChanged event). Returns true exactly
    /// when the second clean tap of a double tap is released.
    mutating func handleModifierFlagsChanged(modifierFlags: NSEvent.ModifierFlags, timestamp: TimeInterval) -> Bool {
        let isTappedModifierNowDown = modifierFlags.contains(tappedModifierFlag)
        let areOtherModifiersDown = !modifierFlags.isDisjoint(with: otherModifierFlags)

        if isTappedModifierNowDown && !isTappedModifierDown {
            isTappedModifierDown = true
            tappedModifierDownTimestamp = timestamp
            wasCurrentPressCombinedWithSomethingElse = areOtherModifiersDown
            if let lastCleanTapReleaseTimestamp,
               timestamp - lastCleanTapReleaseTimestamp > Self.maximumGapBetweenTapsSeconds {
                self.lastCleanTapReleaseTimestamp = nil
            }
            return false
        }

        if isTappedModifierNowDown && isTappedModifierDown {
            // Another modifier changed while the key is held (e.g. ctrl + option)
            if areOtherModifiersDown {
                wasCurrentPressCombinedWithSomethingElse = true
            }
            return false
        }

        if !isTappedModifierNowDown && isTappedModifierDown {
            isTappedModifierDown = false
            let wasCleanTap = !wasCurrentPressCombinedWithSomethingElse
                && !areOtherModifiersDown
                && timestamp - tappedModifierDownTimestamp <= Self.maximumTapDurationSeconds
            guard wasCleanTap else {
                lastCleanTapReleaseTimestamp = nil
                return false
            }

            if let lastCleanTapReleaseTimestamp,
               tappedModifierDownTimestamp - lastCleanTapReleaseTimestamp <= Self.maximumGapBetweenTapsSeconds {
                self.lastCleanTapReleaseTimestamp = nil
                return true
            }

            lastCleanTapReleaseTimestamp = timestamp
            return false
        }

        // A different modifier was used on its own, which breaks a pending double tap
        if areOtherModifiersDown {
            lastCleanTapReleaseTimestamp = nil
        }
        return false
    }

    /// Feed every regular key press. Typing while the modifier is held (or
    /// between the two taps) means it wasn't a double tap.
    mutating func handleKeyPressed() {
        if isTappedModifierDown {
            wasCurrentPressCombinedWithSomethingElse = true
        }
        lastCleanTapReleaseTimestamp = nil
    }
}
