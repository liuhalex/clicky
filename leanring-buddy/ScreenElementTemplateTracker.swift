//
//  ScreenElementTemplateTracker.swift
//  leanring-buddy
//
//  Keeps the buddy pointing at the right UI element while the screen changes
//  during a live session. When Claude points at something, we save a small
//  grayscale "template" image of the area around that spot. On every new
//  screen frame we search the whole frame for the region that best matches
//  the template (normalized cross-correlation), so the pointer follows the
//  element when the user scrolls or moves the window.
//
//  We search the whole frame instead of only near the last position because
//  a quick trackpad flick can move content hundreds of pixels between frames.
//  Apple's Vision object tracker (VNTrackObjectRequest) was evaluated first and
//  lost the element at scroll speeds above ~30px per frame while still
//  reporting high confidence, so it isn't used here.
//
//  All types are nonisolated because tracking runs on the live session's
//  background capture queue, never on the main actor.
//

import Accelerate
import CoreGraphics
import Foundation

/// A downscaled grayscale copy of a screen frame, stored as one brightness
/// value (0–255) per pixel in row-major order with row 0 at the top.
nonisolated struct GrayscaleTrackingImage {
    let widthInPixels: Int
    let heightInPixels: Int
    let pixelBrightnessValues: [Float]

    init(widthInPixels: Int, heightInPixels: Int, pixelBrightnessValues: [Float]) {
        self.widthInPixels = widthInPixels
        self.heightInPixels = heightInPixels
        self.pixelBrightnessValues = pixelBrightnessValues
    }

    /// Draws the image into a grayscale bitmap that is `downscaleFactor` times
    /// smaller in each dimension. Downscaling keeps matching fast enough to run
    /// on every frame, even in unoptimized Debug builds.
    init?(cgImage: CGImage, downscaleFactor: Int) {
        let downscaledWidth = cgImage.width / downscaleFactor
        let downscaledHeight = cgImage.height / downscaleFactor
        guard downscaledWidth > 0, downscaledHeight > 0 else { return nil }

        var eightBitBrightnessValues = [UInt8](repeating: 0, count: downscaledWidth * downscaledHeight)
        let didDrawImage = eightBitBrightnessValues.withUnsafeMutableBytes { brightnessBuffer -> Bool in
            guard let grayscaleContext = CGContext(
                data: brightnessBuffer.baseAddress,
                width: downscaledWidth,
                height: downscaledHeight,
                bitsPerComponent: 8,
                bytesPerRow: downscaledWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else {
                return false
            }
            grayscaleContext.interpolationQuality = .medium
            grayscaleContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: downscaledWidth, height: downscaledHeight))
            return true
        }
        guard didDrawImage else { return nil }

        var floatBrightnessValues = [Float](repeating: 0, count: eightBitBrightnessValues.count)
        vDSP_vfltu8(eightBitBrightnessValues, 1, &floatBrightnessValues, 1, vDSP_Length(eightBitBrightnessValues.count))

        self.init(
            widthInPixels: downscaledWidth,
            heightInPixels: downscaledHeight,
            pixelBrightnessValues: Self.lightlyBlurred(
                pixelBrightnessValues: floatBrightnessValues,
                widthInPixels: downscaledWidth,
                heightInPixels: downscaledHeight
            )
        )
    }

    /// Scrolling rarely moves content by an exact multiple of the downscale
    /// factor, so the element usually lands between two downscaled pixels. A
    /// sharp image then matches noticeably worse at half-pixel offsets, enough
    /// for an identical look-alike row that happens to land on the pixel grid
    /// to outscore the real element. A light 3x3 blur spreads each detail over
    /// its neighbors so the score barely depends on sub-pixel position.
    private static func lightlyBlurred(pixelBrightnessValues: [Float], widthInPixels: Int, heightInPixels: Int) -> [Float] {
        guard widthInPixels >= 3, heightInPixels >= 3 else { return pixelBrightnessValues }

        var gaussianBlurKernel: [Float] = [
            1, 2, 1,
            2, 4, 2,
            1, 2, 1
        ].map { $0 / 16 }
        var blurredBrightnessValues = [Float](repeating: 0, count: pixelBrightnessValues.count)
        vDSP_f3x3(
            pixelBrightnessValues,
            vDSP_Length(heightInPixels),
            vDSP_Length(widthInPixels),
            &gaussianBlurKernel,
            &blurredBrightnessValues
        )

        // vDSP_f3x3 sets the outermost ring of pixels to zero. Left that way, a
        // template at the screen edge would contain a fake black stripe that
        // matches the same stripe at every height of every frame, so tracking
        // would drift. Keep the original (unblurred) pixels on the border instead.
        for columnIndex in 0..<widthInPixels {
            let lastRowIndex = (heightInPixels - 1) * widthInPixels + columnIndex
            blurredBrightnessValues[columnIndex] = pixelBrightnessValues[columnIndex]
            blurredBrightnessValues[lastRowIndex] = pixelBrightnessValues[lastRowIndex]
        }
        for rowIndex in 0..<heightInPixels {
            let firstColumnIndex = rowIndex * widthInPixels
            let lastColumnIndex = firstColumnIndex + widthInPixels - 1
            blurredBrightnessValues[firstColumnIndex] = pixelBrightnessValues[firstColumnIndex]
            blurredBrightnessValues[lastColumnIndex] = pixelBrightnessValues[lastColumnIndex]
        }

        return blurredBrightnessValues
    }

    /// Copies the rectangle whose top-left pixel is (originX, originY).
    /// Returns nil if the rectangle doesn't fit entirely inside the image.
    func croppedRegion(originX: Int, originY: Int, regionWidth: Int, regionHeight: Int) -> GrayscaleTrackingImage? {
        guard originX >= 0, originY >= 0,
              originX + regionWidth <= widthInPixels,
              originY + regionHeight <= heightInPixels else {
            return nil
        }

        var regionBrightnessValues: [Float] = []
        regionBrightnessValues.reserveCapacity(regionWidth * regionHeight)
        for rowIndex in originY..<(originY + regionHeight) {
            let rowStartIndex = rowIndex * widthInPixels + originX
            regionBrightnessValues.append(contentsOf: pixelBrightnessValues[rowStartIndex..<(rowStartIndex + regionWidth)])
        }

        return GrayscaleTrackingImage(
            widthInPixels: regionWidth,
            heightInPixels: regionHeight,
            pixelBrightnessValues: regionBrightnessValues
        )
    }
}

/// One candidate location for the template inside a frame.
nonisolated struct TemplateMatchCandidate: Equatable {
    /// Center of the matched region, in the searched image's pixel coordinates (top-left origin).
    let centerX: Int
    let centerY: Int
    /// Normalized cross-correlation score from -1 to 1. 1 means a pixel-perfect match.
    let similarityScore: Float
}

/// How well the template matches at every possible center position of a frame.
nonisolated struct TemplateSimilarityScoreMap {
    /// Positions where the template doesn't fit, or the frame region is too
    /// plain to compare, get this score so they're never chosen.
    static let unscoredPositionScore: Float = -2

    let widthInPixels: Int
    let heightInPixels: Int
    let templateWidthInPixels: Int
    let templateHeightInPixels: Int
    /// Row-major, row 0 at the top. Indexed by the template's center position.
    let similarityScoreAtEachCenter: [Float]

    /// The best-scoring position anywhere in the frame.
    func bestMatch() -> TemplateMatchCandidate? {
        var bestMatch: TemplateMatchCandidate? = nil
        for centerY in 0..<heightInPixels {
            for centerX in 0..<widthInPixels {
                let similarityScore = similarityScoreAtEachCenter[centerY * widthInPixels + centerX]
                if similarityScore > (bestMatch?.similarityScore ?? Self.unscoredPositionScore) {
                    bestMatch = TemplateMatchCandidate(centerX: centerX, centerY: centerY, similarityScore: similarityScore)
                }
            }
        }
        return bestMatch
    }

    /// The best-scoring position that doesn't overlap `excludedMatch`. Comparing
    /// it with the best match tells us whether the best match is unique or one
    /// of several look-alikes, like identical rows in a list.
    func bestMatch(notOverlapping excludedMatch: TemplateMatchCandidate) -> TemplateMatchCandidate? {
        var bestMatch: TemplateMatchCandidate? = nil
        for centerY in 0..<heightInPixels {
            for centerX in 0..<widthInPixels {
                let overlapsExcludedMatch = abs(centerX - excludedMatch.centerX) < templateWidthInPixels
                    && abs(centerY - excludedMatch.centerY) < templateHeightInPixels
                if overlapsExcludedMatch { continue }

                let similarityScore = similarityScoreAtEachCenter[centerY * widthInPixels + centerX]
                if similarityScore > (bestMatch?.similarityScore ?? Self.unscoredPositionScore) {
                    bestMatch = TemplateMatchCandidate(centerX: centerX, centerY: centerY, similarityScore: similarityScore)
                }
            }
        }
        return bestMatch
    }

    /// The best position within `searchRadius` of an expected location, where
    /// each position's score is reduced by `scorePenaltyPerPixelOfDistance` for
    /// every pixel it is away from the expected location. The returned candidate
    /// carries its real (unpenalized) score.
    ///
    /// The penalty is what keeps tracking on the right element among
    /// look-alikes: identical list rows score within a few hundredths of each
    /// other, so the one where the element should be (based on its motion) wins.
    func bestMatchFavoringCloseness(
        toExpectedCenterX expectedCenterX: CGFloat,
        expectedCenterY: CGFloat,
        searchRadius: CGFloat,
        scorePenaltyPerPixelOfDistance: Float
    ) -> TemplateMatchCandidate? {
        let searchRowRange = max(0, Int(expectedCenterY - searchRadius))...min(heightInPixels - 1, Int(expectedCenterY + searchRadius))
        let searchColumnRange = max(0, Int(expectedCenterX - searchRadius))...min(widthInPixels - 1, Int(expectedCenterX + searchRadius))
        guard !searchRowRange.isEmpty, !searchColumnRange.isEmpty else { return nil }

        var bestMatch: TemplateMatchCandidate? = nil
        var bestPenalizedScore = -Float.infinity
        for centerY in searchRowRange {
            for centerX in searchColumnRange {
                let similarityScore = similarityScoreAtEachCenter[centerY * widthInPixels + centerX]
                guard similarityScore > Self.unscoredPositionScore else { continue }

                let distanceFromExpectedCenter = hypot(CGFloat(centerX) - expectedCenterX, CGFloat(centerY) - expectedCenterY)
                guard distanceFromExpectedCenter <= searchRadius else { continue }

                let penalizedScore = similarityScore - Float(distanceFromExpectedCenter) * scorePenaltyPerPixelOfDistance
                if penalizedScore > bestPenalizedScore {
                    bestPenalizedScore = penalizedScore
                    bestMatch = TemplateMatchCandidate(centerX: centerX, centerY: centerY, similarityScore: similarityScore)
                }
            }
        }
        return bestMatch
    }
}

nonisolated enum TemplateMatcher {
    /// Regions flatter than this (almost no brightness variation, like an empty
    /// background) can't be told apart from each other, so they're skipped.
    private static let minimumRegionBrightnessVariance: Double = 1.0

    /// Scores how well `template` matches at every position of `searchImage`
    /// using normalized cross-correlation. The template must have odd width and
    /// height so it has a center pixel. Returns nil if the template is too
    /// plain to match or larger than the image.
    static func computeSimilarityScoreMap(
        template: GrayscaleTrackingImage,
        searchImage: GrayscaleTrackingImage
    ) -> TemplateSimilarityScoreMap? {
        let templateWidth = template.widthInPixels
        let templateHeight = template.heightInPixels
        let searchWidth = searchImage.widthInPixels
        let searchHeight = searchImage.heightInPixels

        guard templateWidth % 2 == 1, templateHeight % 2 == 1,
              searchWidth >= templateWidth, searchHeight >= templateHeight else {
            return nil
        }

        let templatePixelCount = Double(templateWidth * templateHeight)

        // Subtracting the template's mean makes the correlation ignore overall
        // brightness, so a match still works if the frame gets slightly lighter or darker.
        var templateMeanBrightness: Float = 0
        vDSP_meanv(template.pixelBrightnessValues, 1, &templateMeanBrightness, vDSP_Length(template.pixelBrightnessValues.count))
        var zeroMeanTemplate = template.pixelBrightnessValues.map { $0 - templateMeanBrightness }
        var templateSumOfSquares: Float = 0
        vDSP_svesq(zeroMeanTemplate, 1, &templateSumOfSquares, vDSP_Length(zeroMeanTemplate.count))
        guard Double(templateSumOfSquares) / templatePixelCount >= minimumRegionBrightnessVariance else {
            return nil
        }

        // vDSP_imgfir slides the template over every position of the image and
        // returns the dot product at each one, centered on the output pixel.
        // This is the expensive part, and Accelerate does it fully vectorized.
        var dotProductAtEachCenter = [Float](repeating: 0, count: searchImage.pixelBrightnessValues.count)
        vDSP_imgfir(
            searchImage.pixelBrightnessValues,
            vDSP_Length(searchHeight),
            vDSP_Length(searchWidth),
            &zeroMeanTemplate,
            &dotProductAtEachCenter,
            vDSP_Length(templateHeight),
            vDSP_Length(templateWidth)
        )

        // Summed-area tables let us get the brightness sum and sum of squares of
        // any window in constant time, which we need to normalize each score.
        let summedAreaTableWidth = searchWidth + 1
        var brightnessSummedAreaTable = [Double](repeating: 0, count: summedAreaTableWidth * (searchHeight + 1))
        var squaredBrightnessSummedAreaTable = brightnessSummedAreaTable
        for rowIndex in 0..<searchHeight {
            var runningRowSum = 0.0
            var runningRowSumOfSquares = 0.0
            for columnIndex in 0..<searchWidth {
                let brightness = Double(searchImage.pixelBrightnessValues[rowIndex * searchWidth + columnIndex])
                runningRowSum += brightness
                runningRowSumOfSquares += brightness * brightness
                let tableIndex = (rowIndex + 1) * summedAreaTableWidth + columnIndex + 1
                let tableIndexOneRowUp = rowIndex * summedAreaTableWidth + columnIndex + 1
                brightnessSummedAreaTable[tableIndex] = brightnessSummedAreaTable[tableIndexOneRowUp] + runningRowSum
                squaredBrightnessSummedAreaTable[tableIndex] = squaredBrightnessSummedAreaTable[tableIndexOneRowUp] + runningRowSumOfSquares
            }
        }

        func windowSum(_ summedAreaTable: [Double], left: Int, top: Int, right: Int, bottom: Int) -> Double {
            return summedAreaTable[bottom * summedAreaTableWidth + right]
                - summedAreaTable[top * summedAreaTableWidth + right]
                - summedAreaTable[bottom * summedAreaTableWidth + left]
                + summedAreaTable[top * summedAreaTableWidth + left]
        }

        let halfTemplateWidth = templateWidth / 2
        let halfTemplateHeight = templateHeight / 2
        var similarityScoreAtEachCenter = [Float](
            repeating: TemplateSimilarityScoreMap.unscoredPositionScore,
            count: searchWidth * searchHeight
        )

        for centerY in halfTemplateHeight..<(searchHeight - halfTemplateHeight) {
            for centerX in halfTemplateWidth..<(searchWidth - halfTemplateWidth) {
                let windowLeft = centerX - halfTemplateWidth
                let windowTop = centerY - halfTemplateHeight
                let windowRight = centerX + halfTemplateWidth + 1
                let windowBottom = centerY + halfTemplateHeight + 1

                let windowBrightnessSum = windowSum(brightnessSummedAreaTable, left: windowLeft, top: windowTop, right: windowRight, bottom: windowBottom)
                let windowSumOfSquares = windowSum(squaredBrightnessSummedAreaTable, left: windowLeft, top: windowTop, right: windowRight, bottom: windowBottom)
                let windowVarianceTimesPixelCount = windowSumOfSquares - (windowBrightnessSum * windowBrightnessSum) / templatePixelCount
                guard windowVarianceTimesPixelCount / templatePixelCount >= minimumRegionBrightnessVariance else { continue }

                similarityScoreAtEachCenter[centerY * searchWidth + centerX] = dotProductAtEachCenter[centerY * searchWidth + centerX]
                    / Float((windowVarianceTimesPixelCount * Double(templateSumOfSquares)).squareRoot())
            }
        }

        return TemplateSimilarityScoreMap(
            widthInPixels: searchWidth,
            heightInPixels: searchHeight,
            templateWidthInPixels: templateWidth,
            templateHeightInPixels: templateHeight,
            similarityScoreAtEachCenter: similarityScoreAtEachCenter
        )
    }
}

/// Follows one UI element across a sequence of frames from the same display.
/// Create one when Claude points at something, then call `locateTarget(in:)`
/// with each new frame.
nonisolated final class ScreenElementTemplateTracker {
    enum TrackingResult: Equatable {
        /// The element was found. The location is in the frame's pixel coordinates (top-left origin).
        case found(targetLocationInScreenshotPixels: CGPoint)
        /// The element isn't confidently visible in this frame (for example it
        /// scrolled off-screen or something covered it).
        case notFoundInThisFrame
    }

    /// Frames are shrunk by this factor before matching. At 4x, a 1280px-wide
    /// screenshot becomes 320px, so each match is accurate to ~4 screenshot pixels,
    /// which is plenty for pointing at a button.
    static let downscaleFactor = 4

    /// Template size in downscaled pixels (must be odd). 41x17 covers about
    /// 164x68 screenshot pixels: enough surrounding context to make most UI
    /// elements distinctive, small enough to move as one piece when scrolling.
    static let templateWidthInDownscaledPixels = 41
    static let templateHeightInDownscaledPixels = 17

    /// Minimum similarity for a match near where we expect the element to be.
    static let minimumSimilarityForNearbyMatch: Float = 0.80
    /// How far (in screenshot pixels) from the predicted location to look for
    /// the element. 300px covers a fast flick between two frames.
    static let nearbySearchRadiusInScreenshotPixels: CGFloat = 300
    /// Score subtracted per screenshot pixel of distance from the predicted
    /// location (0.04 per 100px). Enough to break ties between identical
    /// look-alikes, small next to the gap between the real element and a
    /// different-looking one.
    static let scorePenaltyPerScreenshotPixelFromPrediction: Float = 0.0004
    /// A match outside the nearby search (or any match when the element is
    /// predicted to be leaving the screen) is only trusted if it's nearly perfect...
    static let minimumSimilarityForUnmistakableMatch: Float = 0.95
    /// ...and clearly better than every other look-alike on screen. Without this,
    /// a target that scrolled off-screen gets "found" on a similar-looking button.
    static let minimumLeadOverRunnerUpForUnmistakableMatch: Float = 0.04

    private let elementTemplate: GrayscaleTrackingImage
    /// The template is centered on the target when possible, but gets shifted
    /// inward when the target is near a screen edge. This offset (in screenshot
    /// pixels) maps the template's center back to the actual target.
    private let targetOffsetFromTemplateCenterInScreenshotPixels: CGPoint
    private(set) var lastKnownTargetLocationInScreenshotPixels: CGPoint
    /// How far the target moved between the last two frames where it was found.
    /// Scrolling is smooth, so the next frame usually continues the same motion.
    private(set) var lastObservedTargetMovementInScreenshotPixels: CGPoint = .zero

    /// Returns nil if the area around the target is too plain to track (for
    /// example, a blank background), in which case the pointer should stay put.
    init?(referenceFrame: CGImage, targetLocationInScreenshotPixels: CGPoint) {
        let downscaleFactor = Self.downscaleFactor
        guard let downscaledReferenceFrame = GrayscaleTrackingImage(cgImage: referenceFrame, downscaleFactor: downscaleFactor) else {
            return nil
        }

        let templateWidth = Self.templateWidthInDownscaledPixels
        let templateHeight = Self.templateHeightInDownscaledPixels
        guard downscaledReferenceFrame.widthInPixels >= templateWidth,
              downscaledReferenceFrame.heightInPixels >= templateHeight else {
            return nil
        }

        let targetXInDownscaledPixels = Int(targetLocationInScreenshotPixels.x) / downscaleFactor
        let targetYInDownscaledPixels = Int(targetLocationInScreenshotPixels.y) / downscaleFactor
        let templateOriginX = min(max(targetXInDownscaledPixels - templateWidth / 2, 0), downscaledReferenceFrame.widthInPixels - templateWidth)
        let templateOriginY = min(max(targetYInDownscaledPixels - templateHeight / 2, 0), downscaledReferenceFrame.heightInPixels - templateHeight)

        guard let elementTemplate = downscaledReferenceFrame.croppedRegion(
            originX: templateOriginX,
            originY: templateOriginY,
            regionWidth: templateWidth,
            regionHeight: templateHeight
        ) else {
            return nil
        }

        // A template with too little detail can't be found again reliably.
        guard TemplateMatcher.computeSimilarityScoreMap(template: elementTemplate, searchImage: elementTemplate) != nil else {
            return nil
        }

        let templateCenterXInScreenshotPixels = CGFloat((templateOriginX + templateWidth / 2) * downscaleFactor)
        let templateCenterYInScreenshotPixels = CGFloat((templateOriginY + templateHeight / 2) * downscaleFactor)

        self.elementTemplate = elementTemplate
        self.targetOffsetFromTemplateCenterInScreenshotPixels = CGPoint(
            x: targetLocationInScreenshotPixels.x - templateCenterXInScreenshotPixels,
            y: targetLocationInScreenshotPixels.y - templateCenterYInScreenshotPixels
        )
        self.lastKnownTargetLocationInScreenshotPixels = targetLocationInScreenshotPixels
    }

    func locateTarget(in frame: CGImage) -> TrackingResult {
        guard let downscaledFrame = GrayscaleTrackingImage(cgImage: frame, downscaleFactor: Self.downscaleFactor),
              let similarityScoreMap = TemplateMatcher.computeSimilarityScoreMap(template: elementTemplate, searchImage: downscaledFrame),
              let bestMatchAnywhere = similarityScoreMap.bestMatch() else {
            return .notFoundInThisFrame
        }

        let downscaleFactor = CGFloat(Self.downscaleFactor)

        // Where the element should be if it keeps moving like it did last frame.
        let predictedTargetLocation = CGPoint(
            x: lastKnownTargetLocationInScreenshotPixels.x + lastObservedTargetMovementInScreenshotPixels.x,
            y: lastKnownTargetLocationInScreenshotPixels.y + lastObservedTargetMovementInScreenshotPixels.y
        )
        // The template's center (in downscaled pixels) at that predicted location.
        let predictedTemplateCenterX = (predictedTargetLocation.x - targetOffsetFromTemplateCenterInScreenshotPixels.x) / downscaleFactor
        let predictedTemplateCenterY = (predictedTargetLocation.y - targetOffsetFromTemplateCenterInScreenshotPixels.y) / downscaleFactor

        // If the whole template wouldn't fit on screen at the predicted spot, the
        // element is leaving the screen and can't be fully matched anymore. Only
        // an unmistakable match counts then, never a nearby look-alike.
        let halfTemplateWidth = CGFloat(Self.templateWidthInDownscaledPixels / 2)
        let halfTemplateHeight = CGFloat(Self.templateHeightInDownscaledPixels / 2)
        let isPredictedTemplateFullyOnScreen = predictedTemplateCenterX >= halfTemplateWidth
            && predictedTemplateCenterY >= halfTemplateHeight
            && predictedTemplateCenterX < CGFloat(downscaledFrame.widthInPixels) - halfTemplateWidth
            && predictedTemplateCenterY < CGFloat(downscaledFrame.heightInPixels) - halfTemplateHeight

        // A near-perfect match that clearly beats every look-alike is trusted
        // wherever it is. This also re-finds the element after a big jump (page down).
        let runnerUpScore = similarityScoreMap.bestMatch(notOverlapping: bestMatchAnywhere)?.similarityScore
            ?? TemplateSimilarityScoreMap.unscoredPositionScore
        let isBestMatchUnmistakable = bestMatchAnywhere.similarityScore >= Self.minimumSimilarityForUnmistakableMatch
            && bestMatchAnywhere.similarityScore - runnerUpScore >= Self.minimumLeadOverRunnerUpForUnmistakableMatch

        var chosenMatch: TemplateMatchCandidate? = nil

        if isPredictedTemplateFullyOnScreen,
           let nearbyMatch = similarityScoreMap.bestMatchFavoringCloseness(
               toExpectedCenterX: predictedTemplateCenterX,
               expectedCenterY: predictedTemplateCenterY,
               searchRadius: Self.nearbySearchRadiusInScreenshotPixels / downscaleFactor,
               scorePenaltyPerPixelOfDistance: Self.scorePenaltyPerScreenshotPixelFromPrediction * Float(downscaleFactor)
           ),
           nearbyMatch.similarityScore >= Self.minimumSimilarityForNearbyMatch {
            chosenMatch = nearbyMatch
        }

        // Prefer an unmistakable match elsewhere over a weaker nearby one, which
        // is most likely a look-alike (the element jumped, for example on page down).
        if isBestMatchUnmistakable {
            let nearbyMatchScore = chosenMatch?.similarityScore ?? TemplateSimilarityScoreMap.unscoredPositionScore
            if bestMatchAnywhere.similarityScore - nearbyMatchScore >= Self.minimumLeadOverRunnerUpForUnmistakableMatch {
                chosenMatch = bestMatchAnywhere
            }
        }

        guard let chosenMatch else {
            return .notFoundInThisFrame
        }

        let chosenTargetLocation = CGPoint(
            x: CGFloat(chosenMatch.centerX) * downscaleFactor + targetOffsetFromTemplateCenterInScreenshotPixels.x,
            y: CGFloat(chosenMatch.centerY) * downscaleFactor + targetOffsetFromTemplateCenterInScreenshotPixels.y
        )
        lastObservedTargetMovementInScreenshotPixels = CGPoint(
            x: chosenTargetLocation.x - lastKnownTargetLocationInScreenshotPixels.x,
            y: chosenTargetLocation.y - lastKnownTargetLocationInScreenshotPixels.y
        )
        lastKnownTargetLocationInScreenshotPixels = chosenTargetLocation
        return .found(targetLocationInScreenshotPixels: chosenTargetLocation)
    }
}
