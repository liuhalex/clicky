//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Live Session State

    /// True while hands-free mode is on (toggled by holding fn + control).
    /// Internally this is a "live session": the screen and the Mac's audio are
    /// watched continuously and the microphone listens whenever Clicky is quiet.
    @Published private(set) var isLiveSessionActive = false
    /// Short status message shown next to the cursor ("hands-free on",
    /// "hands-free off · 3 questions sent", ...). Nil when nothing is showing.
    @Published private(set) var liveSessionStatusBubbleText: String?
    /// Where the element Claude pointed at is right now (global AppKit coords),
    /// updated as the user scrolls or moves the window. Nil when nothing is
    /// being tracked. BlueCursorView moves the pointing buddy to follow it.
    @Published private(set) var liveTrackedElementScreenLocation: CGPoint?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL = "http://localhost:8787"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// How long fn + control must be held to turn hands-free on or off.
    /// Long enough that brushing the keys doesn't toggle it by accident.
    private static let liveSessionToggleHoldDurationSeconds: Double = 0.6
    /// If the tracked element can't be found for this long (scrolled away,
    /// covered, page changed), the buddy stops pointing and comes back.
    private static let liveTrackedElementLostAfterSeconds: Double = 0.6
    /// A click this close (in points) to the tracked element counts as the
    /// user clicking it, which ends the pointing.
    private static let liveTrackedElementClickDismissRadiusInPoints: CGFloat = 60

    private var liveSessionShortcutTransitionCancellable: AnyCancellable?
    private var pendingLiveSessionToggleTask: Task<Void, Never>?
    /// Prevents a second toggle while the screen stream is still starting or stopping.
    private var isLiveSessionStartingOrStopping = false
    private var liveSessionScreenWatcher: LiveSessionScreenWatcher?
    /// Started when the tracked element goes missing; fires the "lost" handling
    /// unless the element is found again first.
    private var liveTrackedElementLostTask: Task<Void, Never>?
    /// Claude's short label for the tracked element (e.g. "save button"), used
    /// when telling the user where it went.
    private var liveTrackedElementLabel: String?
    /// Where the tracked element was heading the last time it went missing.
    /// Updated on every missed frame so the announcement uses the latest motion.
    private var liveTrackedElementLastSeenPosition: TrackedElementLastSeenPosition?
    /// Speaks "it scrolled off the top…" once any answer finishes playing.
    /// Cancelled when the user starts a new push-to-talk.
    private var lostTrackedElementAnnouncementTask: Task<Void, Never>?
    /// True from when the lost-element announcement starts playing until it
    /// finishes, so it can be cut short if the user scrolls the element back.
    private var isLostTrackedElementAnnouncementSpeaking = false

    /// After the tracked element is lost, keep looking for it this long. If the
    /// user scrolls back to it, the buddy flies back and points at it again.
    private static let lostTrackedElementSearchDurationSeconds: Double = 20
    /// True while the element is lost but still being looked for. The buddy
    /// isn't pointing, but the tracker and scroll estimate keep running.
    private var isSearchingForLostTrackedElement = false
    private var lostTrackedElementSearchStartedDate = Date.distantPast
    private var liveSessionStatusBubbleHideTask: Task<Void, Never>?
    private var liveSessionMouseClickMonitor: Any?
    /// True while the screen is being watched outside a live session, only so
    /// the pointer can follow the element Clicky is pointing at. Stops once
    /// the pointing is over.
    private var isWatchingScreenForCurrentPoint = false
    /// Watches trackpad / scroll wheel events during a session so the buddy
    /// moves with scrolled content instantly instead of waiting for frames.
    private var liveSessionScrollWheelMonitor: Any?
    /// Combines instant scroll events with frame measurements into where the
    /// tracked element is right now. Nil when nothing is being tracked.
    private var liveTrackedElementPositionEstimator: TrackedElementPositionEstimator?
    /// The display the tracked element is on. Scrolling on another display
    /// can't move it, so those scroll events are ignored.
    private var liveTrackedElementDisplayFrame: CGRect?

    /// Like Clicky outside a session, the buddy points at an element while
    /// explaining it, then lets go. It holds on for this long after Clicky
    /// stops talking, and scrolling restarts the countdown so the buddy stays
    /// with the element while the user is still looking for it.
    private static let liveTrackedElementHoldAfterActivitySeconds: Double = 4
    /// Last time Clicky talked about the tracked element or the user scrolled.
    private var liveTrackedElementLastActivityDate = Date.distantPast

    /// Checks every 100ms during a session: runs hands-free listening, lets go
    /// of the tracked element after the explanation, and ends idle sessions.
    private var liveSessionSupervisorTask: Task<Void, Never>?
    /// A session nobody talks to for this long ends itself, so the screen
    /// stream and microphone never stay on forgotten in the background.
    private static let liveSessionAutoEndAfterIdleSeconds: Double = 10 * 60
    /// Last time the user asked something (or started talking) in this session.
    private var liveSessionLastActivityDate = Date.distantPast
    /// How many questions went to Claude this session, shown when it ends so
    /// the user can see exactly what the session cost.
    private var liveSessionQuestionCount = 0

    // MARK: - Hands-Free Listening State

    /// After words have been heard, this much silence (no transcript changes)
    /// ends the question and sends it.
    private static let handsFreeSilenceSecondsToEndUtterance: Double = 1.2
    /// Speech recognition sessions have time limits, so a listening session
    /// that hears nothing for this long is quietly restarted.
    private static let handsFreeListeningRestartAfterSecondsWithoutSpeech: Double = 50
    /// Shorter transcripts ("hm", "okay") are background noise or filler, not
    /// questions, and are never sent to Claude.
    private static let handsFreeMinimumWordCountToSend = 2

    /// True while the microphone is listening hands-free (started by the
    /// session, not by push-to-talk). Shares BuddyDictationManager with push-to-talk.
    private var isHandsFreeDictationActive = false
    private var isHandsFreeDictationStarting = false
    /// Becomes true once the transcript has words in it. Until then the buddy
    /// shows normally instead of the listening waveform.
    private var hasHandsFreeListeningHeardSpeech = false
    private var handsFreeDictationStartedDate = Date.distantPast
    private var handsFreeLastSeenTranscript = ""
    private var handsFreeLastTranscriptChangeDate = Date.distantPast
    /// Backs off retries if listening fails to start (for example, dictation turned off).
    private var handsFreeNextStartAllowedDate = Date.distantPast
    /// When words were first heard in the current hands-free utterance (system
    /// uptime, the same clock the computer audio transcript uses).
    private var handsFreeSpeechStartedSystemUptime: TimeInterval = 0
    /// Transcribes what the Mac itself is playing so hands-free mode can tell
    /// the user's voice apart from a video or podcast coming out of the speakers.
    private var computerAudioSpeechTranscriber: ComputerAudioSpeechTranscriber?
    /// How far before the user started talking to look in the computer audio
    /// transcript, since the microphone picks up the speakers with a small delay
    /// and recognition of the two streams finishes at slightly different times.
    private static let computerAudioEchoLookbackSeconds: TimeInterval = 4

    /// True from the moment a transcript is sent to Claude until the answer
    /// finishes or fails. Hands-free listening stays paused meanwhile so it
    /// never hears Clicky's own voice. The generation number keeps a cancelled,
    /// superseded answer from clearing the flag of the newer one.
    private var isResponsePipelineRunning = false
    private var responsePipelineGeneration = 0

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindLiveSessionShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Called by the overlay when the buddy finishes flying back to the cursor.
    /// Clears the pointing target, but a lost live-session element keeps being
    /// searched for so the buddy can return if the user scrolls back to it.
    func handleBuddyReturnedToCursor() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        if !isSearchingForLostTrackedElement {
            stopLiveElementTracking()
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        stopLiveElementTracking()
    }

    func stop() {
        if let liveSessionScreenWatcherToStop = liveSessionScreenWatcher {
            Task { await liveSessionScreenWatcherToStop.stop() }
        }
        liveSessionShortcutTransitionCancellable?.cancel()
        pendingLiveSessionToggleTask?.cancel()
        liveSessionSupervisorTask?.cancel()
        removeLiveSessionMouseClickMonitor()
        removeLiveSessionScrollWheelMonitor()

        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                // Hands-free listening runs quietly in the background. Keep the
                // normal buddy (not the waveform or spinner) until the user
                // actually starts talking; the supervisor switches to .listening then.
                if self.isHandsFreeDictationActive && !self.hasHandsFreeListeningHeardSpeech {
                    self.voiceState = .idle
                    return
                }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            // In a live session the microphone may already be listening hands-free.
            // Push-to-talk still works and takes over the microphone.
            if isHandsFreeDictationActive {
                cancelHandsFreeDictation()
            }
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            lostTrackedElementAnnouncementTask?.cancel()
            lostTrackedElementAnnouncementTask = nil
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Added to the system prompt only for hands-free questions. With the
    /// microphone open, Clicky overhears things that aren't meant for it (a
    /// conversation with someone else, a call, a video). Claude is much better
    /// than any keyword rule at telling those apart from a real question.
    private static let handsFreeOverheardSpeechInstructions = """
    hands-free mode:
    the microphone is open, so this may not have been said to you. the user might be talking to someone else, on a call, reading something aloud, thinking out loud, or it might be audio from a video. only respond if the user is clearly talking to you — asking you something, or continuing your conversation. if they're not, reply with exactly [SILENT] and nothing else. never comment on what's on screen unless the user asked.
    """

    /// The exact reply Claude gives when hands-free speech wasn't meant for Clicky.
    private static let overheardSpeechSilentReply = "[SILENT]"

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    /// `wasHeardHandsFree` is true when the transcript came from hands-free
    /// listening rather than push-to-talk, so it may not have been meant for Clicky.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String, wasHeardHandsFree: Bool = false) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        responsePipelineGeneration += 1
        let thisResponsePipelineGeneration = responsePipelineGeneration
        isResponsePipelineRunning = true
        isLostTrackedElementAnnouncementSpeaking = false

        if isLiveSessionActive {
            liveSessionQuestionCount += 1
            liveSessionLastActivityDate = Date()
        }

        currentResponseTask = Task {
            defer {
                if responsePipelineGeneration == thisResponsePipelineGeneration {
                    isResponsePipelineRunning = false
                }
            }

            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // During a live session, use the frames the stream already has
                // (no screenshot delay) and remember which frame each image came
                // from, so tracking starts on the exact image Claude saw.
                // Otherwise capture all connected screens so the AI has full context.
                let screenCaptures: [CompanionScreenCapture]
                var liveFramesSentToClaude: [LiveScreenFrame] = []
                if isLiveSessionActive,
                   let latestLiveCaptures = liveSessionScreenWatcher?.makeScreenCapturesFromLatestFrames() {
                    screenCaptures = latestLiveCaptures.screenCaptures
                    liveFramesSentToClaude = latestLiveCaptures.framesInSameOrder
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }
                // Same clock as frame and scroll-event timestamps, for tracking
                let screenCaptureSystemUptime = ProcessInfo.processInfo.systemUptime

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: wasHeardHandsFree
                        ? Self.companionVoiceResponseSystemPrompt + "\n\n" + Self.handsFreeOverheardSpeechInstructions
                        : Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Overheard speech that wasn't meant for Clicky: say nothing,
                // point at nothing, and keep it out of the conversation history.
                if wasHeardHandsFree
                    && fullResponseText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(Self.overheardSpeechSilentReply) {
                    print("🤫 Hands-free: \"\(transcript)\" wasn't meant for Clicky, staying quiet")
                    voiceState = .idle
                    scheduleTransientHideIfNeeded()
                    return
                }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCaptureIndex: Int? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenNumber - 1
                    }
                    return screenCaptures.firstIndex(where: { $0.isCursorScreen })
                }()
                let targetScreenCapture = targetScreenCaptureIndex.map { screenCaptures[$0] }

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Clamp to screenshot coordinate space
                    let clampedScreenshotPixelLocation = CGPoint(
                        x: max(0, min(pointCoordinate.x, CGFloat(targetScreenCapture.screenshotWidthInPixels))),
                        y: max(0, min(pointCoordinate.y, CGFloat(targetScreenCapture.screenshotHeightInPixels)))
                    )

                    let globalLocation = Self.convertScreenshotPixelLocationToGlobalScreenLocation(
                        screenshotPixelLocation: clampedScreenshotPixelLocation,
                        screenshotWidthInPixels: targetScreenCapture.screenshotWidthInPixels,
                        screenshotHeightInPixels: targetScreenCapture.screenshotHeightInPixels,
                        displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                        displayHeightInPoints: targetScreenCapture.displayHeightInPoints,
                        displayFrame: targetScreenCapture.displayFrame
                    )

                    // In a live session, keep following the element as the screen
                    // changes. Start tracking before publishing the location so the
                    // first tracking update can't arrive before the buddy takes off.
                    if let targetScreenCaptureIndex,
                       targetScreenCaptureIndex < liveFramesSentToClaude.count {
                        startLiveElementTracking(
                            referenceFrame: liveFramesSentToClaude[targetScreenCaptureIndex],
                            targetLocationInScreenshotPixels: clampedScreenshotPixelLocation,
                            initialGlobalLocation: globalLocation,
                            elementLabel: parseResult.elementLabel
                        )
                    }

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = targetScreenCapture.displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    #if DEBUG
                    PointingDebugRecorder.recordPointing(
                        screenshotImageData: targetScreenCapture.imageData,
                        screenshotLabel: targetScreenCapture.label,
                        pointInScreenshotPixels: clampedScreenshotPixelLocation,
                        elementLabel: parseResult.elementLabel,
                        userTranscript: transcript,
                        claudeResponseText: fullResponseText,
                        isLiveSessionActive: isLiveSessionActive
                    )
                    #endif
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")

                    // Outside a live session, watch the screen just while
                    // pointing so the pointer follows the element too.
                    if !isLiveSessionActive {
                        await startFollowingPointedElementOutsideSession(
                            screenshotImageData: targetScreenCapture.imageData,
                            screenshotCaptureSystemUptime: screenCaptureSystemUptime,
                            displayFrame: targetScreenCapture.displayFrame,
                            targetLocationInScreenshotPixels: clampedScreenshotPixelLocation,
                            initialGlobalLocation: globalLocation,
                            elementLabel: parseResult.elementLabel
                        )
                    }
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        // During a live session the buddy stays on screen the whole time,
        // even when "Show Clicky" is off. Ending the session schedules the hide.
        guard !isClickyCursorEnabled && isOverlayVisible && !isLiveSessionActive else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Live Session

    private func bindLiveSessionShortcutTransitions() {
        liveSessionShortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .liveSessionShortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleLiveSessionShortcutTransition(transition)
            }
    }

    /// The session only toggles after fn + control has been held for
    /// liveSessionToggleHoldDurationSeconds. Releasing earlier cancels it.
    private func handleLiveSessionShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            pendingLiveSessionToggleTask?.cancel()
            pendingLiveSessionToggleTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.liveSessionToggleHoldDurationSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await toggleLiveSession()
            }
        case .released:
            pendingLiveSessionToggleTask?.cancel()
            pendingLiveSessionToggleTask = nil
        case .none:
            break
        }
    }

    func toggleLiveSession() async {
        if isLiveSessionActive {
            await endLiveSession()
        } else {
            await startLiveSession()
        }
    }

    private func startLiveSession() async {
        guard !isLiveSessionActive, !isLiveSessionStartingOrStopping else { return }
        // Same conditions as push-to-talk: not during the onboarding video,
        // and the screen stream needs Screen Recording permission.
        guard !showOnboardingVideo, allPermissionsGranted else { return }

        isLiveSessionStartingOrStopping = true
        defer { isLiveSessionStartingOrStopping = false }

        // If "Show Clicky" is off, bring the buddy on screen for the whole session
        transientHideTask?.cancel()
        transientHideTask = nil
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // A session replaces any short-lived watching for a single point
        if isWatchingScreenForCurrentPoint {
            await stopScreenWatching()
        }

        guard await startScreenWatching(capturesComputerAudio: true) else {
            showLiveSessionStatusBubble("couldn't turn on hands-free")
            scheduleTransientHideIfNeeded()
            return
        }

        isLiveSessionActive = true
        liveSessionQuestionCount = 0
        liveSessionLastActivityDate = Date()
        computerAudioSpeechTranscriber?.setTranscriptionEnabled(true)
        startLiveSessionSupervisor()
        showLiveSessionStatusBubble("hands-free on · just start talking")
        print("🔴 Live session started")
    }

    /// `statusMessage` overrides the default end-of-session summary.
    private func endLiveSession(statusMessage: String? = nil) async {
        guard isLiveSessionActive, !isLiveSessionStartingOrStopping else { return }

        isLiveSessionStartingOrStopping = true
        defer { isLiveSessionStartingOrStopping = false }

        isLiveSessionActive = false
        await stopScreenWatching()

        let questionCountSummary = liveSessionQuestionCount == 1
            ? "1 question sent"
            : "\(liveSessionQuestionCount) questions sent"
        showLiveSessionStatusBubble(statusMessage ?? "hands-free off · \(questionCountSummary)")
        print("⚪️ Live session ended (\(questionCountSummary))")
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Screen Watching

    /// Starts the screen stream, the click and scroll monitors, and the
    /// supervisor. Live sessions keep this running the whole time. Outside a
    /// session it runs only while Clicky points at something, so the pointer
    /// can follow the element as the user scrolls or moves the window.
    private func startScreenWatching(capturesComputerAudio: Bool) async -> Bool {
        let newLiveSessionScreenWatcher = LiveSessionScreenWatcher(capturesComputerAudio: capturesComputerAudio)

        var newComputerAudioSpeechTranscriber: ComputerAudioSpeechTranscriber? = nil
        if capturesComputerAudio {
            let computerAudioSpeechTranscriberForSession = ComputerAudioSpeechTranscriber()
            newLiveSessionScreenWatcher.onComputerAudioBuffer = { computerAudioBuffer in
                computerAudioSpeechTranscriberForSession.appendComputerAudioBuffer(computerAudioBuffer)
            }
            newComputerAudioSpeechTranscriber = computerAudioSpeechTranscriberForSession
        }

        newLiveSessionScreenWatcher.onElementTrackingUpdate = { [weak self] trackingUpdate in
            Task { @MainActor [weak self] in
                self?.handleLiveElementTrackingUpdate(trackingUpdate)
            }
        }
        newLiveSessionScreenWatcher.onStreamStoppedUnexpectedly = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isLiveSessionActive {
                    await self.endLiveSession(statusMessage: "hands-free stopped")
                } else {
                    await self.stopScreenWatching()
                }
            }
        }

        do {
            try await newLiveSessionScreenWatcher.start()
        } catch {
            print("⚠️ Screen watching: couldn't start screen stream: \(error)")
            return false
        }

        liveSessionScreenWatcher = newLiveSessionScreenWatcher
        computerAudioSpeechTranscriber = newComputerAudioSpeechTranscriber
        installLiveSessionMouseClickMonitor()
        installLiveSessionScrollWheelMonitor()
        startLiveSessionSupervisor()
        return true
    }

    private func stopScreenWatching() async {
        liveSessionSupervisorTask?.cancel()
        liveSessionSupervisorTask = nil
        if isHandsFreeDictationActive {
            cancelHandsFreeDictation()
        }

        // If the buddy is pointing at a tracked element, this sends it back to the cursor
        stopLiveElementTracking()
        removeLiveSessionMouseClickMonitor()
        removeLiveSessionScrollWheelMonitor()

        let liveSessionScreenWatcherToStop = liveSessionScreenWatcher
        liveSessionScreenWatcher = nil
        computerAudioSpeechTranscriber?.setTranscriptionEnabled(false)
        computerAudioSpeechTranscriber = nil
        isWatchingScreenForCurrentPoint = false
        await liveSessionScreenWatcherToStop?.stop()
    }

    /// Outside a live session: watch the screen while Clicky points, so the
    /// pointer follows the element. Tracking starts from the exact screenshot
    /// Claude saw, so it locks onto the right element even if the user
    /// scrolled while Claude was answering.
    private func startFollowingPointedElementOutsideSession(
        screenshotImageData: Data,
        screenshotCaptureSystemUptime: TimeInterval,
        displayFrame: CGRect,
        targetLocationInScreenshotPixels: CGPoint,
        initialGlobalLocation: CGPoint,
        elementLabel: String?
    ) async {
        guard let screenshotClaudeSaw = NSBitmapImageRep(data: screenshotImageData)?.cgImage else { return }

        if liveSessionScreenWatcher == nil {
            guard await startScreenWatching(capturesComputerAudio: false) else { return }
            isWatchingScreenForCurrentPoint = true
            print("👀 Watching the screen while pointing")
        }

        // The user may have asked something new while the stream was starting
        guard !Task.isCancelled,
              detectedElementScreenLocation == initialGlobalLocation,
              let displayID = liveSessionScreenWatcher?.displayID(forDisplayFrame: displayFrame) else {
            return
        }

        startLiveElementTracking(
            referenceFrame: LiveScreenFrame(
                cgImage: screenshotClaudeSaw,
                displayID: displayID,
                displayFrame: displayFrame,
                captureTimestamp: screenshotCaptureSystemUptime
            ),
            targetLocationInScreenshotPixels: targetLocationInScreenshotPixels,
            initialGlobalLocation: initialGlobalLocation,
            elementLabel: elementLabel
        )
    }

    /// Ends the short-lived watching once the pointing is fully over: not
    /// tracking, not searching for a lost element, and the buddy is back.
    private func stopWatchingForCurrentPointIfDone() {
        guard isWatchingScreenForCurrentPoint,
              !isLiveSessionActive,
              !isResponsePipelineRunning,
              liveTrackedElementScreenLocation == nil,
              !isSearchingForLostTrackedElement,
              detectedElementScreenLocation == nil else {
            return
        }
        isWatchingScreenForCurrentPoint = false
        print("👀 Done pointing, stopped watching the screen")
        Task {
            await stopScreenWatching()
        }
    }

    private func startLiveElementTracking(
        referenceFrame: LiveScreenFrame,
        targetLocationInScreenshotPixels: CGPoint,
        initialGlobalLocation: CGPoint,
        elementLabel: String?
    ) {
        guard let liveSessionScreenWatcher else { return }

        let didStartTracking = liveSessionScreenWatcher.startTrackingElement(
            referenceFrame: referenceFrame,
            targetLocationInScreenshotPixels: targetLocationInScreenshotPixels
        )
        guard didStartTracking else {
            // The area is too plain to recognize again (for example, empty
            // background). The buddy still points, just without following.
            print("🎯 Live session: element area too plain to track, pointing without following")
            return
        }

        liveTrackedElementLostTask?.cancel()
        liveTrackedElementLostTask = nil
        liveTrackedElementLabel = elementLabel
        liveTrackedElementLastSeenPosition = nil
        liveTrackedElementDisplayFrame = referenceFrame.displayFrame
        liveTrackedElementPositionEstimator = TrackedElementPositionEstimator(
            initialScreenLocation: initialGlobalLocation,
            frameCaptureTimestamp: referenceFrame.captureTimestamp
        )
        liveTrackedElementScreenLocation = initialGlobalLocation
        liveTrackedElementLastActivityDate = Date()

        let referenceFrameAgeInMilliseconds = Int((ProcessInfo.processInfo.systemUptime - referenceFrame.captureTimestamp) * 1000)
        print("🎯 Live session: tracking \"\(elementLabel ?? "element")\" (reference frame is \(referenceFrameAgeInMilliseconds)ms old)")
    }

    private func stopLiveElementTracking() {
        if let liveTrackedElementPositionEstimator {
            print("🎯 Live session: stopped tracking (learned scroll scale \(String(format: "%.2f", liveTrackedElementPositionEstimator.scrollToScreenMovementScale)))")
        }
        liveSessionScreenWatcher?.stopTrackingElement()
        liveTrackedElementLostTask?.cancel()
        liveTrackedElementLostTask = nil
        liveTrackedElementLabel = nil
        liveTrackedElementLastSeenPosition = nil
        liveTrackedElementPositionEstimator = nil
        liveTrackedElementDisplayFrame = nil
        isSearchingForLostTrackedElement = false
        if liveTrackedElementScreenLocation != nil {
            liveTrackedElementScreenLocation = nil
        }
    }

    private func handleLiveElementTrackingUpdate(_ trackingUpdate: LiveSessionElementTrackingUpdate) {
        // Ignore updates that were already in flight when tracking stopped
        guard liveTrackedElementScreenLocation != nil || isSearchingForLostTrackedElement else { return }

        switch trackingUpdate {
        case .targetFound(let targetLocationInScreenshotPixels, let frame):
            liveTrackedElementLostTask?.cancel()
            liveTrackedElementLostTask = nil
            let measuredScreenLocation = Self.convertScreenshotPixelLocationToGlobalScreenLocation(
                screenshotPixelLocation: targetLocationInScreenshotPixels,
                screenshotWidthInPixels: frame.cgImage.width,
                screenshotHeightInPixels: frame.cgImage.height,
                displayWidthInPoints: Int(frame.displayFrame.width),
                displayHeightInPoints: Int(frame.displayFrame.height),
                displayFrame: frame.displayFrame
            )
            #if DEBUG
            if let previousEstimate = liveTrackedElementPositionEstimator?.estimatedScreenLocation {
                let jumpDistance = hypot(measuredScreenLocation.x - previousEstimate.x, measuredScreenLocation.y - previousEstimate.y)
                if jumpDistance >= TrackedElementPositionEstimator.correctionDistanceAppliedInFull {
                    print("🐞 Tracking: frame match is \(Int(jumpDistance))pt from the scroll estimate (scroll scale \(String(format: "%.2f", liveTrackedElementPositionEstimator?.scrollToScreenMovementScale ?? 0)))")
                }
            }
            #endif

            // The frame is slightly old by now; the estimator adds any scrolling
            // since it was captured so the buddy doesn't get pulled backwards.
            liveTrackedElementPositionEstimator?.applyTrackingMeasurement(
                measuredScreenLocation: measuredScreenLocation,
                frameCaptureTimestamp: frame.captureTimestamp
            )
            let estimatedScreenLocation = liveTrackedElementPositionEstimator?.estimatedScreenLocation ?? measuredScreenLocation
            if isSearchingForLostTrackedElement {
                handleLostTrackedElementFoundAgain(atScreenLocation: estimatedScreenLocation, displayFrame: frame.displayFrame)
            } else {
                liveTrackedElementScreenLocation = estimatedScreenLocation
            }
        case .targetNotFoundInThisFrame(let lastKnownTargetLocation, let lastObservedTargetMovement, let frameWidthInPixels, let frameHeightInPixels):
            // Already lost and announced; keep searching quietly
            guard !isSearchingForLostTrackedElement else { return }

            liveTrackedElementLastSeenPosition = TrackedElementLastSeenPosition.determine(
                lastKnownTargetLocationInScreenshotPixels: lastKnownTargetLocation,
                lastObservedTargetMovementInScreenshotPixels: lastObservedTargetMovement,
                frameWidthInPixels: frameWidthInPixels,
                frameHeightInPixels: frameHeightInPixels
            )

            // One missed frame is normal mid-scroll. Only give up if the element
            // stays missing. A timer (instead of counting frames) also covers the
            // case where the screen stops changing, so no more frames arrive.
            guard liveTrackedElementLostTask == nil else { return }
            liveTrackedElementLostTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.liveTrackedElementLostAfterSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                liveTrackedElementLostTask = nil
                handleLiveTrackedElementLost()
            }
        }
    }

    /// The tracked element has been missing long enough to give up. The buddy
    /// flies back to the cursor, and Clicky tells the user where it went.
    private func handleLiveTrackedElementLost() {
        // The scroll-driven estimate knows best when the element was scrolled
        // off-screen (the tracker can lose it a few frames before it leaves).
        var lastSeenPositionFromScrollEstimate: TrackedElementLastSeenPosition? = nil
        if let liveTrackedElementPositionEstimator, let liveTrackedElementDisplayFrame {
            lastSeenPositionFromScrollEstimate = TrackedElementLastSeenPosition.fromEstimatedScreenLocation(
                liveTrackedElementPositionEstimator.estimatedScreenLocation,
                displayFrame: liveTrackedElementDisplayFrame
            )
        }
        let lastSeenPosition = lastSeenPositionFromScrollEstimate
            ?? liveTrackedElementLastSeenPosition
            ?? .disappearedWhileOnScreen(screenAreaDescription: "middle")
        let lostElementLabel = liveTrackedElementLabel
        print("🎯 Live session: lost track of the element (\(lastSeenPosition))")

        // Only speak up when the user scrolled it away (they're probably still
        // looking for it). If it vanished because they switched pages, tabs, or
        // apps, they moved on on purpose: quietly stop pointing, say nothing.
        if case .disappearedWhileOnScreen = lastSeenPosition {
            stopLiveElementTracking()
            return
        }

        // Stop pointing (the buddy flies back to the cursor), but keep the tracker
        // looking for the element in case the user scrolls back to it.
        isSearchingForLostTrackedElement = true
        lostTrackedElementSearchStartedDate = Date()
        liveTrackedElementScreenLocation = nil

        showLiveSessionStatusBubble(lastSeenPosition.statusBubbleText)
        speakLostTrackedElementAnnouncement(lastSeenPosition.spokenAnnouncement(elementLabel: lostElementLabel))
    }

    /// The user scrolled the lost element back into view: stop telling them
    /// where it went, and fly back to point at it again.
    private func handleLostTrackedElementFoundAgain(atScreenLocation elementScreenLocation: CGPoint, displayFrame: CGRect) {
        print("🎯 Live session: found the element again")
        isSearchingForLostTrackedElement = false

        lostTrackedElementAnnouncementTask?.cancel()
        lostTrackedElementAnnouncementTask = nil
        if isLostTrackedElementAnnouncementSpeaking {
            elevenLabsTTSClient.stopPlayback()
            isLostTrackedElementAnnouncementSpeaking = false
        }
        liveSessionStatusBubbleHideTask?.cancel()
        liveSessionStatusBubbleText = nil

        liveTrackedElementLastActivityDate = Date()
        liveTrackedElementScreenLocation = elementScreenLocation

        // The display frame must be set before the location: the overlay reads
        // it when the location changes to decide which screen flies.
        detectedElementBubbleText = "there it is!"
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = elementScreenLocation
    }

    private func speakLostTrackedElementAnnouncement(_ announcementText: String) {
        lostTrackedElementAnnouncementTask?.cancel()
        lostTrackedElementAnnouncementTask = Task {
            // The user often scrolls while Clicky is still answering. Let the
            // answer finish instead of talking over it.
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Don't talk while the user is asking something new
            guard !Task.isCancelled, voiceState == .idle || voiceState == .responding else { return }

            isLostTrackedElementAnnouncementSpeaking = true
            do {
                try await elevenLabsTTSClient.speakText(announcementText)
            } catch {
                isLostTrackedElementAnnouncementSpeaking = false
                print("⚠️ Live session: couldn't speak lost-element announcement: \(error)")
            }

            // speakText returns once playback starts. Clearing the task lets the
            // supervisor notice when the audio ends. A replaced announcement is
            // always cancelled first, so it can't clear its replacement.
            if !Task.isCancelled {
                lostTrackedElementAnnouncementTask = nil
            }
        }
    }

    // MARK: - Live Session Supervisor

    private func startLiveSessionSupervisor() {
        liveSessionSupervisorTask?.cancel()
        liveSessionSupervisorTask = Task {
            while !Task.isCancelled && liveSessionScreenWatcher != nil {
                superviseHandsFreeListening()
                releaseTrackedElementIfExplanationIsOver()
                stopSearchingForLostTrackedElementIfTimedOut()
                endLiveSessionIfIdleTooLong()
                stopWatchingForCurrentPointIfDone()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Keeps the microphone listening whenever Clicky is free, pauses it
    /// while Clicky thinks or talks (so it never hears itself), and sends a
    /// question once the user stops talking.
    private func superviseHandsFreeListening() {
        if isLostTrackedElementAnnouncementSpeaking
            && lostTrackedElementAnnouncementTask == nil
            && !elevenLabsTTSClient.isPlaying {
            isLostTrackedElementAnnouncementSpeaking = false
        }

        guard isLiveSessionActive else {
            if isHandsFreeDictationActive {
                cancelHandsFreeDictation()
            }
            return
        }

        let isClickyThinkingOrTalking = isResponsePipelineRunning || elevenLabsTTSClient.isPlaying
        let isPushToTalkInUse = globalPushToTalkShortcutMonitor.isShortcutCurrentlyPressed
            || (buddyDictationManager.isDictationInProgress && !isHandsFreeDictationActive)
        let now = Date()

        if isHandsFreeDictationActive {
            // The dictation manager went idle: the question was sent, or listening failed
            if !buddyDictationManager.isDictationInProgress && !isHandsFreeDictationStarting {
                let listeningDurationSeconds = now.timeIntervalSince(handsFreeDictationStartedDate)
                let didListeningFailRightAway = !hasHandsFreeListeningHeardSpeech && listeningDurationSeconds < 2
                handsFreeNextStartAllowedDate = now.addingTimeInterval(didListeningFailRightAway ? 5 : 0.3)
                isHandsFreeDictationActive = false
                hasHandsFreeListeningHeardSpeech = false
                return
            }

            if isClickyThinkingOrTalking {
                cancelHandsFreeDictation()
                return
            }

            // Still starting up, or already finalizing the transcript
            guard buddyDictationManager.isRecordingFromKeyboardShortcut else { return }

            let currentTranscript = buddyDictationManager.latestRecognizedText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if currentTranscript != handsFreeLastSeenTranscript {
                handsFreeLastSeenTranscript = currentTranscript
                handsFreeLastTranscriptChangeDate = now

                if !currentTranscript.isEmpty && !hasHandsFreeListeningHeardSpeech {
                    handsFreeSpeechStartedSystemUptime = ProcessInfo.processInfo.systemUptime
                }

                // The microphone may be hearing the Mac's own speakers (a video,
                // a podcast). Drop it quietly as soon as it's clear, before the
                // waveform shows or anything is sent.
                if isHeardSpeechAnEchoOfComputerAudio(currentTranscript) {
                    print("🎙️ Hands-free: ignored sound from this Mac: \"\(currentTranscript)\"")
                    cancelHandsFreeDictation()
                    return
                }

                if !currentTranscript.isEmpty && !hasHandsFreeListeningHeardSpeech {
                    hasHandsFreeListeningHeardSpeech = true
                    liveSessionLastActivityDate = now
                    voiceState = .listening
                }
            }

            if hasHandsFreeListeningHeardSpeech
                && now.timeIntervalSince(handsFreeLastTranscriptChangeDate) >= Self.handsFreeSilenceSecondsToEndUtterance {
                // The user stopped talking. Stopping finalizes the transcript and
                // sends it through handleHandsFreeUtterance.
                print("🎙️ Hands-free: utterance ended")
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            } else if !hasHandsFreeListeningHeardSpeech
                && now.timeIntervalSince(handsFreeDictationStartedDate) >= Self.handsFreeListeningRestartAfterSecondsWithoutSpeech {
                // Quietly restart before the recognizer's session time limit
                cancelHandsFreeDictation()
            }
            return
        }

        guard !isClickyThinkingOrTalking,
              !isPushToTalkInUse,
              !buddyDictationManager.isDictationInProgress,
              !showOnboardingVideo,
              now >= handsFreeNextStartAllowedDate else {
            return
        }
        startHandsFreeDictation()
    }

    private func startHandsFreeDictation() {
        isHandsFreeDictationActive = true
        isHandsFreeDictationStarting = true
        hasHandsFreeListeningHeardSpeech = false
        handsFreeLastSeenTranscript = ""
        handsFreeDictationStartedDate = Date()

        Task {
            await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                currentDraftText: "",
                updateDraftText: { _ in
                    // Partial transcripts are hidden (waveform-only UI)
                },
                submitDraftText: { [weak self] finalTranscript in
                    self?.handleHandsFreeUtterance(finalTranscript)
                }
            )
            isHandsFreeDictationStarting = false
        }
    }

    private func isHeardSpeechAnEchoOfComputerAudio(_ heardText: String) -> Bool {
        guard let computerAudioSpeechTranscriber else { return false }
        let lookbackStartSystemUptime = (hasHandsFreeListeningHeardSpeech
            ? handsFreeSpeechStartedSystemUptime
            : ProcessInfo.processInfo.systemUptime) - Self.computerAudioEchoLookbackSeconds
        let recentComputerAudioText = computerAudioSpeechTranscriber.computerAudioText(
            sinceSystemUptime: lookbackStartSystemUptime
        )
        return ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: heardText,
            computerAudioText: recentComputerAudioText
        )
    }

    private func cancelHandsFreeDictation() {
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        isHandsFreeDictationActive = false
        hasHandsFreeListeningHeardSpeech = false
        if voiceState == .listening {
            voiceState = .idle
        }
    }

    private func handleHandsFreeUtterance(_ finalTranscript: String) {
        let wordCount = finalTranscript.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount >= Self.handsFreeMinimumWordCountToSend else {
            print("🎙️ Hands-free: ignored \"\(finalTranscript)\" (too short to be a question, not sent)")
            return
        }
        // Final check: the Mac's audio transcript may have caught up since the
        // last partial transcript was compared.
        guard !isHeardSpeechAnEchoOfComputerAudio(finalTranscript) else {
            print("🎙️ Hands-free: ignored sound from this Mac: \"\(finalTranscript)\" (not sent)")
            return
        }

        #if DEBUG
        if let computerAudioSpeechTranscriber {
            let recentComputerAudioText = computerAudioSpeechTranscriber.computerAudioText(
                sinceSystemUptime: handsFreeSpeechStartedSystemUptime - Self.computerAudioEchoLookbackSeconds
            )
            if !recentComputerAudioText.isEmpty {
                print("🐞 Hands-free: sending even though the Mac was playing: \"\(recentComputerAudioText)\"")
            }
        }
        #endif

        lastTranscript = finalTranscript
        print("🗣️ Companion received transcript (hands-free): \(finalTranscript)")
        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)

        // Same as pressing push-to-talk: stop pointing at the previous answer's element
        clearDetectedElementLocation()
        sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript, wasHeardHandsFree: true)
    }

    /// The buddy keeps pointing at the tracked element while Clicky explains
    /// it, then lets go a few seconds after Clicky stops talking (scrolling
    /// restarts the countdown).
    private func releaseTrackedElementIfExplanationIsOver() {
        guard liveTrackedElementScreenLocation != nil else { return }

        let now = Date()
        if isResponsePipelineRunning || elevenLabsTTSClient.isPlaying {
            liveTrackedElementLastActivityDate = now
            return
        }

        if now.timeIntervalSince(liveTrackedElementLastActivityDate) >= Self.liveTrackedElementHoldAfterActivitySeconds {
            print("🎯 Live session: explanation finished, done pointing")
            stopLiveElementTracking()
        }
    }

    private func stopSearchingForLostTrackedElementIfTimedOut() {
        guard isSearchingForLostTrackedElement,
              Date().timeIntervalSince(lostTrackedElementSearchStartedDate) >= Self.lostTrackedElementSearchDurationSeconds else {
            return
        }
        print("🎯 Live session: stopped looking for the lost element")
        stopLiveElementTracking()
    }

    private func endLiveSessionIfIdleTooLong() {
        guard isLiveSessionActive,
              !isResponsePipelineRunning,
              !elevenLabsTTSClient.isPlaying,
              !hasHandsFreeListeningHeardSpeech,
              Date().timeIntervalSince(liveSessionLastActivityDate) >= Self.liveSessionAutoEndAfterIdleSeconds else {
            return
        }
        Task {
            await endLiveSession(statusMessage: "hands-free off after 10 quiet minutes")
        }
    }

    /// Clicking the element the buddy is pointing at means the user found it,
    /// so the buddy stops pointing and returns to the cursor.
    private func installLiveSessionMouseClickMonitor() {
        removeLiveSessionMouseClickMonitor()
        liveSessionMouseClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // Global event monitors are always called on the main thread
            MainActor.assumeIsolated {
                self?.handleLiveSessionMouseClick(atScreenLocation: NSEvent.mouseLocation)
            }
        }
    }

    private func removeLiveSessionMouseClickMonitor() {
        if let liveSessionMouseClickMonitor {
            NSEvent.removeMonitor(liveSessionMouseClickMonitor)
            self.liveSessionMouseClickMonitor = nil
        }
    }

    private func installLiveSessionScrollWheelMonitor() {
        removeLiveSessionScrollWheelMonitor()
        liveSessionScrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] scrollEvent in
            // Global event monitors are always called on the main thread
            MainActor.assumeIsolated {
                self?.handleLiveSessionScrollWheelEvent(scrollEvent)
            }
        }
    }

    private func removeLiveSessionScrollWheelMonitor() {
        if let liveSessionScrollWheelMonitor {
            NSEvent.removeMonitor(liveSessionScrollWheelMonitor)
            self.liveSessionScrollWheelMonitor = nil
        }
    }

    /// Moves the tracked element's estimate with the scrolled content right
    /// away, so the buddy stays anchored instead of catching up every frame.
    private func handleLiveSessionScrollWheelEvent(_ scrollEvent: NSEvent) {
        guard liveTrackedElementPositionEstimator != nil,
              let liveTrackedElementDisplayFrame,
              liveTrackedElementDisplayFrame.contains(NSEvent.mouseLocation) else {
            return
        }

        // The user is still looking for the element: keep pointing at it
        liveTrackedElementLastActivityDate = Date()

        // Trackpads and Magic Mice report exact point distances. Classic mouse
        // wheels report "lines" that each app scrolls by a different amount,
        // so for those the buddy follows the screen frames alone.
        guard scrollEvent.hasPreciseScrollingDeltas else { return }

        liveTrackedElementPositionEstimator?.applyScrollWheelMovement(
            scrollingDeltaX: scrollEvent.scrollingDeltaX,
            scrollingDeltaY: scrollEvent.scrollingDeltaY,
            timestamp: scrollEvent.timestamp
        )
        liveTrackedElementScreenLocation = liveTrackedElementPositionEstimator?.estimatedScreenLocation
    }

    private func handleLiveSessionMouseClick(atScreenLocation clickScreenLocation: CGPoint) {
        guard let liveTrackedElementScreenLocation else { return }

        let distanceFromTrackedElement = hypot(
            clickScreenLocation.x - liveTrackedElementScreenLocation.x,
            clickScreenLocation.y - liveTrackedElementScreenLocation.y
        )
        if distanceFromTrackedElement <= Self.liveTrackedElementClickDismissRadiusInPoints {
            stopLiveElementTracking()
        }
    }

    private func showLiveSessionStatusBubble(_ statusText: String) {
        liveSessionStatusBubbleHideTask?.cancel()
        liveSessionStatusBubbleText = statusText
        // Longer messages stay up longer so they can actually be read
        let displayDurationSeconds = max(1.8, Double(statusText.count) * 0.07)
        liveSessionStatusBubbleHideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(displayDurationSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            liveSessionStatusBubbleText = nil
        }
    }

    // MARK: - Screenshot Coordinate Conversion

    /// Claude's coordinates (and tracked element positions) are in the
    /// screenshot's pixel space (top-left origin, e.g. 1280x831). Scales them to
    /// the display's point space (e.g. 1512x982), then converts to AppKit global
    /// coordinates (bottom-left origin) that the overlay windows use.
    nonisolated static func convertScreenshotPixelLocationToGlobalScreenLocation(
        screenshotPixelLocation: CGPoint,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        displayFrame: CGRect
    ) -> CGPoint {
        let displayWidth = CGFloat(displayWidthInPoints)
        let displayHeight = CGFloat(displayHeightInPoints)

        // Scale from screenshot pixels to display points
        let displayLocalX = screenshotPixelLocation.x * (displayWidth / CGFloat(screenshotWidthInPixels))
        let displayLocalY = screenshotPixelLocation.y * (displayHeight / CGFloat(screenshotHeightInPixels))

        // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
        let appKitY = displayHeight - displayLocalY

        // Convert display-local coords to global screen coords
        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
