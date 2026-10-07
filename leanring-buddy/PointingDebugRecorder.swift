//
//  PointingDebugRecorder.swift
//  leanring-buddy
//
//  Debug builds only: every time Clicky points at something, saves the exact
//  screenshot Claude saw with Claude's point marked in red, plus the question,
//  answer, and coordinates. Used to tell whether a bad point came from Claude's
//  coordinates or from what the app did with them afterwards (coordinate
//  mapping, live session tracking).
//
//  Files go to `.pointing-debug/` at the repo root (git-ignored). They contain
//  screenshots of the user's screen, so delete the folder after debugging.
//

import AppKit
import Foundation

#if DEBUG
enum PointingDebugRecorder {
    /// The repo root, derived from this source file's location at compile
    /// time, so debug files land next to the code instead of somewhere hidden.
    private static let pointingDebugFolderURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".pointing-debug", isDirectory: true)

    static func recordPointing(
        screenshotImageData: Data,
        screenshotLabel: String,
        pointInScreenshotPixels: CGPoint,
        elementLabel: String?,
        userTranscript: String,
        claudeResponseText: String,
        isLiveSessionActive: Bool
    ) {
        do {
            try FileManager.default.createDirectory(at: pointingDebugFolderURL, withIntermediateDirectories: true)

            let timestampFormatter = DateFormatter()
            timestampFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let fileNameStem = "\(timestampFormatter.string(from: Date()))_\(sanitizedFileNameComponent(elementLabel ?? "element"))"

            if let markedImageData = imageWithPointMarked(
                screenshotImageData: screenshotImageData,
                pointInScreenshotPixels: pointInScreenshotPixels
            ) {
                try markedImageData.write(to: pointingDebugFolderURL.appendingPathComponent("\(fileNameStem).jpg"))
            }

            let logEntry: [String: Any] = [
                "file": "\(fileNameStem).jpg",
                "elementLabel": elementLabel ?? "",
                "pointX": Int(pointInScreenshotPixels.x),
                "pointY": Int(pointInScreenshotPixels.y),
                "screenshotLabel": screenshotLabel,
                "userTranscript": userTranscript,
                "claudeResponse": claudeResponseText,
                "isLiveSession": isLiveSessionActive
            ]
            let logLineData = try JSONSerialization.data(withJSONObject: logEntry, options: [.sortedKeys])
            let logFileURL = pointingDebugFolderURL.appendingPathComponent("log.jsonl")
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            let logFileHandle = try FileHandle(forWritingTo: logFileURL)
            logFileHandle.seekToEndOfFile()
            logFileHandle.write(logLineData + Data("\n".utf8))
            try logFileHandle.close()

            print("🐞 Pointing debug: saved \(fileNameStem).jpg")
        } catch {
            print("⚠️ Pointing debug: couldn't save: \(error)")
        }
    }

    /// Draws a red ring and crosshair where Claude pointed, at the image's
    /// exact pixel size (no Retina scaling, so pixels match Claude's coordinates).
    private static func imageWithPointMarked(screenshotImageData: Data, pointInScreenshotPixels: CGPoint) -> Data? {
        guard let originalBitmap = NSBitmapImageRep(data: screenshotImageData),
              let originalCGImage = originalBitmap.cgImage else {
            return nil
        }

        let widthInPixels = originalCGImage.width
        let heightInPixels = originalCGImage.height
        guard let drawingContext = CGContext(
            data: nil,
            width: widthInPixels,
            height: heightInPixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        drawingContext.draw(originalCGImage, in: CGRect(x: 0, y: 0, width: widthInPixels, height: heightInPixels))

        // Screenshot coordinates have a top-left origin; CoreGraphics is bottom-left
        let markerCenter = CGPoint(x: pointInScreenshotPixels.x, y: CGFloat(heightInPixels) - pointInScreenshotPixels.y)
        drawingContext.setStrokeColor(NSColor.systemRed.cgColor)
        drawingContext.setLineWidth(2)
        drawingContext.strokeEllipse(in: CGRect(x: markerCenter.x - 12, y: markerCenter.y - 12, width: 24, height: 24))
        drawingContext.move(to: CGPoint(x: markerCenter.x - 20, y: markerCenter.y))
        drawingContext.addLine(to: CGPoint(x: markerCenter.x + 20, y: markerCenter.y))
        drawingContext.move(to: CGPoint(x: markerCenter.x, y: markerCenter.y - 20))
        drawingContext.addLine(to: CGPoint(x: markerCenter.x, y: markerCenter.y + 20))
        drawingContext.strokePath()

        guard let markedCGImage = drawingContext.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: markedCGImage).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func sanitizedFileNameComponent(_ text: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics
        return String(text.lowercased().unicodeScalars.map { allowedCharacters.contains($0) ? Character($0) : "-" }.prefix(40))
    }
}
#endif
