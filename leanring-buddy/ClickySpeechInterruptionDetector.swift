//
//  ClickySpeechInterruptionDetector.swift
//  leanring-buddy
//
//  In hands-free mode the microphone keeps listening while Clicky talks, so
//  the user can talk over it ("wait", or a new question) the way they would
//  with a person. The catch: through the speakers, the microphone also hears
//  Clicky itself. This works out which heard words are the user's.
//
//  Clicky knows exactly what it's saying, so the microphone transcript is
//  lined up against that text. Words that line up in runs of two or more,
//  in order, are Clicky's own voice. The user's words are whatever comes
//  after the last such run (people talk over the end of what they're hearing,
//  not the middle). A single shared word ("the") doesn't count as a run, so
//  it can't swallow the user's question. Pure logic so it can be unit tested.
//

import Foundation

nonisolated enum ClickySpeechInterruptionDetector {
    /// Whether the user's words are enough to stop Clicky. (While Clicky's
    /// voice is playing, CompanionManager only stops it for a stop word,
    /// since the microphone's transcript of Clicky's own voice through
    /// speakers is too unreliable to react to any word.)
    enum InterruptionResponse: Equatable {
        /// Nothing the user said yet.
        case none
        /// A single word: not enough on its own, wait for more.
        case oneWordSoFar
        /// Two or more words, or a clear stop word: stop talking and listen.
        case stopClicky
    }

    /// This many of the user's own words stop Clicky...
    static let minimumUserWordCountToStop = 2
    /// ...or just one of these. Short, clear ways to say "stop talking" or
    /// to get Clicky's attention ("wait", "hold up", "one sec", "Clicky").
    private static let stopWords: Set<String> = [
        "stop", "wait", "hold", "pause", "sec", "cancel", "clicky", "heyclicky"
    ]
    /// What people say when they only want Clicky to stop, not ask something.
    /// An interruption made only of these words isn't sent to Claude.
    private static let stopOnlyWords: Set<String> = stopWords.union([
        "up", "on", "one", "hang", "hey", "never", "mind", "nevermind", "okay", "ok", "please",
        "thanks", "thank", "you", "a", "sec", "second", "moment", "minute", "got", "it"
    ])

    /// The heard words that aren't Clicky's own voice coming back through the
    /// microphone (lowercased, punctuation removed).
    static func userWords(heardText: String, clickySpeechText: String) -> [String] {
        let heardWords = ComputerAudioEchoDetector.normalizedWords(in: heardText)
        let clickyWords = ComputerAudioEchoDetector.normalizedWords(in: clickySpeechText)
        guard !heardWords.isEmpty, !clickyWords.isEmpty else { return heardWords }

        let matchedClickyWordIndexForHeardWord = longestCommonSubsequenceMatches(heardWords, clickyWords)

        // A heard word is Clicky's echo only if a neighbor lines up right next
        // to it too (a run of at least two words)
        var lastEchoHeardWordIndex: Int? = nil
        for heardWordIndex in heardWords.indices {
            guard let matchedClickyWordIndex = matchedClickyWordIndexForHeardWord[heardWordIndex] else { continue }
            let previousWordContinuesRun = heardWordIndex > 0
                && matchedClickyWordIndexForHeardWord[heardWordIndex - 1] == matchedClickyWordIndex - 1
            let nextWordContinuesRun = heardWordIndex + 1 < heardWords.count
                && matchedClickyWordIndexForHeardWord[heardWordIndex + 1] == matchedClickyWordIndex + 1
            if previousWordContinuesRun || nextWordContinuesRun {
                lastEchoHeardWordIndex = heardWordIndex
            }
        }

        guard let lastEchoHeardWordIndex else { return heardWords }
        return Array(heardWords[(lastEchoHeardWordIndex + 1)...])
    }

    /// The heard words that are really the user's, for deciding whether
    /// they're talking over Clicky. Stricter than `userWords`: the microphone
    /// transcript of Clicky's voice is often slightly off, and each stray word
    /// made Clicky fade out and back in. Seen in testing:
    /// - cut off mid-word while still being recognized: "gi" for "github", "far" for "farza"
    /// - a different ending: "source" for "sourced", "click" for "clicky"
    /// - an answer's first word, before a second word can line up with it ("yeah")
    /// So any heard word that looks like one of Clicky's words is dropped too.
    /// Stop words still count, unless Clicky itself said that word.
    static func userWordsWhileClickyTalks(heardText: String, clickySpeechText: String) -> [String] {
        let clickyWords = wordsClickyMightBeHeardSaying(clickySpeechText)
        guard !clickyWords.isEmpty else {
            return ComputerAudioEchoDetector.normalizedWords(in: heardText)
        }
        return userWords(heardText: heardText, clickySpeechText: clickySpeechText).filter { heardWord in
            if stopWords.contains(heardWord) && !clickyWords.contains(heardWord) {
                return true
            }
            return !isLikelyMisheardClickyWord(heardWord, clickyWords: clickyWords)
        }
    }

    /// Clicky's words as the microphone might transcribe them. Clicky's text
    /// has digits ("7.7k stars") but the microphone hears words ("seven point
    /// seven k"), so numbers are added spelled out.
    static func wordsClickyMightBeHeardSaying(_ clickySpeechText: String) -> Set<String> {
        var clickyWords = Set(ComputerAudioEchoDetector.normalizedWords(in: clickySpeechText))
        guard clickySpeechText.contains(where: \.isNumber) else { return clickyWords }

        let numberSpeller = NumberFormatter()
        numberSpeller.locale = Locale(identifier: "en_US")
        numberSpeller.numberStyle = .spellOut
        for digitRun in clickySpeechText.split(whereSeparator: { !$0.isNumber }) {
            guard let number = Int(digitRun), let spelledNumber = numberSpeller.string(from: NSNumber(value: number)) else { continue }
            clickyWords.formUnion(ComputerAudioEchoDetector.normalizedWords(in: spelledNumber.replacingOccurrences(of: "-", with: " ")))
        }
        // How numbers like "7.7k" or "45%" are read out
        clickyWords.formUnion(["point", "k", "thousand", "hundred", "million", "percent"])
        return clickyWords
    }

    /// Whether a heard word looks like one of Clicky's words:
    /// - the same word
    /// - the start of one, because recognition hasn't finished it yet ("gi" / "github")
    /// - a word that starts with a Clicky word ("clicks" / "click")
    /// - the same stem with a different ending ("clicking" / "clicky")
    /// - one letter off, as a whole word ("colour" / "color") or as the start
    ///   of one ("get" / "git…" in "github")
    static func isLikelyMisheardClickyWord(_ heardWord: String, clickyWords: Set<String>) -> Bool {
        if clickyWords.contains(heardWord) { return true }
        for clickyWord in clickyWords {
            if heardWord.count >= 2 && clickyWord.hasPrefix(heardWord) { return true }
            if clickyWord.count >= 4 && heardWord.hasPrefix(clickyWord) { return true }

            let sharedStartLength = zip(heardWord, clickyWord).prefix { $0 == $1 }.count
            if sharedStartLength >= 4 && sharedStartLength >= min(heardWord.count, clickyWord.count) - 2 { return true }

            if heardWord.count >= 4 && clickyWord.count >= 4
                && isAtMostOneEditApart(heardWord, clickyWord) {
                return true
            }
            if heardWord.count >= 3 && clickyWord.count > heardWord.count
                && isAtMostOneEditApart(heardWord, String(clickyWord.prefix(heardWord.count))) {
                return true
            }
        }
        return false
    }

    /// Whether the user said a clear stop word ("wait", "stop", "Clicky"),
    /// which Clicky reacts to right away instead of waiting to be sure.
    static func containsStopWord(_ userWords: [String]) -> Bool {
        return userWords.contains { stopWords.contains($0) }
    }

    /// True if one letter added, removed, or changed turns one word into the other.
    private static func isAtMostOneEditApart(_ firstWord: String, _ secondWord: String) -> Bool {
        let firstCharacters = Array(firstWord)
        let secondCharacters = Array(secondWord)
        guard abs(firstCharacters.count - secondCharacters.count) <= 1 else { return false }

        var firstIndex = 0
        var secondIndex = 0
        var editCount = 0
        while firstIndex < firstCharacters.count && secondIndex < secondCharacters.count {
            if firstCharacters[firstIndex] == secondCharacters[secondIndex] {
                firstIndex += 1
                secondIndex += 1
                continue
            }
            editCount += 1
            if editCount > 1 { return false }
            if firstCharacters.count > secondCharacters.count {
                firstIndex += 1
            } else if firstCharacters.count < secondCharacters.count {
                secondIndex += 1
            } else {
                firstIndex += 1
                secondIndex += 1
            }
        }
        let remainingCharacterCount = (firstCharacters.count - firstIndex) + (secondCharacters.count - secondIndex)
        return editCount + remainingCharacterCount <= 1
    }

    static func interruptionResponse(toUserWords userWords: [String]) -> InterruptionResponse {
        if userWords.count >= minimumUserWordCountToStop || userWords.contains(where: { stopWords.contains($0) }) {
            return .stopClicky
        }
        return userWords.isEmpty ? .none : .oneWordSoFar
    }

    /// True for "wait", "hold up", "one sec", "hey Clicky", "never mind": the
    /// user only wanted Clicky to stop, so nothing is sent to Claude.
    static func isOnlyAskingClickyToStop(userWords: [String]) -> Bool {
        return !userWords.isEmpty && userWords.allSatisfy { stopOnlyWords.contains($0) }
    }

    /// For each heard word, the index of the Clicky word it lines up with in
    /// the longest in-order match, or nil if it doesn't line up with any.
    private static func longestCommonSubsequenceMatches(_ heardWords: [String], _ clickyWords: [String]) -> [Int?] {
        let heardWordCount = heardWords.count
        let clickyWordCount = clickyWords.count
        // matchLengths[h][c] = longest match between heardWords[h...] and clickyWords[c...]
        var matchLengths = [[Int]](repeating: [Int](repeating: 0, count: clickyWordCount + 1), count: heardWordCount + 1)
        for heardWordIndex in stride(from: heardWordCount - 1, through: 0, by: -1) {
            for clickyWordIndex in stride(from: clickyWordCount - 1, through: 0, by: -1) {
                matchLengths[heardWordIndex][clickyWordIndex] = heardWords[heardWordIndex] == clickyWords[clickyWordIndex]
                    ? matchLengths[heardWordIndex + 1][clickyWordIndex + 1] + 1
                    : max(matchLengths[heardWordIndex + 1][clickyWordIndex], matchLengths[heardWordIndex][clickyWordIndex + 1])
            }
        }

        var matchedClickyWordIndexForHeardWord = [Int?](repeating: nil, count: heardWordCount)
        var heardWordIndex = 0
        var clickyWordIndex = 0
        while heardWordIndex < heardWordCount && clickyWordIndex < clickyWordCount {
            if heardWords[heardWordIndex] == clickyWords[clickyWordIndex] {
                matchedClickyWordIndexForHeardWord[heardWordIndex] = clickyWordIndex
                heardWordIndex += 1
                clickyWordIndex += 1
            } else if matchLengths[heardWordIndex + 1][clickyWordIndex] >= matchLengths[heardWordIndex][clickyWordIndex + 1] {
                heardWordIndex += 1
            } else {
                clickyWordIndex += 1
            }
        }
        return matchedClickyWordIndexForHeardWord
    }
}
