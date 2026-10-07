//
//  LostTrackedElementAnnouncement.swift
//  leanring-buddy
//
//  When a live session loses track of the element Clicky was pointing at,
//  works out where it went (scrolled off the top, off the left side, or just
//  vanished mid-screen) and turns that into what Clicky says out loud and
//  shows in the status bubble.
//

import CoreGraphics
import Foundation

nonisolated enum TrackedElementLastSeenPosition: Equatable {
    case scrolledOffTop
    case scrolledOffBottom
    case movedOffLeft
    case movedOffRight
    /// The element disappeared away from any edge (for example a dialog
    /// covered it or the page changed). The description names the screen area
    /// where it was last seen, like "top left" or "middle".
    case disappearedWhileOnScreen(screenAreaDescription: String)

    /// How close (in screenshot pixels) to an edge the element must be, while
    /// moving toward that edge, to count as having left the screen that way.
    /// About one tracking template's height.
    static let screenEdgeMarginInScreenshotPixels: CGFloat = 80

    /// Decides where the element went from the last place it was found and the
    /// direction it was moving. Leaving the screen means its predicted next
    /// position is past an edge, or near an edge while still moving toward it.
    static func determine(
        lastKnownTargetLocationInScreenshotPixels lastKnownLocation: CGPoint,
        lastObservedTargetMovementInScreenshotPixels lastMovement: CGPoint,
        frameWidthInPixels: Int,
        frameHeightInPixels: Int
    ) -> TrackedElementLastSeenPosition {
        let frameWidth = CGFloat(frameWidthInPixels)
        let frameHeight = CGFloat(frameHeightInPixels)
        let edgeMargin = screenEdgeMarginInScreenshotPixels

        let predictedLocation = CGPoint(
            x: lastKnownLocation.x + lastMovement.x,
            y: lastKnownLocation.y + lastMovement.y
        )

        // How far past (or into the margin of) each edge the element is heading.
        // Only counts if it's actually past the edge, or moving toward it.
        func overshoot(distancePastMarginLine: CGFloat, isPastEdge: Bool, isMovingTowardEdge: Bool) -> CGFloat {
            guard distancePastMarginLine > 0, isPastEdge || isMovingTowardEdge else { return 0 }
            return distancePastMarginLine
        }

        let overshootPerExitDirection: [(TrackedElementLastSeenPosition, CGFloat)] = [
            (.scrolledOffTop, overshoot(
                distancePastMarginLine: edgeMargin - predictedLocation.y,
                isPastEdge: predictedLocation.y < 0,
                isMovingTowardEdge: lastMovement.y < 0)),
            (.scrolledOffBottom, overshoot(
                distancePastMarginLine: predictedLocation.y - (frameHeight - edgeMargin),
                isPastEdge: predictedLocation.y > frameHeight,
                isMovingTowardEdge: lastMovement.y > 0)),
            (.movedOffLeft, overshoot(
                distancePastMarginLine: edgeMargin - predictedLocation.x,
                isPastEdge: predictedLocation.x < 0,
                isMovingTowardEdge: lastMovement.x < 0)),
            (.movedOffRight, overshoot(
                distancePastMarginLine: predictedLocation.x - (frameWidth - edgeMargin),
                isPastEdge: predictedLocation.x > frameWidth,
                isMovingTowardEdge: lastMovement.x > 0))
        ]

        if let mostLikelyExit = overshootPerExitDirection.max(by: { $0.1 < $1.1 }), mostLikelyExit.1 > 0 {
            return mostLikelyExit.0
        }

        return .disappearedWhileOnScreen(screenAreaDescription: screenAreaDescription(
            of: lastKnownLocation,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ))
    }

    /// Uses the scroll-driven position estimate (global AppKit coordinates, y
    /// pointing up) to tell which edge the element left through. Returns nil
    /// if the estimate is still on the display, meaning it didn't scroll away.
    static func fromEstimatedScreenLocation(_ estimatedScreenLocation: CGPoint, displayFrame: CGRect) -> TrackedElementLastSeenPosition? {
        let distancePastEachEdge: [(TrackedElementLastSeenPosition, CGFloat)] = [
            (.scrolledOffTop, estimatedScreenLocation.y - displayFrame.maxY),
            (.scrolledOffBottom, displayFrame.minY - estimatedScreenLocation.y),
            (.movedOffLeft, displayFrame.minX - estimatedScreenLocation.x),
            (.movedOffRight, estimatedScreenLocation.x - displayFrame.maxX)
        ]
        guard let farthestPastEdge = distancePastEachEdge.max(by: { $0.1 < $1.1 }),
              farthestPastEdge.1 > 0 else {
            return nil
        }
        return farthestPastEdge.0
    }

    /// Names the third of the screen a location is in, the way a person would
    /// say it out loud: "top left", "bottom", "right", "middle".
    static func screenAreaDescription(of location: CGPoint, frameWidth: CGFloat, frameHeight: CGFloat) -> String {
        let verticalArea: String
        if location.y < frameHeight / 3 {
            verticalArea = "top"
        } else if location.y > frameHeight * 2 / 3 {
            verticalArea = "bottom"
        } else {
            verticalArea = "middle"
        }

        let horizontalArea: String
        if location.x < frameWidth / 3 {
            horizontalArea = "left"
        } else if location.x > frameWidth * 2 / 3 {
            horizontalArea = "right"
        } else {
            horizontalArea = "center"
        }

        switch (verticalArea, horizontalArea) {
        case ("middle", "center"):
            return "middle"
        case (_, "center"):
            return verticalArea
        case ("middle", _):
            return horizontalArea
        default:
            return "\(verticalArea) \(horizontalArea)"
        }
    }

    /// What Clicky says out loud. Written for the ear in Clicky's casual
    /// lowercase voice, matching the companion system prompt's style rules.
    func spokenAnnouncement(elementLabel: String?) -> String {
        let elementName = Self.spokenElementName(elementLabel: elementLabel)

        switch self {
        case .scrolledOffTop:
            return "\(elementName) scrolled off the top of your screen. scroll back up a little and it'll be right there."
        case .scrolledOffBottom:
            return "\(elementName) scrolled off the bottom of your screen. scroll back down a little and it'll be right there."
        case .movedOffLeft:
            return "\(elementName) moved off the left side of your screen. it's over to the left now."
        case .movedOffRight:
            return "\(elementName) moved off the right side of your screen. it's over to the right now."
        case .disappearedWhileOnScreen(let screenAreaDescription):
            let whereItWas = screenAreaDescription == "middle"
                ? "in the middle of your screen"
                : "near the \(screenAreaDescription) of your screen"
            return "i can't see \(elementName) anymore. it was \(whereItWas), so something might be covering it now."
        }
    }

    /// Short version for the status bubble next to the cursor.
    var statusBubbleText: String {
        switch self {
        case .scrolledOffTop:
            return "scrolled off the top ↑"
        case .scrolledOffBottom:
            return "scrolled off the bottom ↓"
        case .movedOffLeft:
            return "moved off to the left ←"
        case .movedOffRight:
            return "moved off to the right →"
        case .disappearedWhileOnScreen:
            return "lost sight of it"
        }
    }

    /// Turns Claude's short element label (e.g. "save button") into "the save
    /// button". Falls back to "it" when Claude didn't label the element.
    private static func spokenElementName(elementLabel: String?) -> String {
        guard let trimmedLabel = elementLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmedLabel.isEmpty, trimmedLabel != "none" else {
            return "it"
        }
        if trimmedLabel.hasPrefix("the ") {
            return trimmedLabel
        }
        return "the \(trimmedLabel)"
    }
}
