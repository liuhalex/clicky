//
//  RepeatLastAnswerRequest.swift
//  leanring-buddy
//
//  Recognizes "say that again" style requests so Clicky can replay its last
//  answer from the saved audio instead of asking Claude again. Free, instant,
//  and the user hears exactly the same words.
//

import Foundation

nonisolated enum RepeatLastAnswerRequest {
    /// Longer than this, it's a real question that happens to contain one of
    /// the phrases ("repeat the steps for exporting a pdf...").
    static let maximumWordCount = 7

    private static let repeatRequestPhrases = [
        "say that again", "say it again", "say again",
        "repeat that", "repeat it", "repeat yourself", "can you repeat", "could you repeat",
        "what did you say", "come again", "one more time"
    ]

    static func isAskingToRepeatLastAnswer(_ transcript: String) -> Bool {
        let normalizedWords = transcript.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        guard !normalizedWords.isEmpty, normalizedWords.count <= maximumWordCount else { return false }

        let normalizedTranscript = normalizedWords.joined(separator: " ")
        if normalizedTranscript == "repeat" || normalizedTranscript == "repeat please" {
            return true
        }
        return repeatRequestPhrases.contains { repeatRequestPhrase in
            normalizedTranscript.contains(repeatRequestPhrase)
        }
    }
}
