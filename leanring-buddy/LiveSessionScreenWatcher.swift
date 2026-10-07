//
//  LiveSessionScreenWatcher.swift
//  leanring-buddy
//
//  Watches the screen continuously while a live session is on. Runs one
//  ScreenCaptureKit stream per display and keeps the newest frame of each,
//  so a push-to-talk question can use what's on screen right now without
//  waiting for a fresh screenshot. When Claude points at something, the
//  watcher also tracks that element in every new frame and reports where
//  it moved, so the buddy keeps pointing at it while the user scrolls.
//
//  Nothing here is sent to Claude on its own. Frames stay on the Mac; only
//  the frames attached to a push-to-talk question leave the device, exactly
//  like the screenshots outside a session.
//

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// One frame from a live session stream, plus the display it came from.
nonisolated struct LiveScreenFrame {
    let cgImage: CGImage
    let displayID: CGDirectDisplayID
    /// Display frame in AppKit coordinates (bottom-left origin), the same space
    /// as NSEvent.mouseLocation and the overlay windows.
    let displayFrame: CGRect
    /// When the frame was captured, in seconds since system startup (the same
    /// clock as NSEvent.timestamp), so scroll events can be ordered against it.
    let captureTimestamp: TimeInterval
}

nonisolated enum LiveSessionElementTrackingUpdate {
    case targetFound(targetLocationInScreenshotPixels: CGPoint, frame: LiveScreenFrame)
    /// Carries where the element was last found and how it was moving, so a
    /// lost element can be described ("it scrolled off the top").
    case targetNotFoundInThisFrame(
        lastKnownTargetLocationInScreenshotPixels: CGPoint,
        lastObservedTargetMovementInScreenshotPixels: CGPoint,
        frameWidthInPixels: Int,
        frameHeightInPixels: Int
    )
}

nonisolated final class LiveSessionScreenWatcher: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Fast enough for the pointer to follow a scroll smoothly. ScreenCaptureKit
    /// only delivers new frames when something on screen changes, so a still
    /// screen costs almost nothing.
    static let framesPerSecond: Int32 = 12

    /// Called on the frame processing queue (not the main thread) after each
    /// frame from the display the tracked element is on.
    var onElementTrackingUpdate: (@Sendable (LiveSessionElementTrackingUpdate) -> Void)?
    /// Called on a ScreenCaptureKit queue if a stream dies (for example, the
    /// user revokes Screen Recording permission mid-session).
    var onStreamStoppedUnexpectedly: (@Sendable (Error) -> Void)?
    /// Called with what the Mac is playing (Clicky's own voice excluded), so
    /// hands-free mode can ignore the Mac's speakers. Called on its own queue.
    var onComputerAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Computer audio has its own queue so speech processing never delays frames.
    private let computerAudioProcessingQueue = DispatchQueue(label: "com.clicky.live-session-computer-audio")

    /// Only live sessions need the Mac's audio (for hands-free mode). Watching
    /// the screen just while pointing at something captures video only.
    private let capturesComputerAudio: Bool

    init(capturesComputerAudio: Bool) {
        self.capturesComputerAudio = capturesComputerAudio
        super.init()
    }

    /// All streams deliver frames on this one serial queue, so tracking never
    /// runs twice at the same time.
    private let frameProcessingQueue = DispatchQueue(label: "com.clicky.live-session-frame-processing")

    /// Guards every property below, which are written from the main actor and
    /// read from the frame processing queue.
    private let watcherStateLock = NSLock()
    private var activeStreams: [SCStream] = []
    private var displayInfoByStreamIdentifier: [ObjectIdentifier: (displayID: CGDirectDisplayID, displayFrame: CGRect)] = [:]
    private var latestFrameByDisplayID: [CGDirectDisplayID: LiveScreenFrame] = [:]
    private var activeElementTracking: (displayID: CGDirectDisplayID, tracker: ScreenElementTemplateTracker)?

    // MARK: - Starting and Stopping

    @MainActor
    func start() async throws {
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !shareableContent.displays.isEmpty else {
            throw NSError(domain: "LiveSessionScreenWatcher", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        // Exclude the whole app rather than its current windows, so overlays
        // created after the stream starts are hidden too. Otherwise the tracker
        // would see the blue buddy sitting on top of the element it's tracking.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownApplications = shareableContent.applications.filter { application in
            application.bundleIdentifier == ownBundleIdentifier
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        do {
            for (displayIndex, display) in shareableContent.displays.enumerated() {
                let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                    ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                              width: CGFloat(display.width), height: CGFloat(display.height))

                let contentFilter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])

                let streamConfiguration = SCStreamConfiguration()
                let frameDimensions = CompanionScreenCaptureUtility.screenshotDimensionsInPixels(
                    forDisplayWidth: display.width,
                    displayHeight: display.height
                )
                streamConfiguration.width = frameDimensions.widthInPixels
                streamConfiguration.height = frameDimensions.heightInPixels
                streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
                streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
                streamConfiguration.showsCursor = false
                streamConfiguration.queueDepth = 3

                // System audio is the same on every display, so only the first
                // stream captures it. Clicky's own voice is excluded.
                let shouldCaptureComputerAudio = capturesComputerAudio && displayIndex == 0
                if shouldCaptureComputerAudio {
                    streamConfiguration.capturesAudio = true
                    streamConfiguration.excludesCurrentProcessAudio = true
                    streamConfiguration.sampleRate = 16_000
                    streamConfiguration.channelCount = 1
                }

                let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameProcessingQueue)
                if shouldCaptureComputerAudio {
                    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: computerAudioProcessingQueue)
                }

                watcherStateLock.withLock {
                    displayInfoByStreamIdentifier[ObjectIdentifier(stream)] = (display.displayID, displayFrame)
                    activeStreams.append(stream)
                }

                try await stream.startCapture()
            }
        } catch {
            await stop()
            throw error
        }
    }

    @MainActor
    func stop() async {
        let streamsToStop = watcherStateLock.withLock {
            let streamsToStop = activeStreams
            activeStreams = []
            displayInfoByStreamIdentifier = [:]
            latestFrameByDisplayID = [:]
            activeElementTracking = nil
            return streamsToStop
        }

        for stream in streamsToStop {
            try? await stream.stopCapture()
        }
    }

    // MARK: - Latest Frames for Claude

    /// Builds the same labeled JPEG images that a push-to-talk screenshot
    /// produces, but from the frames already captured by the stream. Returns
    /// nil if any display hasn't delivered a frame yet, so the caller can fall
    /// back to a regular screenshot.
    ///
    /// `framesInSameOrder[index]` is the frame behind `screenCaptures[index]`,
    /// so the caller can start tracking on the exact image Claude saw.
    @MainActor
    func makeScreenCapturesFromLatestFrames() -> (screenCaptures: [CompanionScreenCapture], framesInSameOrder: [LiveScreenFrame])? {
        let latestFrames = watcherStateLock.withLock { Array(latestFrameByDisplayID.values) }
        guard !latestFrames.isEmpty, latestFrames.count == NSScreen.screens.count else {
            return nil
        }

        // Cursor screen first, matching CompanionScreenCaptureUtility's ordering.
        let mouseLocation = NSEvent.mouseLocation
        let framesWithCursorScreenFirst = latestFrames.sorted { frameA, frameB in
            let frameAContainsCursor = frameA.displayFrame.contains(mouseLocation)
            let frameBContainsCursor = frameB.displayFrame.contains(mouseLocation)
            if frameAContainsCursor != frameBContainsCursor { return frameAContainsCursor }
            return frameA.displayID < frameB.displayID
        }

        var screenCaptures: [CompanionScreenCapture] = []
        for (displayIndex, frame) in framesWithCursorScreenFirst.enumerated() {
            guard let jpegData = NSBitmapImageRep(cgImage: frame.cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return nil
            }

            let isCursorScreen = frame.displayFrame.contains(mouseLocation)
            screenCaptures.append(CompanionScreenCapture(
                imageData: jpegData,
                label: CompanionScreenCaptureUtility.screenLabelForClaude(
                    displayIndex: displayIndex,
                    displayCount: framesWithCursorScreenFirst.count,
                    isCursorScreen: isCursorScreen
                ),
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(frame.displayFrame.width),
                displayHeightInPoints: Int(frame.displayFrame.height),
                displayFrame: frame.displayFrame,
                screenshotWidthInPixels: frame.cgImage.width,
                screenshotHeightInPixels: frame.cgImage.height
            ))
        }

        return (screenCaptures, framesWithCursorScreenFirst)
    }

    /// The display ID of the streamed display with this frame (AppKit
    /// coordinates), used to track an element from a regular screenshot.
    @MainActor
    func displayID(forDisplayFrame displayFrame: CGRect) -> CGDirectDisplayID? {
        watcherStateLock.withLock {
            displayInfoByStreamIdentifier.values.first { $0.displayFrame == displayFrame }?.displayID
        }
    }

    // MARK: - Element Tracking

    /// Starts following the element at `targetLocationInScreenshotPixels` in
    /// `referenceFrame`. Replaces any element that was being tracked. Returns
    /// false if the area is too plain to track, in which case the buddy should
    /// point at the original location like it does outside a session.
    @MainActor
    func startTrackingElement(referenceFrame: LiveScreenFrame, targetLocationInScreenshotPixels: CGPoint) -> Bool {
        guard let elementTracker = ScreenElementTemplateTracker(
            referenceFrame: referenceFrame.cgImage,
            targetLocationInScreenshotPixels: targetLocationInScreenshotPixels
        ) else {
            stopTrackingElement()
            return false
        }

        watcherStateLock.withLock {
            activeElementTracking = (referenceFrame.displayID, elementTracker)
        }
        return true
    }

    func stopTrackingElement() {
        watcherStateLock.withLock {
            activeElementTracking = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        if outputType == .audio {
            if let computerAudioBuffer = Self.makePCMBuffer(fromAudioSampleBuffer: sampleBuffer) {
                onComputerAudioBuffer?(computerAudioBuffer)
            }
            return
        }

        guard outputType == .screen else { return }

        // ScreenCaptureKit also delivers "idle" buffers when nothing changed.
        // Only complete frames carry new pixels.
        guard let sampleAttachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let frameStatusRawValue = sampleAttachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: frameStatusRawValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        var capturedImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &capturedImage)
        guard let capturedImage else { return }

        // ScreenCaptureKit stamps frames with the host clock, which counts the
        // same seconds-since-startup as NSEvent.timestamp. If the stamp ever looks
        // wrong, fall back to the arrival time (a frame is only a few ms old).
        let currentSystemUptime = ProcessInfo.processInfo.systemUptime
        let presentationTimestampSeconds = sampleBuffer.presentationTimeStamp.seconds
        let isPresentationTimestampPlausible = presentationTimestampSeconds.isFinite
            && abs(currentSystemUptime - presentationTimestampSeconds) < 1.0
        let frameCaptureTimestamp = isPresentationTimestampPlausible ? presentationTimestampSeconds : currentSystemUptime

        let (newFrame, elementTrackerForThisDisplay) = watcherStateLock.withLock { () -> (LiveScreenFrame?, ScreenElementTemplateTracker?) in
            guard let displayInfo = displayInfoByStreamIdentifier[ObjectIdentifier(stream)] else {
                return (nil, nil)
            }
            let newFrame = LiveScreenFrame(
                cgImage: capturedImage,
                displayID: displayInfo.displayID,
                displayFrame: displayInfo.displayFrame,
                captureTimestamp: frameCaptureTimestamp
            )
            latestFrameByDisplayID[displayInfo.displayID] = newFrame

            let isTrackedElementOnThisDisplay = activeElementTracking?.displayID == displayInfo.displayID
            return (newFrame, isTrackedElementOnThisDisplay ? activeElementTracking?.tracker : nil)
        }

        guard let newFrame, let elementTrackerForThisDisplay else { return }

        let trackingResult = elementTrackerForThisDisplay.locateTarget(in: newFrame.cgImage)

        // The user may have asked a new question while this frame was being
        // processed. Don't report a result for an element we stopped tracking.
        let isTrackerStillActive = watcherStateLock.withLock {
            activeElementTracking?.tracker === elementTrackerForThisDisplay
        }
        guard isTrackerStillActive else { return }

        switch trackingResult {
        case .found(let targetLocationInScreenshotPixels):
            onElementTrackingUpdate?(.targetFound(targetLocationInScreenshotPixels: targetLocationInScreenshotPixels, frame: newFrame))
        case .notFoundInThisFrame:
            onElementTrackingUpdate?(.targetNotFoundInThisFrame(
                lastKnownTargetLocationInScreenshotPixels: elementTrackerForThisDisplay.lastKnownTargetLocationInScreenshotPixels,
                lastObservedTargetMovementInScreenshotPixels: elementTrackerForThisDisplay.lastObservedTargetMovementInScreenshotPixels,
                frameWidthInPixels: newFrame.cgImage.width,
                frameHeightInPixels: newFrame.cgImage.height
            ))
        }
    }

    /// Copies a ScreenCaptureKit audio sample buffer into an AVAudioPCMBuffer,
    /// the format the Speech framework accepts.
    private static func makePCMBuffer(fromAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let audioFormatDescription = audioSampleBuffer.formatDescription else { return nil }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: audioFormatDescription)
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(audioSampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            audioSampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        return copyStatus == noErr ? pcmBuffer : nil
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("⚠️ Live session: screen stream stopped: \(error)")
        onStreamStoppedUnexpectedly?(error)
    }
}
