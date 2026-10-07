//
//  LiveSessionToggleShortcut.swift
//  leanring-buddy
//
//  Detects the fn + control shortcut that starts and ends a live session.
//  The user holds the keys for a moment (see CompanionManager) so a stray
//  tap doesn't toggle the session by accident.
//

import AppKit

nonisolated enum LiveSessionToggleShortcut {
    static let displayText = "fn + control"

    /// Both keys must be held.
    private static let requiredModifierFlags: NSEvent.ModifierFlags = [.function, .control]
    /// If any of these are also held, the user is pressing a different
    /// shortcut (for example ctrl + option push-to-talk while fn happens to be down),
    /// so the live session shortcut doesn't fire.
    private static let disallowedModifierFlags: NSEvent.ModifierFlags = [.option, .command, .shift]

    /// Translates a global keyboard event into a press/release of the
    /// live session shortcut. Only modifier changes (flagsChanged) matter
    /// because the shortcut is modifier-keys only.
    static func shortcutTransition(
        for eventType: CGEventType,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> BuddyPushToTalkShortcut.ShortcutTransition {
        guard eventType == .flagsChanged else { return .none }

        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isShortcutCurrentlyPressed = modifierFlags.contains(requiredModifierFlags)
            && modifierFlags.isDisjoint(with: disallowedModifierFlags)

        if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}
