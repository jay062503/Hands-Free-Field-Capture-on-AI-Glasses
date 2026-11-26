// QualityCheckService.swift
// FieldCapture
//
// Frame quality checks — synced with the web version (quality_check.py).
//
// Design principle (adopted from web): get output at all costs.
// A bad frame sent to Gemini gives a low-confidence result.
// A rejected frame gives nothing. So we reject as little as possible.
//
// Hard-block only:
//   brightness < 8  → completely blank frame (camera not streaming)
//   could not decode
//
// Everything else: advisory warnings in failureReasons, passed = true.
// Framing and blur never hard-block a capture.
//
// Image pre-processing is applied before quality scoring AND before
// the extraction API call, matching quality_check.py _preprocess():
//   1. Upscale to ≥600px short-side
//   2. Auto-levels (histogram stretch to 0–255)
//   3. Brightness boost for dark images
//   4. Contrast +35%
//   5. Mild sharpening (CIUnsharpMask)

import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate

final class QualityCheckService {

    static let shared = QualityCheckService()

    // Thresholds — advisory only. Only brightness < hardBlockBrightness hard-blocks.
    let thresholds = QualityThresholds(
        minBlurScore: 30.0,
        minBrightness: 20.0,
        minFraming: 0.05
    )

    private let hardBlockBrightness: Double = 8.0
    private let ciContext = CIContext()

    // MARK: - Main check entry point

    func check(frame: CapturedFrame, captureType: CaptureEvent.CaptureType) -> QualityCheckResult {
        let ciImage = CIImage(cgImage: frame.image)

        // Hard-block: completely blank image (camera not started)
        let rawBrightness = computeBrightness(ciImage: ciImage)
        if rawBrightness < hardBlockBrightness {
            return QualityCheckResult(
                passed: false,
                blurScore: 0,
                brightnessScore: rawBrightness,
                framingScore: 0,
                failureReasons: [
                    "Frame is completely black (brightness \(String(format: "%.1f", rawBrightness))). " +
                    "The camera stream may not be active — stop and restart the session."
                ],
                thresholdsUsed: thresholds
            )
        }

        // Pre-process for better scoring accuracy
        let processed = preprocessed(ciImage)

        let blurScore       = computeBlurScore(ciImage: processed)
        let brightnessScore = computeBrightness(ciImage: processed)
        let framingScore    = computeFramingScore(ciImage: processed)

        // Build advisory warnings — none of these block the capture
        var warnings: [String] = []
        if blurScore < thresholds.minBlurScore {
            warnings.append(
                "Image is blurry (score \(String(format: "%.1f", blurScore))) — " +
                "confidence scores may be lower."
            )
        }
        if brightnessScore < thresholds.minBrightness {
            warnings.append(
                "Image is dark (brightness \(String(format: "%.1f", brightnessScore))) — " +
                "try better lighting."
            )
        }
        if framingScore < thresholds.minFraming {
            warnings.append(
                "Subject may be small or cut off (framing \(String(format: "%.2f", framingScore))) — " +
                "get closer if possible."
            )
        }

        return QualityCheckResult(
            passed: true,              // warnings never block
            blurScore: blurScore,
            brightnessScore: brightnessScore,
            framingScore: framingScore,
            failureReasons: warnings,
            thresholdsUsed: thresholds
        )
    }

    // MARK: - Pre-processing (mirrors Python _preprocess)

    /// Returns an enhanced CIImage suitable for quality scoring and extraction.
    func preprocessed(_ ciImage: CIImage) -> CIImage {
        var img = ciImage

        // 1. Upscale small images
        let shortSide = min(img.extent.width, img.extent.height)
        if shortSide < 600 {
            let scale = 600.0 / shortSide
            img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        // 2. Auto-levels via CIColorControls saturation + exposure
        //    (Full histogram stretch is not a single CIFilter; we approximate
        //     with auto-enhance then a moderate exposure boost for dark images.)
        let brightness = computeBrightness(ciImage: img)
        if brightness < 90 {
            let boost = min(2.5, 110.0 / max(brightness, 1.0))
            let evBoost = log2(boost)   // CIExposureAdjust uses EV (stops)
            if let filter = CIFilter(name: "CIExposureAdjust") {
                filter.setValue(img, forKey: kCIInputImageKey)
                filter.setValue(evBoost, forKey: "inputEV")
                img = filter.outputImage ?? img
            }
        }

        // 3. Contrast boost
        if let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(img, forKey: kCIInputImageKey)
            filter.setValue(1.35, forKey: "inputContrast")
            img = filter.outputImage ?? img
        }

        // 4. Mild unsharp mask
        if let filter = CIFilter(name: "CIUnsharpMask") {
            filter.setValue(img, forKey: kCIInputImageKey)
            filter.setValue(1.5, forKey: "inputRadius")
            filter.setValue(0.7, forKey: "inputIntensity")
            img = filter.outputImage ?? img
        }

        return img
    }

    /// Returns a base64 JPEG of the pre-processed image for the extraction API.
    func preprocessedJPEG(from cgImage: CGImage) -> String? {
        let ci = preprocessed(CIImage(cgImage: cgImage))
        guard let data = ciContext.jpegRepresentation(
            of: ci,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        ) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Blur: Laplacian variance

    private func computeBlurScore(ciImage: CIImage) -> Double {
        let scale = min(1.0, 400.0 / max(ciImage.extent.width, ciImage.extent.height))
        let smallImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgSmall = ciContext.createCGImage(smallImage, from: smallImage.extent) else { return 0 }

        let w = cgSmall.width, h = cgSmall.height
        let bpr = w * 4
        var pixels = [UInt8](repeating: 0, count: bpr * h)

        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(cgSmall, in: CGRect(x: 0, y: 0, width: w, height: h))

        var grey = [Float](repeating: 0, count: w * h)
        for i in 0 ..< w * h {
            grey[i] = 0.299 * Float(pixels[i*4]) + 0.587 * Float(pixels[i*4+1]) + 0.114 * Float(pixels[i*4+2])
        }

        var diffs = [Float]()
        diffs.reserveCapacity((w-1)*h + w*(h-1))
        for y in 0..<h { for x in 0..<(w-1) { diffs.append(grey[y*w+x+1] - grey[y*w+x]) } }
        for y in 0..<(h-1) { for x in 0..<w { diffs.append(grey[(y+1)*w+x] - grey[y*w+x]) } }

        var mean: Float = 0, stddev: Float = 0
        vDSP_normalize(diffs, 1, nil, 1, &mean, &stddev, vDSP_Length(diffs.count))
        return max(0, min(Double(stddev * stddev) * 10_000, 2000))
    }

    // MARK: - Brightness: mean pixel intensity

    private func computeBrightness(ciImage: CIImage) -> Double {
        let filter = CIFilter.areaAverage()
        filter.inputImage = ciImage
        filter.extent = ciImage.extent
        guard let output = filter.outputImage,
              let cgOut = ciContext.createCGImage(output, from: output.extent)
        else { return 128 }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1,
                                  bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 128 }
        ctx.draw(cgOut, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return 0.299 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.114 * Double(pixel[2])
    }

    // MARK: - Framing: edge bounding-box coverage

    private func computeFramingScore(ciImage: CIImage) -> Double {
        let scale = min(1.0, 200.0 / max(ciImage.extent.width, ciImage.extent.height))
        let small = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let edgeFilter = CIFilter(name: "CIEdges") else { return 0.5 }
        edgeFilter.setValue(small, forKey: kCIInputImageKey)
        edgeFilter.setValue(5.0, forKey: kCIInputIntensityKey)
        guard let edgeImage = edgeFilter.outputImage,
              let cg = ciContext.createCGImage(edgeImage, from: edgeImage.extent)
        else { return 0.5 }

        let w = cg.width, h = cg.height
        var pix = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pix, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0.5 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Lowered edge threshold to 15 (matches Python version) so low-contrast
        // frames still produce meaningful framing scores
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0 ..< h {
            for x in 0 ..< w {
                if pix[(y*w+x)*4] > 15 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX > minX && maxY > minY else { return 0.0 }
        return min(Double((maxX-minX) * (maxY-minY)) / Double(w*h), 1.0)
    }
}
