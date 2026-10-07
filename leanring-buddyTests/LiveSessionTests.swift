//
//  LiveSessionTests.swift
//  leanring-buddyTests
//
//  Tests for the live session feature: the fn + control shortcut, the
//  screenshot-to-screen coordinate conversion, and the template tracker that
//  keeps the buddy pointing at an element while the user scrolls.
//
//  Tracker tests draw a synthetic tall "web page" and slide a 1280x800
//  viewport over it, which simulates scrolling (vertical offset) and dragging
//  the window (horizontal offset) with exactly known element positions.
//

import AppKit
import Testing
@testable import Clicky

// MARK: - Live Session Shortcut

struct LiveSessionToggleShortcutTests {
    private let functionAndControlFlags = UInt64(NSEvent.ModifierFlags([.function, .control]).rawValue)

    @Test func pressingFunctionAndControlStartsTheShortcut() {
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: functionAndControlFlags,
            wasShortcutPreviouslyPressed: false
        )
        #expect(transition == .pressed)
    }

    @Test func releasingEitherKeyEndsTheShortcut() {
        let onlyControlStillHeldFlags = UInt64(NSEvent.ModifierFlags.control.rawValue)
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: onlyControlStillHeldFlags,
            wasShortcutPreviouslyPressed: true
        )
        #expect(transition == .released)
    }

    @Test func holdingTheKeysDoesNotRepeatThePress() {
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: functionAndControlFlags,
            wasShortcutPreviouslyPressed: true
        )
        #expect(transition == .none)
    }

    @Test func pushToTalkWithFunctionHeldDoesNotStartALiveSession() {
        // ctrl + option is push-to-talk. Holding fn as well must not also toggle the session.
        let functionControlOptionFlags = UInt64(NSEvent.ModifierFlags([.function, .control, .option]).rawValue)
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: functionControlOptionFlags,
            wasShortcutPreviouslyPressed: false
        )
        #expect(transition == .none)
    }

    @Test func functionAloneDoesNothing() {
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .flagsChanged,
            modifierFlagsRawValue: UInt64(NSEvent.ModifierFlags.function.rawValue),
            wasShortcutPreviouslyPressed: false
        )
        #expect(transition == .none)
    }

    @Test func keyPressesAreIgnoredBecauseTheShortcutIsModifierOnly() {
        let transition = LiveSessionToggleShortcut.shortcutTransition(
            for: .keyDown,
            modifierFlagsRawValue: functionAndControlFlags,
            wasShortcutPreviouslyPressed: false
        )
        #expect(transition == .none)
    }
}

// MARK: - Computer Audio Echo

struct ComputerAudioEchoDetectorTests {
    private let podcastTranscript = """
    so the thing about building a startup is that nobody tells you how lonely it gets in the first year \
    you spend most of your time talking to users and fixing bugs and honestly that is the whole job \
    and then one day it clicks and people start telling their friends about what you made
    """

    @Test func exactCopyOfTheMacsAudioIsAnEcho() {
        #expect(ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "you spend most of your time talking to users",
            computerAudioText: podcastTranscript
        ))
    }

    @Test func slightlyMisheardCopyIsStillAnEcho() {
        // The microphone hears the speakers through the room, so a few words differ
        #expect(ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "you spent most of the time talking to user and fixing bugs",
            computerAudioText: podcastTranscript
        ))
    }

    @Test func aRealQuestionIsNotAnEchoEvenWithSharedCommonWords() {
        // "what", "is", "the", "about" all appear somewhere in the podcast, but scattered
        #expect(!ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "what is the export button about",
            computerAudioText: podcastTranscript
        ))
    }

    @Test func talkingWhileNothingIsPlayingIsNotAnEcho() {
        #expect(!ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "where is the search bar",
            computerAudioText: ""
        ))
    }

    @Test func twoSharedWordsAreNotEnough() {
        #expect(!ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "the job",
            computerAudioText: podcastTranscript
        ))
    }

    @Test func punctuationAndCapitalizationDoNotMatter() {
        #expect(ComputerAudioEchoDetector.isLikelyEchoOfComputerAudio(
            heardText: "Then one day, it clicks! And people start telling their friends.",
            computerAudioText: podcastTranscript
        ))
    }
}

// MARK: - Command Double Tap

struct ModifierKeyDoubleTapDetectorTests {
    private let commandOnly = NSEvent.ModifierFlags.command
    private let noModifiers = NSEvent.ModifierFlags()

    /// Presses and releases command at the given times; returns whether the
    /// release completed a double tap.
    private func tapCommand(_ detector: inout ModifierKeyDoubleTapDetector, pressAt pressTimestamp: TimeInterval, releaseAt releaseTimestamp: TimeInterval) -> Bool {
        _ = detector.handleModifierFlagsChanged(modifierFlags: commandOnly, timestamp: pressTimestamp)
        return detector.handleModifierFlagsChanged(modifierFlags: noModifiers, timestamp: releaseTimestamp)
    }

    @Test func twoQuickTapsAreADoubleTap() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        #expect(tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1) == false)
        #expect(tapCommand(&detector, pressAt: 0.25, releaseAt: 0.35) == true)
    }

    @Test func aSingleTapIsNotADoubleTap() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        #expect(tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1) == false)
    }

    @Test func tapsTooFarApartDoNotCount() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        _ = tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1)
        #expect(tapCommand(&detector, pressAt: 0.8, releaseAt: 0.9) == false)
    }

    @Test func holdingCommandIsNotATap() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        _ = tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1)
        #expect(tapCommand(&detector, pressAt: 0.2, releaseAt: 1.0) == false)
    }

    @Test func quickCommandShortcutsDoNotCount() {
        // command + c, then command + v, both quick: must not toggle the mode
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        for pressTimestamp in [0.0, 0.25] {
            _ = detector.handleModifierFlagsChanged(modifierFlags: commandOnly, timestamp: pressTimestamp)
            detector.handleKeyPressed()
            let completedDoubleTap = detector.handleModifierFlagsChanged(modifierFlags: noModifiers, timestamp: pressTimestamp + 0.1)
            #expect(completedDoubleTap == false)
        }
    }

    @Test func commandShiftShortcutDoesNotCount() {
        // command + shift (e.g. starting command + shift + 4) is not a clean tap
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        _ = tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1)
        _ = detector.handleModifierFlagsChanged(modifierFlags: commandOnly, timestamp: 0.2)
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.command, .shift], timestamp: 0.22)
        _ = detector.handleModifierFlagsChanged(modifierFlags: commandOnly, timestamp: 0.25)
        #expect(detector.handleModifierFlagsChanged(modifierFlags: noModifiers, timestamp: 0.3) == false)
    }

    @Test func typingBetweenTheTapsCancelsTheDoubleTap() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        _ = tapCommand(&detector, pressAt: 0.0, releaseAt: 0.1)
        detector.handleKeyPressed()
        #expect(tapCommand(&detector, pressAt: 0.2, releaseAt: 0.3) == false)
    }

    @Test func capsLockDoesNotBlockDoubleTaps() {
        var detector = ModifierKeyDoubleTapDetector(tappedModifierFlag: .command)
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.capsLock, .command], timestamp: 0.0)
        _ = detector.handleModifierFlagsChanged(modifierFlags: .capsLock, timestamp: 0.1)
        _ = detector.handleModifierFlagsChanged(modifierFlags: [.capsLock, .command], timestamp: 0.2)
        #expect(detector.handleModifierFlagsChanged(modifierFlags: .capsLock, timestamp: 0.3) == true)
    }
}

// MARK: - Coordinate Conversion

struct ScreenshotCoordinateConversionTests {
    @Test func screenshotCenterMapsToDisplayCenter() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let globalLocation = CompanionManager.convertScreenshotPixelLocationToGlobalScreenLocation(
            screenshotPixelLocation: CGPoint(x: 640, y: 415.5),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 831,
            displayWidthInPoints: 1512,
            displayHeightInPoints: 982,
            displayFrame: displayFrame
        )
        #expect(abs(globalLocation.x - 756) < 0.5)
        #expect(abs(globalLocation.y - 491) < 0.5)
    }

    @Test func topOfScreenshotMapsToTopOfDisplayBecauseAppKitYPointsUp() {
        let globalLocation = CompanionManager.convertScreenshotPixelLocationToGlobalScreenLocation(
            screenshotPixelLocation: CGPoint(x: 0, y: 0),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 800,
            displayWidthInPoints: 1440,
            displayHeightInPoints: 900,
            displayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        )
        #expect(globalLocation == CGPoint(x: 0, y: 900))
    }

    @Test func secondaryDisplayOffsetIsApplied() {
        // A second monitor to the right of a 1512pt-wide laptop screen, raised by 100pt
        let secondaryDisplayFrame = CGRect(x: 1512, y: 100, width: 1920, height: 1080)
        let globalLocation = CompanionManager.convertScreenshotPixelLocationToGlobalScreenLocation(
            screenshotPixelLocation: CGPoint(x: 640, y: 360),
            screenshotWidthInPixels: 1280,
            screenshotHeightInPixels: 720,
            displayWidthInPoints: 1920,
            displayHeightInPoints: 1080,
            displayFrame: secondaryDisplayFrame
        )
        #expect(globalLocation == CGPoint(x: 1512 + 960, y: 100 + 540))
    }
}

// MARK: - Lost Element Announcement

struct LostTrackedElementAnnouncementTests {
    private let frameWidth = 1280
    private let frameHeight = 800

    private func lastSeenPosition(lastKnownLocation: CGPoint, lastMovement: CGPoint) -> TrackedElementLastSeenPosition {
        return TrackedElementLastSeenPosition.determine(
            lastKnownTargetLocationInScreenshotPixels: lastKnownLocation,
            lastObservedTargetMovementInScreenshotPixels: lastMovement,
            frameWidthInPixels: frameWidth,
            frameHeightInPixels: frameHeight
        )
    }

    @Test func scrollingDownPushesTheElementOffTheTop() {
        // Content moves up when the user scrolls down
        let position = lastSeenPosition(lastKnownLocation: CGPoint(x: 400, y: 50), lastMovement: CGPoint(x: 0, y: -60))
        #expect(position == .scrolledOffTop)
    }

    @Test func fastFlickFromMidScreenStillCountsAsOffTheTop() {
        // Last seen well inside the screen, but moving fast enough to be gone next frame
        let position = lastSeenPosition(lastKnownLocation: CGPoint(x: 400, y: 120), lastMovement: CGPoint(x: 0, y: -200))
        #expect(position == .scrolledOffTop)
    }

    @Test func scrollingUpPushesTheElementOffTheBottom() {
        let position = lastSeenPosition(lastKnownLocation: CGPoint(x: 400, y: 760), lastMovement: CGPoint(x: 0, y: 40))
        #expect(position == .scrolledOffBottom)
    }

    @Test func horizontalMovesAreDetected() {
        #expect(lastSeenPosition(lastKnownLocation: CGPoint(x: 30, y: 400), lastMovement: CGPoint(x: -50, y: 0)) == .movedOffLeft)
        #expect(lastSeenPosition(lastKnownLocation: CGPoint(x: 1250, y: 400), lastMovement: CGPoint(x: 50, y: 0)) == .movedOffRight)
    }

    @Test func standingStillNearAnEdgeIsNotLeavingTheScreen() {
        // Near the top but not moving: it was covered, not scrolled away
        let position = lastSeenPosition(lastKnownLocation: CGPoint(x: 200, y: 40), lastMovement: .zero)
        #expect(position == .disappearedWhileOnScreen(screenAreaDescription: "top left"))
    }

    @Test func disappearingMidScreenNamesWhereItWas() {
        let position = lastSeenPosition(lastKnownLocation: CGPoint(x: 640, y: 400), lastMovement: CGPoint(x: 0, y: -5))
        #expect(position == .disappearedWhileOnScreen(screenAreaDescription: "middle"))
    }

    @Test func screenAreasUseNaturalNames() {
        func area(_ x: CGFloat, _ y: CGFloat) -> String {
            TrackedElementLastSeenPosition.screenAreaDescription(of: CGPoint(x: x, y: y), frameWidth: 1280, frameHeight: 800)
        }
        #expect(area(100, 100) == "top left")
        #expect(area(640, 100) == "top")
        #expect(area(1200, 400) == "right")
        #expect(area(640, 400) == "middle")
        #expect(area(1200, 700) == "bottom right")
    }

    @Test func announcementUsesClaudesElementLabel() {
        let announcement = TrackedElementLastSeenPosition.scrolledOffTop.spokenAnnouncement(elementLabel: "Save Button")
        #expect(announcement == "the save button scrolled off the top of your screen. scroll back up a little and it'll be right there.")
    }

    @Test func announcementFallsBackToItWithoutALabel() {
        let announcement = TrackedElementLastSeenPosition.movedOffLeft.spokenAnnouncement(elementLabel: nil)
        #expect(announcement.hasPrefix("it moved off the left side"))
    }

    @Test func announcementDoesNotDoubleTheWordThe() {
        let announcement = TrackedElementLastSeenPosition.scrolledOffBottom.spokenAnnouncement(elementLabel: "the search bar")
        #expect(announcement.hasPrefix("the search bar scrolled off the bottom"))
    }

    @Test func scrollEstimateAboveTheDisplayMeansScrolledOffTheTop() {
        // AppKit y points up, so "above the display" is a y larger than maxY
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(TrackedElementLastSeenPosition.fromEstimatedScreenLocation(CGPoint(x: 400, y: 1050), displayFrame: displayFrame) == .scrolledOffTop)
        #expect(TrackedElementLastSeenPosition.fromEstimatedScreenLocation(CGPoint(x: 400, y: -30), displayFrame: displayFrame) == .scrolledOffBottom)
        #expect(TrackedElementLastSeenPosition.fromEstimatedScreenLocation(CGPoint(x: 1600, y: 500), displayFrame: displayFrame) == .movedOffRight)
    }

    @Test func scrollEstimateStillOnTheDisplayGivesNoDirection() {
        let displayFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(TrackedElementLastSeenPosition.fromEstimatedScreenLocation(CGPoint(x: 400, y: 500), displayFrame: displayFrame) == nil)
    }

    @Test func disappearedAnnouncementSaysWhereItWas() {
        let announcement = TrackedElementLastSeenPosition
            .disappearedWhileOnScreen(screenAreaDescription: "top left")
            .spokenAnnouncement(elementLabel: "export menu")
        #expect(announcement == "i can't see the export menu anymore. it was near the top left of your screen, so something might be covering it now.")
    }
}

// MARK: - Anchored Position Estimate

struct TrackedElementPositionEstimatorTests {
    private let startLocation = CGPoint(x: 500, y: 600)

    @Test func scrollEventsMoveTheEstimateImmediately() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 10.0)
        // Positive deltaY = content moves down on screen = lower AppKit y
        estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 12, timestamp: 10.01)
        estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 8, timestamp: 10.02)
        #expect(estimator.estimatedScreenLocation == CGPoint(x: 500, y: 580))
    }

    @Test func measurementReAnchorsAndKeepsScrollingThatHappenedAfterTheFrame() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 10.0)
        estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 10, timestamp: 10.05)
        // This scroll happens after the frame below was captured, so the frame can't show it
        estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 15, timestamp: 10.15)

        // The frame (captured at 10.10) shows the element 10pt lower: only the first
        // scroll. Adding the later 15pt scroll puts it at y 575, exactly where the
        // scroll events already moved the estimate, so y must not jump back to 590.
        estimator.applyTrackingMeasurement(measuredScreenLocation: CGPoint(x: 512, y: 590), frameCaptureTimestamp: 10.10)

        #expect(estimator.estimatedScreenLocation.y == 575)
        // The 12pt sideways measurement error is blended in, not applied at once
        #expect(abs(estimator.estimatedScreenLocation.x - (500 + 12 * TrackedElementPositionEstimator.correctionBlendWeight)) < 0.001)
    }

    @Test func largeMismatchIsAppliedInFull() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 10.0)
        // The element was re-found 200pt away: not noise, so no gradual blending
        estimator.applyTrackingMeasurement(measuredScreenLocation: CGPoint(x: 500, y: 400), frameCaptureTimestamp: 10.1)
        #expect(estimator.estimatedScreenLocation == CGPoint(x: 500, y: 400))
    }

    @Test func learnsWhenContentMovesOppositeToTheScrollDeltas() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 0)
        var measuredLocation = startLocation

        // Each frame interval: 40pt of scroll, but the content actually moves UP 40pt
        for frameIndex in 1...8 {
            let frameTimestamp = Double(frameIndex) * 0.1
            estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 40, timestamp: frameTimestamp - 0.05)
            measuredLocation.y += 40
            estimator.applyTrackingMeasurement(measuredScreenLocation: measuredLocation, frameCaptureTimestamp: frameTimestamp)
        }

        #expect(estimator.scrollToScreenMovementScale < -0.9)
    }

    @Test func learnsAppsThatScrollFasterThanTheDeltas() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 0)
        var measuredLocation = startLocation

        // Content moves 1.5x the scroll delta
        for frameIndex in 1...10 {
            let frameTimestamp = Double(frameIndex) * 0.1
            estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 40, timestamp: frameTimestamp - 0.05)
            measuredLocation.y -= 60
            estimator.applyTrackingMeasurement(measuredScreenLocation: measuredLocation, frameCaptureTimestamp: frameTimestamp)
        }

        #expect(abs(estimator.scrollToScreenMovementScale - 1.5) < 0.05)
    }

    @Test func tinyScrollsDoNotChangeTheCalibration() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 0)
        estimator.applyScrollWheelMovement(scrollingDeltaX: 0, scrollingDeltaY: 5, timestamp: 0.05)
        // Measurement disagrees wildly, but 5pt is too small to calibrate from
        estimator.applyTrackingMeasurement(measuredScreenLocation: CGPoint(x: 500, y: 700), frameCaptureTimestamp: 0.1)
        #expect(estimator.scrollToScreenMovementScale == 1)
    }

    @Test func staleFramesAreIgnored() {
        var estimator = TrackedElementPositionEstimator(initialScreenLocation: startLocation, frameCaptureTimestamp: 5.0)
        estimator.applyTrackingMeasurement(measuredScreenLocation: CGPoint(x: 0, y: 0), frameCaptureTimestamp: 4.0)
        #expect(estimator.estimatedScreenLocation == startLocation)
    }
}

// MARK: - Element Tracking

@MainActor
struct ScreenElementTemplateTrackerTests {
    private static let viewportWidthInPixels = 1280
    private static let viewportHeightInPixels = 800
    /// The viewport starts this far into the page horizontally so tests can
    /// also slide it left to simulate dragging the window to the right.
    private static let viewportStartingHorizontalOffset = 200
    /// Found locations must be within this many screenshot pixels of the truth.
    /// The tracker matches at 1/4 resolution, so a few pixels of error is expected.
    private static let maximumAllowedTrackingErrorInPixels: CGFloat = 8

    /// Expected element location in the viewport after scrolling down by
    /// `scrollOffset` and dragging the window right by `windowDragOffset`.
    private func expectedLocation(of pageLocation: CGPoint, scrollOffset: Int, windowDragOffset: Int) -> CGPoint {
        return CGPoint(
            x: pageLocation.x - CGFloat(Self.viewportStartingHorizontalOffset) + CGFloat(windowDragOffset),
            y: pageLocation.y - CGFloat(scrollOffset)
        )
    }

    private func viewport(of page: SyntheticPage, scrollOffset: Int, windowDragOffset: Int) -> CGImage {
        return page.image.cropping(to: CGRect(
            x: Self.viewportStartingHorizontalOffset - windowDragOffset,
            y: scrollOffset,
            width: Self.viewportWidthInPixels,
            height: Self.viewportHeightInPixels
        ))!
    }

    private func distanceBetween(_ firstLocation: CGPoint, _ secondLocation: CGPoint) -> CGFloat {
        return hypot(firstLocation.x - secondLocation.x, firstLocation.y - secondLocation.y)
    }

    @Test func followsTargetThroughSmoothScrolling() throws {
        let page = SyntheticPage.makeVariedContentPage()
        let targetPageLocation = page.buttonCenterLocations[1]
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: targetPageLocation, scrollOffset: 0, windowDragOffset: 0)
        ))

        for scrollOffset in stride(from: 20, through: 300, by: 20) {
            let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: scrollOffset, windowDragOffset: 0))
            guard case .found(let trackedLocation) = result else {
                Issue.record("Lost the target at scroll offset \(scrollOffset)")
                return
            }
            let expected = expectedLocation(of: targetPageLocation, scrollOffset: scrollOffset, windowDragOffset: 0)
            #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                    "scroll \(scrollOffset): tracked \(trackedLocation), expected \(expected)")
        }
    }

    @Test func followsTargetThroughFastFlickScrolling() throws {
        // 150px between frames is a quick trackpad flick at 12 fps.
        // Apple's Vision tracker lost the element at these speeds.
        let page = SyntheticPage.makeVariedContentPage()
        // The third button starts low in the viewport (y ≈ 634), so it stays on
        // screen through four big scroll steps.
        let targetPageLocation = page.buttonCenterLocations[2]
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: targetPageLocation, scrollOffset: 0, windowDragOffset: 0)
        ))

        for scrollOffset in [150, 300, 450, 600] {
            let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: scrollOffset, windowDragOffset: 0))
            guard case .found(let trackedLocation) = result else {
                Issue.record("Lost the target at scroll offset \(scrollOffset)")
                return
            }
            let expected = expectedLocation(of: targetPageLocation, scrollOffset: scrollOffset, windowDragOffset: 0)
            #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                    "scroll \(scrollOffset): tracked \(trackedLocation), expected \(expected)")
        }
    }

    @Test func followsTargetWhenTheWindowIsDraggedAndScrolled() throws {
        let page = SyntheticPage.makeVariedContentPage()
        let targetPageLocation = page.buttonCenterLocations[1]
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: targetPageLocation, scrollOffset: 0, windowDragOffset: 0)
        ))

        let framesWithScrollAndDrag = [(0, 60), (30, 120), (60, 200), (90, 200)]
        for (scrollOffset, windowDragOffset) in framesWithScrollAndDrag {
            let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: scrollOffset, windowDragOffset: windowDragOffset))
            guard case .found(let trackedLocation) = result else {
                Issue.record("Lost the target at scroll \(scrollOffset), drag \(windowDragOffset)")
                return
            }
            let expected = expectedLocation(of: targetPageLocation, scrollOffset: scrollOffset, windowDragOffset: windowDragOffset)
            #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                    "scroll \(scrollOffset), drag \(windowDragOffset): tracked \(trackedLocation), expected \(expected)")
        }
    }

    @Test func reportsNotFoundInsteadOfJumpingToALookAlikeWhenTargetScrollsOffScreen() throws {
        let page = SyntheticPage.makeVariedContentPage()
        let targetPageLocation = page.buttonCenterLocations[1]
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: targetPageLocation, scrollOffset: 0, windowDragOffset: 0)
        ))

        var scrollOffset = 0
        while true {
            scrollOffset += 60
            let expected = expectedLocation(of: targetPageLocation, scrollOffset: scrollOffset, windowDragOffset: 0)
            let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: scrollOffset, windowDragOffset: 0))

            if expected.y < -40 {
                // Fully scrolled off the top: must not claim to have found it
                #expect(result == .notFoundInThisFrame, "scroll \(scrollOffset): target is off-screen but tracker reported \(result)")
                if expected.y < -400 { break }
            } else if case .found(let trackedLocation) = result {
                // Still (partly) visible: if it reports a location, it must be the right one
                #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                        "scroll \(scrollOffset): tracked \(trackedLocation), expected \(expected)")
            }
        }
    }

    @Test func picksTheRightRowAmongIdenticalLookAlikes() throws {
        // A list of identical rows, like a file list where every row has the same "Edit" button
        let page = SyntheticPage.makeIdenticalRowsPage()
        let targetPageLocation = page.buttonCenterLocations[3]
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: targetPageLocation, scrollOffset: 0, windowDragOffset: 0)
        ))

        for scrollOffset in stride(from: 25, through: 250, by: 25) {
            let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: scrollOffset, windowDragOffset: 0))
            guard case .found(let trackedLocation) = result else {
                Issue.record("Lost the target at scroll offset \(scrollOffset)")
                return
            }
            let expected = expectedLocation(of: targetPageLocation, scrollOffset: scrollOffset, windowDragOffset: 0)
            #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                    "scroll \(scrollOffset): tracked \(trackedLocation), expected \(expected)")
        }
    }

    @Test func refusesToTrackABlankArea() {
        let blankPage = SyntheticPage.makeBlankPage()
        let tracker = ScreenElementTemplateTracker(
            referenceFrame: viewport(of: blankPage, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: CGPoint(x: 640, y: 400)
        )
        #expect(tracker == nil)
    }

    @Test func tracksATargetRightAtTheScreenEdge() throws {
        // Targets near an edge can't have a template centered on them; the
        // template shifts inward and the offset must still land on the target.
        let page = SyntheticPage.makeVariedContentPage()
        let pageLocationNearLeftEdge = CGPoint(x: CGFloat(Self.viewportStartingHorizontalOffset) + 30, y: 300)
        let tracker = try #require(ScreenElementTemplateTracker(
            referenceFrame: viewport(of: page, scrollOffset: 0, windowDragOffset: 0),
            targetLocationInScreenshotPixels: expectedLocation(of: pageLocationNearLeftEdge, scrollOffset: 0, windowDragOffset: 0)
        ))

        let result = tracker.locateTarget(in: viewport(of: page, scrollOffset: 100, windowDragOffset: 0))
        guard case .found(let trackedLocation) = result else {
            Issue.record("Lost a target near the screen edge")
            return
        }
        let expected = expectedLocation(of: pageLocationNearLeftEdge, scrollOffset: 100, windowDragOffset: 0)
        #expect(distanceBetween(trackedLocation, expected) <= Self.maximumAllowedTrackingErrorInPixels,
                "tracked \(trackedLocation), expected \(expected)")
    }
}

// MARK: - Synthetic Test Pages

/// A tall rendered page plus the exact centers of its buttons, in page
/// pixel coordinates with a top-left origin (matching screenshots).
private struct SyntheticPage {
    let image: CGImage
    let buttonCenterLocations: [CGPoint]

    private static let pageWidthInPixels = 1600
    private static let pageHeightInPixels = 4000

    /// Lines of random text with a colored button every 7th line. Buttons look
    /// alike in grayscale (same size, same brightness, only the label differs),
    /// which is exactly the look-alike situation the tracker must handle.
    static func makeVariedContentPage() -> SyntheticPage {
        var seededRandomNumberGenerator = SeededRandomNumberGenerator(seed: 42)
        let words = ["export", "settings", "profile", "the", "quick", "brown", "fox", "jumps", "over",
                     "lazy", "dog", "account", "billing", "save", "cancel", "project", "window", "help"]

        return render { drawingContext in
            var buttonCenterLocations: [CGPoint] = []
            var lineIndex = 0
            var lineTopY = 40

            while lineTopY < pageHeightInPixels - 60 {
                if lineIndex % 7 == 3 {
                    let buttonLeftX = 260 + Int.random(in: 0...300, using: &seededRandomNumberGenerator)
                    let buttonRectTopLeftOrigin = CGRect(x: buttonLeftX, y: lineTopY, width: 140, height: 32)
                    drawButton(in: drawingContext, rectWithTopLeftOrigin: buttonRectTopLeftOrigin,
                               label: "button \(lineIndex)", hue: CGFloat(lineIndex % 5) / 5)
                    buttonCenterLocations.append(CGPoint(x: buttonRectTopLeftOrigin.midX, y: buttonRectTopLeftOrigin.midY))
                } else {
                    let wordCount = Int.random(in: 4...12, using: &seededRandomNumberGenerator)
                    let lineText = (0..<wordCount).map { _ in words.randomElement(using: &seededRandomNumberGenerator)! }
                        .joined(separator: " ")
                    drawText(lineText, atTopLeft: CGPoint(x: 240, y: lineTopY + 6), fontSize: 14,
                             color: .darkGray, bold: false)
                }
                lineTopY += 34
                lineIndex += 1
            }
            return buttonCenterLocations
        }
    }

    /// Identical rows: same text, same button, evenly spaced.
    static func makeIdenticalRowsPage() -> SyntheticPage {
        return render { drawingContext in
            var buttonCenterLocations: [CGPoint] = []
            var rowTopY = 40
            while rowTopY < pageHeightInPixels - 80 {
                drawText("quarterly report final.pdf", atTopLeft: CGPoint(x: 260, y: rowTopY + 8), fontSize: 14,
                         color: .darkGray, bold: false)
                let buttonRectTopLeftOrigin = CGRect(x: 620, y: rowTopY, width: 80, height: 30)
                drawButton(in: drawingContext, rectWithTopLeftOrigin: buttonRectTopLeftOrigin, label: "Edit", hue: 0.6)
                buttonCenterLocations.append(CGPoint(x: buttonRectTopLeftOrigin.midX, y: buttonRectTopLeftOrigin.midY))
                rowTopY += 90
            }
            return buttonCenterLocations
        }
    }

    static func makeBlankPage() -> SyntheticPage {
        return render { _ in [] }
    }

    private static func render(drawContent: (CGContext) -> [CGPoint]) -> SyntheticPage {
        let drawingContext = CGContext(
            data: nil,
            width: pageWidthInPixels,
            height: pageHeightInPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        drawingContext.setFillColor(NSColor.white.cgColor)
        drawingContext.fill(CGRect(x: 0, y: 0, width: pageWidthInPixels, height: pageHeightInPixels))

        // Flip so drawing code can use top-left coordinates like a screenshot
        drawingContext.translateBy(x: 0, y: CGFloat(pageHeightInPixels))
        drawingContext.scaleBy(x: 1, y: -1)

        let previousGraphicsContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: drawingContext, flipped: true)
        let buttonCenterLocations = drawContent(drawingContext)
        NSGraphicsContext.current = previousGraphicsContext

        return SyntheticPage(image: drawingContext.makeImage()!, buttonCenterLocations: buttonCenterLocations)
    }

    private static func drawButton(in drawingContext: CGContext, rectWithTopLeftOrigin: CGRect, label: String, hue: CGFloat) {
        drawingContext.setFillColor(NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
        drawingContext.fill(rectWithTopLeftOrigin)
        drawText(label, atTopLeft: CGPoint(x: rectWithTopLeftOrigin.minX + 14, y: rectWithTopLeftOrigin.minY + 7),
                 fontSize: 15, color: .white, bold: true)
    }

    private static func drawText(_ text: String, atTopLeft topLeftLocation: CGPoint, fontSize: CGFloat, color: NSColor, bold: Bool) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        (text as NSString).draw(at: topLeftLocation, withAttributes: [.font: font, .foregroundColor: color])
    }
}

/// Deterministic random numbers so the synthetic pages are identical on every run.
private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var currentState: UInt64

    init(seed: UInt64) {
        currentState = seed
    }

    mutating func next() -> UInt64 {
        // SplitMix64
        currentState &+= 0x9E3779B97F4A7C15
        var mixedValue = currentState
        mixedValue = (mixedValue ^ (mixedValue >> 30)) &* 0xBF58476D1CE4E5B9
        mixedValue = (mixedValue ^ (mixedValue >> 27)) &* 0x94D049BB133111EB
        return mixedValue ^ (mixedValue >> 31)
    }
}
