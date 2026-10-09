//
//  CaptionsToggleCommands.swift
//  leanring-buddy
//
//  Ways to turn captions on and off besides the switch in the menu bar
//  panel: the ctrl + shift + c shortcut, and saying "captions on" /
//  "captions off". Both are handled on the Mac, with no Claude call.
//

import AppKit

nonisolated enum CaptionsToggleShortcut {
    static let displayText = "ctrl + shift + c"
    /// The C key (US layout virtual key code).
    private static let captionsKeyCode: UInt16 = 8

    /// True for a fresh press of ctrl + shift + c. Clicky's keyboard tap only
    /// listens (the frontmost app also gets the keys), so the shortcut avoids
    /// option (ctrl + option starts push-to-talk) and command (common app
    /// shortcuts), and ignores key repeat so holding it doesn't flip back and forth.
    static func isCaptionsTogglePress(
        eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        isAutorepeat: Bool
    ) -> Bool {
        guard eventType == .keyDown, keyCode == captionsKeyCode, !isAutorepeat else { return false }
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
            .intersection(.deviceIndependentFlagsMask)
        return modifierFlags.contains([.control, .shift])
            && modifierFlags.isDisjoint(with: [.option, .command])
    }
}

nonisolated enum CaptionsVoiceCommand {
    /// Longer than this, it's a real question that mentions captions.
    static let maximumWordCount = 5

    private static let turnOnPhrases = ["captions on", "turn on captions", "turn captions on", "show captions", "enable captions"]
    private static let turnOffPhrases = ["captions off", "turn off captions", "turn captions off", "hide captions", "disable captions", "no captions"]

    /// True for "captions on", false for "captions off", nil if the transcript
    /// isn't a captions command.
    static func requestedCaptionsSetting(_ transcript: String) -> Bool? {
        let normalizedWords = transcript.lowercased()
            .replacingOccurrences(of: "caption ", with: "captions ")
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .map { $0 == "caption" ? "captions" : $0 }
        guard !normalizedWords.isEmpty, normalizedWords.count <= maximumWordCount else { return nil }

        let normalizedTranscript = normalizedWords.joined(separator: " ")
        if turnOffPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return false
        }
        if turnOnPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }
        return nil
    }
}
