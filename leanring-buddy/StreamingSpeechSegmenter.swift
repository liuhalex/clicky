//
//  StreamingSpeechSegmenter.swift
//  leanring-buddy
//
//  Lets Clicky start talking before Claude has finished writing the answer.
//  Claude's text streams in a few words at a time. As soon as the first
//  complete sentence is in, it goes to ElevenLabs and starts playing, while
//  the rest of the answer is still being written. Without this, Clicky waited
//  for the whole answer and then for audio of the whole answer.
//
//  The first piece is kept short (one sentence) because it decides how soon
//  Clicky starts talking. Later pieces are longer, since they're ready well
//  before the first one finishes playing, and longer pieces sound smoother.
//
//  Text from the first "[" on is held back until the answer is complete: it's
//  the [POINT:...] tag at the end, or a [SILENT] reply in hands-free mode,
//  neither of which should be read aloud. Pure logic so it can be unit tested.
//

import Foundation

nonisolated struct StreamingSpeechSegmenter {
    /// The first piece is spoken as soon as it has a complete sentence at
    /// least this long, so a lone "Sure." waits for the next sentence.
    static let minimumFirstSegmentCharacterCount = 20
    /// Later pieces wait for at least this much text.
    static let minimumLaterSegmentCharacterCount = 60

    /// How many characters of the streamed text have already been handed to speech.
    private var releasedStreamedCharacterCount = 0
    /// Everything handed to speech so far, normalized and joined with spaces.
    private(set) var releasedSpeechText = ""

    /// Called with all the text streamed so far. Returns the next piece ready
    /// to be spoken, or nil if there isn't a long enough complete sentence yet.
    mutating func nextSegmentReadyToSpeak(streamedTextSoFar: String) -> String? {
        let streamedCharacters = Array(streamedTextSoFar)
        // Nothing from a "[" on can be spoken until the answer is complete
        let speakableCharacterCount = streamedCharacters.firstIndex(of: "[") ?? streamedCharacters.count
        guard speakableCharacterCount > releasedStreamedCharacterCount else { return nil }

        let sentenceEndCharacterCounts = Self.sentenceEndCharacterCounts(
            in: streamedCharacters,
            from: releasedStreamedCharacterCount,
            upTo: speakableCharacterCount
        )
        let isFirstSegment = releasedSpeechText.isEmpty
        let minimumCharacterCount = isFirstSegment
            ? Self.minimumFirstSegmentCharacterCount
            : Self.minimumLaterSegmentCharacterCount

        // The first piece ends at the earliest sentence end that makes it long
        // enough (shorter means Clicky starts talking sooner). Later pieces
        // take every complete sentence available (longer sounds smoother).
        let candidateEndCharacterCounts = isFirstSegment ? sentenceEndCharacterCounts : sentenceEndCharacterCounts.reversed()
        for sentenceEndCharacterCount in candidateEndCharacterCounts {
            let candidateSegment = SpokenCaptionTimeline.normalizedSpokenText(
                String(streamedCharacters[releasedStreamedCharacterCount..<sentenceEndCharacterCount])
            )
            if candidateSegment.count >= minimumCharacterCount {
                releasedStreamedCharacterCount = sentenceEndCharacterCount
                appendToReleasedSpeechText(candidateSegment)
                return candidateSegment
            }
            // Later pieces: the longest candidate is too short, so all are
            if !isFirstSegment { return nil }
        }
        return nil
    }

    /// Called once when the answer is complete, with the text to speak (the
    /// [POINT:...] tag already removed). Returns whatever hasn't been spoken
    /// yet, or nil if everything has.
    mutating func remainingSegmentToSpeak(finalSpokenText: String) -> String? {
        let normalizedFinalSpokenText = SpokenCaptionTimeline.normalizedSpokenText(finalSpokenText)
        guard normalizedFinalSpokenText.hasPrefix(releasedSpeechText) else {
            // Shouldn't happen (spoken pieces always come from the start of the
            // answer). Saying nothing more beats repeating what was already said.
            return nil
        }
        let remainingSegment = String(normalizedFinalSpokenText.dropFirst(releasedSpeechText.count))
            .trimmingCharacters(in: .whitespaces)
        guard !remainingSegment.isEmpty else { return nil }

        appendToReleasedSpeechText(remainingSegment)
        return remainingSegment
    }

    private mutating func appendToReleasedSpeechText(_ segment: String) {
        releasedSpeechText = releasedSpeechText.isEmpty ? segment : releasedSpeechText + " " + segment
    }

    /// The character counts up to and including each sentence ending in the
    /// given range, in order: a ".", "!" or "?" followed by a space or line
    /// break, or a line break itself. The space requirement keeps "3.5" or a
    /// half-streamed "e.g" from counting.
    private static func sentenceEndCharacterCounts(
        in characters: [Character],
        from startCharacterIndex: Int,
        upTo endCharacterIndex: Int
    ) -> [Int] {
        var sentenceEndCharacterCounts: [Int] = []
        var characterIndex = startCharacterIndex
        while characterIndex < endCharacterIndex {
            let character = characters[characterIndex]
            let nextCharacterIndex = characterIndex + 1
            if character.isNewline {
                sentenceEndCharacterCounts.append(nextCharacterIndex)
            } else if ".!?".contains(character),
                      nextCharacterIndex < endCharacterIndex,
                      characters[nextCharacterIndex].isWhitespace {
                sentenceEndCharacterCounts.append(nextCharacterIndex)
            }
            characterIndex += 1
        }
        return sentenceEndCharacterCounts
    }
}
