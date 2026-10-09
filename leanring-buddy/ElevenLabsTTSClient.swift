//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Turns Clicky's answers into speech with ElevenLabs and plays them.
//
//  An answer is spoken as a series of pieces (usually its first sentence,
//  then the rest), so Clicky can start talking while Claude is still writing.
//  Each piece's audio is requested the moment its text is known, and the
//  pieces play back to back in order. ElevenLabs is told what came before
//  each piece (`previous_text`) so the voice flows across them.
//

import AVFoundation
import Foundation

@MainActor
final class ElevenLabsTTSClient {
    /// One piece of an answer with its audio, and the time each character
    /// starts being spoken (nil if ElevenLabs didn't send timings).
    struct SpeechSegmentAudio {
        let text: String
        let audioData: Data
        let characterStartTimes: [Double]?
    }

    /// The piece playing right now. `playbackIdentifier` changes every time a
    /// new piece starts, so captions know when to switch to the next piece.
    struct PlayingSpeechSegment {
        let playbackIdentifier: Int
        let text: String
        let characterStartTimes: [Double]?
    }

    private let proxyURL: URL
    /// The Worker route that returns audio plus per-character timings.
    private let timedSpeechProxyURL: URL
    private let session: URLSession

    /// The audio player for the piece playing right now.
    private var audioPlayer: AVAudioPlayer?

    // MARK: - Current Speech

    /// Bumped whenever speech starts or stops, so work belonging to stopped
    /// speech can tell it's out of date and quietly end.
    private var speechGeneration = 0
    private var speechSegmentTexts: [String] = []
    /// Audio requests for each piece, in speaking order. They run at the same
    /// time, so later pieces are usually ready before they're needed.
    private var speechSegmentAudioTasks: [Task<SpeechSegmentAudio, Error>] = []
    /// True once no more pieces will be added to the current speech.
    private var isSpeechTextComplete = false
    private var speechPlaybackTask: Task<Void, Never>?
    private var hasCurrentSpeechStartedPlaying = false
    /// Why the first piece couldn't be spoken (for example, out of credits).
    private var firstSpeechSegmentError: Error?
    private var playbackIdentifierCounter = 0
    private var isReplayingLastSpeech = false

    /// True from the moment speech begins until its last piece finishes playing
    /// (including the short waits between pieces), or until it's stopped.
    private(set) var isSpeaking = false
    private(set) var currentlyPlayingSpeechSegment: PlayingSpeechSegment?
    /// Everything that has started playing in the current speech. Hands-free
    /// mode uses it to recognize Clicky's own voice in the microphone.
    private(set) var textSpokenSoFar = ""

    /// The last thing Clicky said, kept so "say that again" can replay it
    /// without another ElevenLabs request or Claude call.
    private var lastSpeechSegmentAudios: [SpeechSegmentAudio] = []
    var lastSpokenText: String? {
        lastSpeechSegmentAudios.isEmpty ? nil : lastSpeechSegmentAudios.map(\.text).joined(separator: " ")
    }

    init(proxyURL: String, timedSpeechProxyURL: String) {
        self.proxyURL = URL(string: proxyURL)!
        self.timedSpeechProxyURL = URL(string: timedSpeechProxyURL)!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Speaking

    /// Speaks `text` in one piece and returns once the audio starts playing.
    /// Throws if it can't be spoken.
    func speakText(_ text: String) async throws {
        beginSpeech()
        appendSpeechText(text)
        finishSpeechText()
        try await waitUntilSpeechStartsPlaying()
    }

    /// Starts a new speech (stopping anything playing). Add its pieces with
    /// `appendSpeechText` as they become known, then call `finishSpeechText`.
    func beginSpeech() {
        stopPlayback()
        lastSpeechSegmentAudios = []
        isReplayingLastSpeech = false
        startPlaybackLoop()
    }

    /// Adds the next piece of the current speech and requests its audio right away.
    func appendSpeechText(_ text: String) {
        guard isSpeaking, !isSpeechTextComplete else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let previousText = speechSegmentTexts.joined(separator: " ")
        speechSegmentTexts.append(trimmedText)
        speechSegmentAudioTasks.append(Task {
            try await self.fetchSpeechSegmentAudio(text: trimmedText, previousText: previousText)
        })
    }

    /// No more pieces will be added; speech ends after the last one plays.
    func finishSpeechText() {
        isSpeechTextComplete = true
    }

    /// Returns once the current speech's first piece starts playing. Throws
    /// the reason if it couldn't be spoken, or CancellationError if the speech
    /// was stopped (or ended without saying anything) first.
    func waitUntilSpeechStartsPlaying() async throws {
        let speechGenerationBeingWaitedFor = speechGeneration
        while true {
            guard speechGeneration == speechGenerationBeingWaitedFor else { throw CancellationError() }
            if hasCurrentSpeechStartedPlaying { return }
            if let firstSpeechSegmentError { throw firstSpeechSegmentError }
            guard isSpeaking else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Plays the last thing Clicky said again from the saved audio. Returns
    /// false if nothing has been said yet.
    func replayLastSpeech() -> Bool {
        let speechSegmentAudiosToReplay = lastSpeechSegmentAudios
        guard !speechSegmentAudiosToReplay.isEmpty else { return false }

        stopPlayback()
        isReplayingLastSpeech = true
        startPlaybackLoop()
        for speechSegmentAudio in speechSegmentAudiosToReplay {
            speechSegmentTexts.append(speechSegmentAudio.text)
            speechSegmentAudioTasks.append(Task { () throws -> SpeechSegmentAudio in speechSegmentAudio })
        }
        isSpeechTextComplete = true
        print("🔁 ElevenLabs TTS: replaying last speech from saved audio")
        return true
    }

    /// Stops speaking immediately, including pieces not played yet.
    func stopPlayback() {
        speechGeneration += 1
        speechPlaybackTask?.cancel()
        speechPlaybackTask = nil
        for speechSegmentAudioTask in speechSegmentAudioTasks {
            speechSegmentAudioTask.cancel()
        }
        speechSegmentAudioTasks = []
        speechSegmentTexts = []
        isSpeechTextComplete = false
        audioPlayer?.stop()
        audioPlayer = nil
        isSpeaking = false
        currentlyPlayingSpeechSegment = nil
        hasCurrentSpeechStartedPlaying = false
        firstSpeechSegmentError = nil
        textSpokenSoFar = ""
    }

    // MARK: - Playback Progress

    /// Seconds since the current piece started. Nil when no audio is playing
    /// (including between pieces).
    var currentSegmentPlaybackTimeInSeconds: Double? {
        guard let audioPlayer, audioPlayer.isPlaying else { return nil }
        return audioPlayer.currentTime
    }

    /// How far through the current piece playback is, from 0 to 1. Nil when
    /// no audio is playing.
    var currentSegmentPlaybackProgressFraction: Double? {
        guard let audioPlayer, audioPlayer.isPlaying, audioPlayer.duration > 0 else { return nil }
        return min(max(audioPlayer.currentTime / audioPlayer.duration, 0), 1)
    }

    // MARK: - Private

    /// Plays the pieces in order as their audio arrives, until the speech is
    /// complete or stopped.
    private func startPlaybackLoop() {
        speechGeneration += 1
        let speechGenerationForThisLoop = speechGeneration
        isSpeaking = true

        speechPlaybackTask = Task {
            var speechSegmentIndex = 0
            while speechGeneration == speechGenerationForThisLoop {
                // The next piece hasn't been written yet: wait for it, unless
                // the answer is complete
                if speechSegmentIndex >= speechSegmentAudioTasks.count {
                    if isSpeechTextComplete { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                do {
                    let speechSegmentAudio = try await speechSegmentAudioTasks[speechSegmentIndex].value
                    guard speechGeneration == speechGenerationForThisLoop else { return }
                    try playSpeechSegmentAudio(speechSegmentAudio)
                } catch {
                    guard speechGeneration == speechGenerationForThisLoop else { return }
                    print("⚠️ ElevenLabs TTS: couldn't speak piece \(speechSegmentIndex + 1): \(error)")
                    if !hasCurrentSpeechStartedPlaying {
                        // Nothing has been said yet (likely out of credits or
                        // offline), so the rest would fail too
                        firstSpeechSegmentError = error
                        break
                    }
                    speechSegmentIndex += 1
                    continue
                }

                while speechGeneration == speechGenerationForThisLoop, audioPlayer?.isPlaying == true {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                speechSegmentIndex += 1
            }

            if speechGeneration == speechGenerationForThisLoop {
                isSpeaking = false
                currentlyPlayingSpeechSegment = nil
                audioPlayer = nil
            }
        }
    }

    private func playSpeechSegmentAudio(_ speechSegmentAudio: SpeechSegmentAudio) throws {
        let player = try AVAudioPlayer(data: speechSegmentAudio.audioData)
        audioPlayer = player
        player.play()

        playbackIdentifierCounter += 1
        currentlyPlayingSpeechSegment = PlayingSpeechSegment(
            playbackIdentifier: playbackIdentifierCounter,
            text: speechSegmentAudio.text,
            characterStartTimes: speechSegmentAudio.characterStartTimes
        )
        textSpokenSoFar = textSpokenSoFar.isEmpty
            ? speechSegmentAudio.text
            : textSpokenSoFar + " " + speechSegmentAudio.text
        if !isReplayingLastSpeech {
            lastSpeechSegmentAudios.append(speechSegmentAudio)
        }
        hasCurrentSpeechStartedPlaying = true
        print("🔊 ElevenLabs TTS: playing \(speechSegmentAudio.audioData.count / 1024)KB audio\(speechSegmentAudio.characterStartTimes == nil ? " (no timings)" : ""): \"\(speechSegmentAudio.text.prefix(40))\"")
    }

    /// Requests audio for one piece, with per-character timings (same cost),
    /// so captions can follow the voice exactly.
    private func fetchSpeechSegmentAudio(text: String, previousText: String) async throws -> SpeechSegmentAudio {
        var request = URLRequest(url: timedSpeechProxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeSpeechRequestBody(text: text, previousText: previousText))

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            // The timed route may not be deployed on an older Worker: fall
            // back to plain audio, captions then use estimated timing
            print("⚠️ ElevenLabs TTS: timed speech unavailable, using plain audio")
            return try await fetchSpeechSegmentAudioWithoutTimings(text: text, previousText: previousText)
        }

        guard let timedSpeechResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let audioBase64 = timedSpeechResponse["audio_base64"] as? String,
              let audioData = Data(base64Encoded: audioBase64) else {
            throw NSError(domain: "ElevenLabsTTS", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't read timed speech response"])
        }

        // ElevenLabs returns one start time per character of the text sent.
        // Only trust them if they line up one-to-one with our text.
        var characterStartTimes: [Double]? = nil
        if let alignment = timedSpeechResponse["alignment"] as? [String: Any],
           let alignedCharacters = alignment["characters"] as? [String],
           let alignedStartTimes = alignment["character_start_times_seconds"] as? [Double],
           alignedCharacters.count == text.count,
           alignedStartTimes.count == text.count {
            characterStartTimes = alignedStartTimes
        }

        try Task.checkCancellation()
        return SpeechSegmentAudio(text: text, audioData: audioData, characterStartTimes: characterStartTimes)
    }

    /// Plain audio without timings (the original endpoint).
    private func fetchSpeechSegmentAudioWithoutTimings(text: String, previousText: String) async throws -> SpeechSegmentAudio {
        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeSpeechRequestBody(text: text, previousText: previousText))

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabsTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ElevenLabsTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        try Task.checkCancellation()
        return SpeechSegmentAudio(text: text, audioData: data, characterStartTimes: nil)
    }

    private func makeSpeechRequestBody(text: String, previousText: String) -> [String: Any] {
        var body: [String: Any] = [
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75
            ]
        ]
        // Lets ElevenLabs continue the voice naturally from the previous piece
        // (only the new text is spoken)
        if !previousText.isEmpty {
            body["previous_text"] = previousText
        }
        return body
    }
}
