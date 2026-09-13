import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public enum ImagePipeline {
    public static func prepare(_ image: CGImage, settings: CaptureSettings, context: ScreenContext) throws -> CapturedFrame {
        let settings = try settings.validated()
        let ratio = min(1, Double(settings.maximumDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let canvas = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RewindError.imageEncoding }
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = canvas.makeImage() else { throw RewindError.imageEncoding }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RewindError.imageEncoding
        }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImageDestinationLossyCompressionQuality: Double(settings.jpegQuality) / 100
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let jpegImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RewindError.imageEncoding
        }
        let grid = settings.fingerprintGrid
        var pixels = [UInt8](repeating: 0, count: grid * grid)
        let fingerprint: String? = pixels.withUnsafeMutableBytes { bytes in
            guard let thumb = CGContext(
                data: bytes.baseAddress, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return nil }
            thumb.interpolationQuality = .high
            thumb.draw(jpegImage, in: CGRect(x: 0, y: 0, width: grid, height: grid))
            return Fingerprint.hex(Array(bytes))
        }
        return CapturedFrame(jpeg: data as Data, fingerprint: fingerprint, context: context)
    }
}

public protocol TextRecognizing: Sendable {
    func recognize(_ image: Data) async throws -> RecognizedText
}

public actor VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(_ image: Data) async throws -> RecognizedText {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RewindError.imageEncoding
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            try Task.checkCancellation()
            let observations = request.results ?? []
            var lines: [String] = []
            var confidence: Float = 0
            for observation in observations {
                if let candidate = observation.topCandidates(1).first {
                    lines.append(candidate.string)
                    confidence += candidate.confidence
                }
            }
            return RecognizedText(
                text: lines.joined(separator: "\n"), lines: lines.count,
                confidence: observations.isEmpty ? 0 : Double(confidence / Float(observations.count))
            )
        } onCancel: {
            request.cancel()
        }
    }
}
