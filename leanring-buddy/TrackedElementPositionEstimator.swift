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
//  Some apps scroll content faster or slower than the event deltas, and if the
//  scroll direction convention were ever flipped the buddy would move the wrong
//  way. Each frame measurement therefore also calibrates how much on-screen
//  movement one point of scroll delta produces.
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
    /// The learned scale stays within this range. Negative means the content
    /// moves opposite to the scroll deltas.
    static let allowedScrollToScreenMovementScaleRange: ClosedRange<CGFloat> = -2...2
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
    mutating func applyTrackingMeasurement(measuredScreenLocation: CGPoint, frameCaptureTimestamp: TimeInterval) {
        // Frames can arrive out of order across displays; ignore stale ones.
        guard frameCaptureTimestamp >= lastMeasurementFrameCaptureTimestamp else { return }

        let verticalScrollBetweenFrames = totalScrollingDelta(
            after: lastMeasurementFrameCaptureTimestamp,
            upTo: frameCaptureTimestamp
        ).deltaY
        if abs(verticalScrollBetweenFrames) >= Self.minimumScrollBetweenFramesForCalibrationInPoints {
            let measuredVerticalMovement = measuredScreenLocation.y - lastMeasuredScreenLocation.y
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
