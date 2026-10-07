//
//  ComputerAudioSpeechTranscriber.swift
//  leanring-buddy
//
//  In hands-free mode, transcribes what the Mac itself is playing (videos,
//  podcasts, calls) so the microphone transcript can be checked against it.
//  If the microphone only heard the Mac's own speakers, the question is
//  dropped instead of being sent to Claude (see ComputerAudioEchoDetector).
//
//  Recognition is on-device only, so the Mac's audio never leaves it. If this
//  Mac can't recognize speech on-device, nothing is transcribed and hands-free
//  simply works without the echo filter.
//

import AVFoundation
import Foundation
import Speech

nonisolated final class ComputerAudioSpeechTranscriber: @unchecked Sendable {
    /// Audio quieter than this (RMS) is treated as silence, so no recognition
    /// runs while the Mac isn't playing anything.
    private static let minimumAudibleRootMeanSquare: Float = 0.005
    /// A recognition task ends after this much silence...
    private static let finishTaskAfterSilenceSeconds: TimeInterval = 4
    /// ...or after this long, to stay well inside the recognizer's time limits.
    private static let finishTaskAfterSeconds: TimeInterval = 45
    /// Transcripts older than this can't matter for an echo check.
    private static let transcriptRetentionSeconds: TimeInterval = 60

    private struct TranscriptSegment {
        var text: String
        let startSystemUptime: TimeInterval
        var endSystemUptime: TimeInterval
    }

    /// Guards every property below. Audio arrives on a ScreenCaptureKit queue
    /// and recognition results on a Speech framework queue.
    private let transcriberStateLock = NSLock()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var isTranscriptionEnabled = false
    private var activeRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeRecognitionTask: SFSpeechRecognitionTask?
    private var activeTaskStartedSystemUptime: TimeInterval = 0
    private var lastAudibleAudioSystemUptime: TimeInterval = 0
    private var transcriptSegments: [TranscriptSegment] = []
    #if DEBUG
    private var hasLoggedFirstComputerAudioBuffer = false
    #endif

    /// Turned on only in hands-free mode; push-to-talk doesn't need it.
    func setTranscriptionEnabled(_ shouldTranscribe: Bool) {
        transcriberStateLock.withLock {
            isTranscriptionEnabled = shouldTranscribe
            if !shouldTranscribe {
                finishActiveTaskWhileLocked()
            }
        }
    }

    func appendComputerAudioBuffer(_ computerAudioBuffer: AVAudioPCMBuffer) {
        let currentSystemUptime = ProcessInfo.processInfo.systemUptime
        let isAudible = Self.rootMeanSquare(of: computerAudioBuffer) >= Self.minimumAudibleRootMeanSquare

        transcriberStateLock.withLock {
            guard isTranscriptionEnabled,
                  let speechRecognizer,
                  speechRecognizer.isAvailable,
                  speechRecognizer.supportsOnDeviceRecognition else {
                return
            }

            #if DEBUG
            if !hasLoggedFirstComputerAudioBuffer {
                hasLoggedFirstComputerAudioBuffer = true
                print("🐞 Computer audio: receiving this Mac's audio (\(Int(computerAudioBuffer.format.sampleRate))Hz, \(computerAudioBuffer.format.channelCount)ch)")
            }
            #endif

            if isAudible {
                lastAudibleAudioSystemUptime = currentSystemUptime
            }

            if activeRecognitionRequest == nil {
                guard isAudible else { return }
                startTaskWhileLocked(speechRecognizer: speechRecognizer, startSystemUptime: currentSystemUptime)
            }

            activeRecognitionRequest?.append(computerAudioBuffer)

            let hasBeenSilentTooLong = currentSystemUptime - lastAudibleAudioSystemUptime >= Self.finishTaskAfterSilenceSeconds
            let hasRunTooLong = currentSystemUptime - activeTaskStartedSystemUptime >= Self.finishTaskAfterSeconds
            if hasBeenSilentTooLong || hasRunTooLong {
                finishActiveTaskWhileLocked()
            }
        }
    }

    /// Everything the Mac was heard saying since `startSystemUptime`.
    func computerAudioText(sinceSystemUptime startSystemUptime: TimeInterval) -> String {
        transcriberStateLock.withLock {
            transcriptSegments
                .filter { $0.endSystemUptime >= startSystemUptime }
                .map(\.text)
                .joined(separator: " ")
        }
    }

    // MARK: - Recognition Tasks (call with the lock held)

    private func startTaskWhileLocked(speechRecognizer: SFSpeechRecognizer, startSystemUptime: TimeInterval) {
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        // Never send the Mac's audio to a server
        recognitionRequest.requiresOnDeviceRecognition = true

        transcriptSegments.removeAll { segment in
            segment.endSystemUptime < startSystemUptime - Self.transcriptRetentionSeconds
        }
        transcriptSegments.append(TranscriptSegment(
            text: "",
            startSystemUptime: startSystemUptime,
            endSystemUptime: startSystemUptime
        ))

        activeRecognitionRequest = recognitionRequest
        activeTaskStartedSystemUptime = startSystemUptime
        activeRecognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] recognitionResult, _ in
            guard let self, let recognitionResult else { return }
            let recognizedText = recognitionResult.bestTranscription.formattedString
            #if DEBUG
            if recognitionResult.isFinal && !recognizedText.isEmpty {
                print("🐞 Computer audio: the Mac said \"\(recognizedText)\"")
            }
            #endif
            let resultSystemUptime = ProcessInfo.processInfo.systemUptime
            self.transcriberStateLock.withLock {
                // The segment list may have been pruned since; match by start time
                guard let matchingSegmentIndex = self.transcriptSegments.firstIndex(where: {
                    $0.startSystemUptime == startSystemUptime
                }) else {
                    return
                }
                self.transcriptSegments[matchingSegmentIndex].text = recognizedText
                self.transcriptSegments[matchingSegmentIndex].endSystemUptime = resultSystemUptime
            }
        }
    }

    private func finishActiveTaskWhileLocked() {
        activeRecognitionRequest?.endAudio()
        activeRecognitionRequest = nil
        activeRecognitionTask = nil
    }

    private static func rootMeanSquare(of audioBuffer: AVAudioPCMBuffer) -> Float {
        guard let channelSamples = audioBuffer.floatChannelData?[0], audioBuffer.frameLength > 0 else { return 0 }
        var summedSquares: Float = 0
        for sampleIndex in 0..<Int(audioBuffer.frameLength) {
            summedSquares += channelSamples[sampleIndex] * channelSamples[sampleIndex]
        }
        return (summedSquares / Float(audioBuffer.frameLength)).squareRoot()
    }
}
