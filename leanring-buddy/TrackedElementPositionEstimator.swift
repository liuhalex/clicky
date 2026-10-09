//
//  TrackedElementPositionEstimator.swift
//  leanring-buddy
//
//  Keeps the buddy anchored to a tracked element while the user scrolls.
//
//  Screen frames only arrive ~12 times a second and each one takes a moment
//  to analyze, so following frames alone makes the buddy lag behind and then
//  catch up ("scroll away, snap back"). Scroll wheel / trackpad events arrive
//  instantly and say exactly how far the content moved, so the estimate moves
//  with every scroll event, and each analyzed frame only corrects the drift.
//
//  Some apps scroll content faster or slower than the event deltas, so each
//  frame measurement also calibrates how much on-screen movement one point of
//  scroll delta produces.
//
//  When scrolling and a frame match disagree, scrolling wins. A match that
//  stays put while the user scrolls has latched onto something that doesn't
//  scroll: GitHub, for example, keeps a copy of a repo's Watch / Fork / Star
//  buttons pinned at the top. Trusting it froze the buddy and taught the
//  estimator that the page doesn't scroll.
//
//  All locations are global AppKit screen coordinates (bottom-left origin).
//

import CoreGraphics
import Foundation

nonisolated struct TrackedElementPositionEstimator {
    /// Scroll events older than this can't matter for re-anchoring, because
    /// frame measurements are never this far behind.
    static let scrollHistoryDurationSeconds: TimeInterval = 1.0
    /// Only scrolls at least this large between two frames are used to
    /// calibrate, so tiny scrolls don't produce noisy estimates.
    static let minimumScrollBetweenFramesForCalibrationInPoints: CGFloat = 30
    /// How strongly each calibration sample updates the scale (0...1).
    static let calibrationSampleWeight: CGFloat = 0.35
    /// The learned scale stays within this range. Content always moves with the
    /// scroll (measured 0.91 in Safari, 1.0 on GitHub in Chrome), so a much
    /// smaller scale can only come from a bad match and isn't learned.
    static let allowedScrollToScreenMovementScaleRange: ClosedRange<CGFloat> = 0.5...2
    /// While scrolling, a match must move at least this share of the movement
    /// the scroll predicts, in the same direction, to be trusted.
    static let minimumShareOfScrollMovementForTrustedMeasurement: CGFloat = 0.3
    /// Fraction of a frame measurement's correction applied right away. Frame
    /// timestamps and 4px matching resolution make each measurement a few points
    /// off; applying them fully made the buddy shake while scrolling, so small
    /// corrections are blended in over a few frames instead.
    static let correctionBlendWeight: CGFloat = 0.35
    /// A correction this large (in points) isn't measurement noise; the element
    /// really is somewhere else (for example, it was re-found after a jump), so
    /// it's applied in full.
    static let correctionDistanceAppliedInFull: CGFloat = 60

    private struct ScrollMovement {
        let timestamp: TimeInterval
        let scrollingDeltaX: CGFloat
        let scrollingDeltaY: CGFloat
    }

    private(set) var estimatedScreenLocation: CGPoint
    /// On-screen movement per point of scroll delta, learned from frame measurements.
    private(set) var scrollToScreenMovementScale: CGFloat = 1
    private var recentScrollMovements: [ScrollMovement] = []
    private var lastMeasuredScreenLocation: CGPoint
    private var lastMeasurementFrameCaptureTimestamp: TimeInterval

    init(initialScreenLocation: CGPoint, frameCaptureTimestamp: TimeInterval) {
        estimatedScreenLocation = initialScreenLocation
        lastMeasuredScreenLocation = initialScreenLocation
        lastMeasurementFrameCaptureTimestamp = frameCaptureTimestamp
    }

    /// Applies one scroll event, using NSEvent's precise `scrollingDeltaX/Y`.
    /// Positive deltaY means the content moves down on screen, and AppKit's y
    /// axis points up, so the estimate's y goes down by deltaY.
    mutating func applyScrollWheelMovement(scrollingDeltaX: CGFloat, scrollingDeltaY: CGFloat, timestamp: TimeInterval) {
        recentScrollMovements.append(ScrollMovement(
            timestamp: timestamp,
            scrollingDeltaX: scrollingDeltaX,
            scrollingDeltaY: scrollingDeltaY
        ))
        recentScrollMovements.removeAll { scrollMovement in
            scrollMovement.timestamp < timestamp - Self.scrollHistoryDurationSeconds
        }

        estimatedScreenLocation.x += scrollToScreenMovementScale * scrollingDeltaX
        estimatedScreenLocation.y -= scrollToScreenMovementScale * scrollingDeltaY
    }

    /// Applies where the tracker found the element in a frame captured at
    /// `frameCaptureTimestamp`. Calibrates the scroll scale, then re-anchors the
    /// estimate on the measurement plus any scrolling that happened after the
    /// frame was captured (which the frame can't show yet).
    /// Returns false if the measurement was ignored: a stale frame, or a match
    /// that didn't move with the scrolling (so it isn't the element).
    @discardableResult
    mutating func applyTrackingMeasurement(measuredScreenLocation: CGPoint, frameCaptureTimestamp: TimeInterval) -> Bool {
        // Frames can arrive out of order across displays; ignore stale ones.
        guard frameCaptureTimestamp >= lastMeasurementFrameCaptureTimestamp else { return false }

        let verticalScrollBetweenFrames = totalScrollingDelta(
            after: lastMeasurementFrameCaptureTimestamp,
            upTo: frameCaptureTimestamp
        ).deltaY
        if abs(verticalScrollBetweenFrames) >= Self.minimumScrollBetweenFramesForCalibrationInPoints {
            let measuredVerticalMovement = measuredScreenLocation.y - lastMeasuredScreenLocation.y
            // Content moving down (positive delta) lowers AppKit y
            let expectedVerticalMovement = -scrollToScreenMovementScale * verticalScrollBetweenFrames
            let didMoveWithScrolling = measuredVerticalMovement * expectedVerticalMovement > 0
                && abs(measuredVerticalMovement) >= Self.minimumShareOfScrollMovementForTrustedMeasurement * abs(expectedVerticalMovement)
            guard didMoveWithScrolling else {
                // Keep the last good measurement, so the next match is checked
                // against everything scrolled since then
                return false
            }
            // Content moving down (positive delta) lowers AppKit y, hence the minus.
            let observedScale = -measuredVerticalMovement / verticalScrollBetweenFrames
            let clampedObservedScale = min(
                max(observedScale, Self.allowedScrollToScreenMovementScaleRange.lowerBound),
                Self.allowedScrollToScreenMovementScaleRange.upperBound
            )
            scrollToScreenMovementScale += Self.calibrationSampleWeight * (clampedObservedScale - scrollToScreenMovementScale)
        }

        let scrollSinceFrameWasCaptured = totalScrollingDelta(after: frameCaptureTimestamp, upTo: .infinity)
        let correctedScreenLocation = CGPoint(
            x: measuredScreenLocation.x + scrollToScreenMovementScale * scrollSinceFrameWasCaptured.deltaX,
            y: measuredScreenLocation.y - scrollToScreenMovementScale * scrollSinceFrameWasCaptured.deltaY
        )

        let correctionX = correctedScreenLocation.x - estimatedScreenLocation.x
        let correctionY = correctedScreenLocation.y - estimatedScreenLocation.y
        if hypot(correctionX, correctionY) >= Self.correctionDistanceAppliedInFull {
            estimatedScreenLocation = correctedScreenLocation
        } else {
            estimatedScreenLocation = CGPoint(
                x: estimatedScreenLocation.x + correctionX * Self.correctionBlendWeight,
                y: estimatedScreenLocation.y + correctionY * Self.correctionBlendWeight
            )
        }

        lastMeasuredScreenLocation = measuredScreenLocation
        lastMeasurementFrameCaptureTimestamp = frameCaptureTimestamp
        return true
    }

    /// How far scrolling moved the element on screen during the last second
    /// before `currentTimestamp` (AppKit points, y up: positive y means it
    /// was carried up). Zero if the user wasn't scrolling.
    func recentScrollDrivenScreenMovement(asOf currentTimestamp: TimeInterval) -> CGVector {
        let recentScrollingDelta = totalScrollingDelta(
            after: currentTimestamp - Self.scrollHistoryDurationSeconds,
            upTo: .infinity
        )
        return CGVector(
            dx: scrollToScreenMovementScale * recentScrollingDelta.deltaX,
            dy: -scrollToScreenMovementScale * recentScrollingDelta.deltaY
        )
    }

    private func totalScrollingDelta(after startTimestamp: TimeInterval, upTo endTimestamp: TimeInterval) -> (deltaX: CGFloat, deltaY: CGFloat) {
        var totalDeltaX: CGFloat = 0
        var totalDeltaY: CGFloat = 0
        for scrollMovement in recentScrollMovements
        where scrollMovement.timestamp > startTimestamp && scrollMovement.timestamp <= endTimestamp {
            totalDeltaX += scrollMovement.scrollingDeltaX
            totalDeltaY += scrollMovement.scrollingDeltaY
        }
        return (totalDeltaX, totalDeltaY)
    }
}
