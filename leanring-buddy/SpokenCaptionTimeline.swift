//
//  SpokenCaptionTimeline.swift
//  leanring-buddy
//
//  Shows what Clicky is saying as captions in its blue bubble, timed to the
//  voice. Spoken instructions are easy to miss (especially for older users
//  or in a noisy room), and reading along helps.
//
//  The answer is split into evenly sized chunks that each fill the caption
//  box (two lines), so the box never looks half empty. Chunks follow the text
//  continuously, like TV subtitles, even across sentence ends.
//
//  Timing comes from ElevenLabs' per-character start times when available:
//  each chunk appears when its first word starts being spoken. Otherwise it's
//  estimated from the share of characters already spoken.
//

import AppKit
import Foundation

nonisolated enum SpokenCaptionTimeline {
    /// The caption box: up to two lines of this width, in the caption font.
    static let captionLineWidth: CGFloat = 260
    static let captionLineCount = 2
    /// Text is fitted a little narrower than the box so the real text layout,
    /// which can differ slightly from this measurement, never needs a third line.
    static let captionFittingSafetyMargin: CGFloat = 10
    static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Claude's answers sometimes contain line breaks between sentences. A
    /// caption starting with a line break rendered as two lines with an empty
    /// one on top, so all whitespace becomes single spaces. Speech is sent in
    /// this form too, so ElevenLabs' character timings line up with captions.
    static func normalizedSpokenText(_ spokenText: String) -> String {
        return spokenText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Splits spoken text into captions for the caption box, using the
    /// caption font to measure.
    static func captionSegments(in spokenText: String) -> [String] {
        return captionSegments(
            in: spokenText,
            maximumLineWidth: captionLineWidth - captionFittingSafetyMargin,
            maximumLineCount: captionLineCount,
            measureTextWidth: { text in
                (text as NSString).size(withAttributes: [.font: captionFont]).width
            }
        )
    }

    /// Splits spoken text into the fewest chunks that each fit in
    /// `maximumLineCount` lines of `maximumLineWidth`, with the words spread
    /// as evenly as possible so every chunk fills the box. The chunks, joined
    /// with spaces, are exactly the (normalized) text.
    static func captionSegments(
        in spokenText: String,
        maximumLineWidth: CGFloat,
        maximumLineCount: Int,
        measureTextWidth: (String) -> CGFloat
    ) -> [String] {
        let words = normalizedSpokenText(spokenText).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }

        func fitsInCaptionBox(_ chunkWords: [String]) -> Bool {
            wrappedLineCount(of: chunkWords, maximumLineWidth: maximumLineWidth, measureTextWidth: measureTextWidth)
                <= maximumLineCount
        }

        // Fewest chunks possible: fill each box as full as it goes
        let fullestChunks = chunkWords(words, maximumChunkWidth: .infinity, fitsInCaptionBox: fitsInCaptionBox, measureTextWidth: measureTextWidth)
        guard fullestChunks.count > 1 else {
            return fullestChunks.map { $0.joined(separator: " ") }
        }

        // Then even them out: find the smallest per-chunk size that still needs
        // only that many chunks. Without this, the last chunk is often a short
        // leftover and the box looks half empty.
        let chunkCount = fullestChunks.count
        let totalSingleLineWidth = measureTextWidth(words.joined(separator: " "))
        var smallestWorkingChunkWidth = maximumLineWidth * CGFloat(maximumLineCount)
        var lowerBoundChunkWidth = totalSingleLineWidth / CGFloat(chunkCount)
        for _ in 0..<24 {
            let candidateChunkWidth = (lowerBoundChunkWidth + smallestWorkingChunkWidth) / 2
            let candidateChunks = chunkWords(words, maximumChunkWidth: candidateChunkWidth, fitsInCaptionBox: fitsInCaptionBox, measureTextWidth: measureTextWidth)
            if candidateChunks.count <= chunkCount {
                smallestWorkingChunkWidth = candidateChunkWidth
            } else {
                lowerBoundChunkWidth = candidateChunkWidth
            }
        }

        let evenChunks = chunkWords(words, maximumChunkWidth: smallestWorkingChunkWidth, fitsInCaptionBox: fitsInCaptionBox, measureTextWidth: measureTextWidth)
        let finalChunks = evenChunks.count <= chunkCount ? evenChunks : fullestChunks
        return finalChunks.map { $0.joined(separator: " ") }
    }

    /// Greedily groups words into chunks: each chunk takes words until the next
    /// one would make it wider than `maximumChunkWidth` (as a single line) or
    /// stop it fitting in the caption box.
    private static func chunkWords(
        _ words: [String],
        maximumChunkWidth: CGFloat,
        fitsInCaptionBox: ([String]) -> Bool,
        measureTextWidth: (String) -> CGFloat
    ) -> [[String]] {
        var chunks: [[String]] = []
        var currentChunkWords: [String] = []
        for word in words {
            let chunkWithWord = currentChunkWords + [word]
            let chunkWithWordFits = fitsInCaptionBox(chunkWithWord)
                && measureTextWidth(chunkWithWord.joined(separator: " ")) <= maximumChunkWidth
            if currentChunkWords.isEmpty || chunkWithWordFits {
                currentChunkWords = chunkWithWord
            } else {
                chunks.append(currentChunkWords)
                currentChunkWords = [word]
            }
        }
        if !currentChunkWords.isEmpty {
            chunks.append(currentChunkWords)
        }
        return chunks
    }

    /// How many lines these words take when wrapped at word boundaries to
    /// `maximumLineWidth`, the same way the caption text wraps on screen.
    static func wrappedLineCount(of words: [String], maximumLineWidth: CGFloat, measureTextWidth: (String) -> CGFloat) -> Int {
        var lineCount = 0
        var currentLine = ""
        for word in words {
            let lineWithWord = currentLine.isEmpty ? word : currentLine + " " + word
            if currentLine.isEmpty || measureTextWidth(lineWithWord) <= maximumLineWidth {
                currentLine = lineWithWord
            } else {
                lineCount += 1
                currentLine = word
            }
        }
        return currentLine.isEmpty ? lineCount : lineCount + 1
    }

    /// The room a caption needs in the caption box: the width of its widest
    /// wrapped line and how many lines it takes. Lets the box hug the text so
    /// it looks full rather than leaving empty space on the right.
    static func captionTextAreaSize(for captionText: String) -> (width: CGFloat, lineCount: Int) {
        let measureTextWidth: (String) -> CGFloat = { text in
            (text as NSString).size(withAttributes: [.font: captionFont]).width
        }
        let maximumLineWidth = captionLineWidth - captionFittingSafetyMargin
        var wrappedLines: [String] = []
        var currentLine = ""
        for word in normalizedSpokenText(captionText).split(separator: " ").map(String.init) {
            let lineWithWord = currentLine.isEmpty ? word : currentLine + " " + word
            if currentLine.isEmpty || measureTextWidth(lineWithWord) <= maximumLineWidth {
                currentLine = lineWithWord
            } else {
                wrappedLines.append(currentLine)
                currentLine = word
            }
        }
        if !currentLine.isEmpty {
            wrappedLines.append(currentLine)
        }
        let widestLineWidth = wrappedLines.map(measureTextWidth).max() ?? 0
        // A little slack so the on-screen layout wraps the same way
        return (min(ceil(widestLineWidth) + 4, captionLineWidth), max(1, min(wrappedLines.count, captionLineCount)))
    }

    /// When each caption starts being spoken, using the per-character start
    /// times ElevenLabs returns for `spokenText`. Returns nil if a caption
    /// can't be found in the text (then estimated timing is used instead).
    static func captionSegmentStartTimes(
        captionSegments: [String],
        spokenText: String,
        characterStartTimes: [Double]
    ) -> [Double]? {
        guard characterStartTimes.count == spokenText.count else { return nil }

        var segmentStartTimes: [Double] = []
        var searchStartIndex = spokenText.startIndex
        for captionSegment in captionSegments {
            guard let segmentRange = spokenText.range(of: captionSegment, range: searchStartIndex..<spokenText.endIndex) else {
                return nil
            }
            let segmentStartCharacterOffset = spokenText.distance(from: spokenText.startIndex, to: segmentRange.lowerBound)
            segmentStartTimes.append(characterStartTimes[segmentStartCharacterOffset])
            searchStartIndex = segmentRange.upperBound
        }
        return segmentStartTimes
    }

    /// Which caption to show at `playbackTimeInSeconds`: the last one that has
    /// started being spoken.
    static func captionSegmentIndex(forPlaybackTime playbackTimeInSeconds: Double, segmentStartTimes: [Double]) -> Int {
        return segmentStartTimes.lastIndex { $0 <= playbackTimeInSeconds } ?? 0
    }

    /// Which caption to show when `playbackProgressFraction` (0 to 1) of the
    /// audio has played, when exact timings aren't available.
    static func captionSegmentIndex(forPlaybackProgress playbackProgressFraction: Double, captionSegments: [String]) -> Int {
        guard !captionSegments.isEmpty else { return 0 }

        let totalCharacterCount = captionSegments.reduce(0) { $0 + $1.count }
        guard totalCharacterCount > 0 else { return 0 }

        var charactersUpToEndOfSegment = 0
        for (segmentIndex, captionSegment) in captionSegments.enumerated() {
            charactersUpToEndOfSegment += captionSegment.count
            if Double(charactersUpToEndOfSegment) / Double(totalCharacterCount) > playbackProgressFraction {
                return segmentIndex
            }
        }
        return captionSegments.count - 1
    }
}
