//
//  ComputerAudioEchoDetector.swift
//  leanring-buddy
//
//  Decides whether something the microphone heard in hands-free mode was
//  really the Mac's own audio (a video, a podcast) coming out of its speakers,
//  by comparing the microphone transcript with a transcript of what the Mac
//  played. Pure logic so it can be unit tested.
//
//  An echo matches one stretch of the computer audio closely, in order. A real
//  question that happens to share common words ("what", "is", "this") with a
//  long video doesn't, because those words are scattered across it. So the
//  comparison only looks at short windows of the computer audio at a time.
//

import Foundation

nonisolated enum ComputerAudioEchoDetector {
    /// At least this many words must line up before calling something an echo,
    /// so a single shared word ("okay") never counts.
    static let minimumMatchingWordCount = 3
    /// At least this share of the heard words must line up with the computer
    /// audio. Below 1.0 because the microphone hears the speakers through the
    /// room, so its transcript has some recognition differences.
    static let minimumMatchedFractionOfHeardWords = 0.6
    /// The computer audio window compared against is this many words longer
    /// than what was heard, leaving room for words the microphone missed.
    static let extraWordsAllowedInMatchingWindow = 4

    static func isLikelyEchoOfComputerAudio(heardText: String, computerAudioText: String) -> Bool {
        let heardWords = normalizedWords(in: heardText)
        let computerAudioWords = normalizedWords(in: computerAudioText)
        guard heardWords.count >= minimumMatchingWordCount, !computerAudioWords.isEmpty else {
            return false
        }

        let matchingWindowLength = heardWords.count + extraWordsAllowedInMatchingWindow
        var bestMatchingWordCount = 0

        // Slide a window over the computer audio and find the stretch that
        // lines up best (in order) with what was heard.
        let lastWindowStartIndex = max(0, computerAudioWords.count - matchingWindowLength)
        for windowStartIndex in 0...lastWindowStartIndex {
            let windowEndIndex = min(computerAudioWords.count, windowStartIndex + matchingWindowLength)
            let computerAudioWindow = Array(computerAudioWords[windowStartIndex..<windowEndIndex])
            let matchingWordCount = longestCommonSubsequenceLength(heardWords, computerAudioWindow)
            bestMatchingWordCount = max(bestMatchingWordCount, matchingWordCount)
            if bestMatchingWordCount == heardWords.count { break }
        }

        let matchedFractionOfHeardWords = Double(bestMatchingWordCount) / Double(heardWords.count)
        return bestMatchingWordCount >= minimumMatchingWordCount
            && matchedFractionOfHeardWords >= minimumMatchedFractionOfHeardWords
    }

    /// Lowercased words with punctuation removed ("Don't stop!" → ["don't", "stop"]).
    static func normalizedWords(in text: String) -> [String] {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
        return text.lowercased()
            .components(separatedBy: allowedCharacters.inverted)
            .filter { !$0.isEmpty }
    }

    /// Number of words that appear in both lists in the same order (not
    /// necessarily next to each other), so a missed or misheard word doesn't
    /// break the match.
    private static func longestCommonSubsequenceLength(_ firstWords: [String], _ secondWords: [String]) -> Int {
        guard !firstWords.isEmpty, !secondWords.isEmpty else { return 0 }

        var previousRow = [Int](repeating: 0, count: secondWords.count + 1)
        for firstWord in firstWords {
            var currentRow = [Int](repeating: 0, count: secondWords.count + 1)
            for (secondWordIndex, secondWord) in secondWords.enumerated() {
                currentRow[secondWordIndex + 1] = firstWord == secondWord
                    ? previousRow[secondWordIndex] + 1
                    : max(previousRow[secondWordIndex + 1], currentRow[secondWordIndex])
            }
            previousRow = currentRow
        }
        return previousRow[secondWords.count]
    }
}
