import Foundation
import CoreText
import ImageIO
import RAPPRewindCore
import XCTest

final class FingerprintPrivacyTests: XCTestCase {
    func testDualThresholdsKeepNoiseButCatchSmallWindows() {
        let baseline = [UInt8](repeating: 100, count: 1024)
        var noise = baseline
        for i in 0..<10 { noise[i] += 2 }
        XCTAssertTrue(Fingerprint.isSame(Fingerprint.hex(baseline), Fingerprint.hex(noise)))
        var smallWindow = baseline
        smallWindow[500] += 32
        XCTAssertFalse(Fingerprint.isSame(Fingerprint.hex(baseline), Fingerprint.hex(smallWindow)))
        let globalChange = baseline.map { $0 + 1 }
        XCTAssertFalse(Fingerprint.isSame(Fingerprint.hex(baseline), Fingerprint.hex(globalChange)))
        let delta = Fingerprint.delta(Fingerprint.hex(baseline), Fingerprint.hex(noise))
        XCTAssertEqual(delta.mean, 20.0 / 1024)
        XCTAssertEqual(delta.maximum, 2)
    }

    func testThresholdEqualityIsAChangeAndMalformedFingerprintsNeverDedup() {
        XCTAssertFalse(Fingerprint.isSame("0000", "0100", mean: 0.5))
        XCTAssertFalse(Fingerprint.isSame("00000000", "0c000000", mean: 10, maximum: 12))
        for (a, b): (String?, String?) in [(nil, "00"), ("", ""), ("00", "0000"), ("0", "0"), ("zz", "zz")] {
            XCTAssertFalse(Fingerprint.isSame(a, b))
            XCTAssertEqual(Fingerprint.delta(a, b).mean, 999)
        }
        XCTAssertTrue(Fingerprint.isSame("aaff", "AAFF"))
    }

    func testVisibleExcludedBackgroundWindowSkipsEntireSample() {
        let policy = PrivacyPolicy(excludedBundleIDs: ["  fixture.secret  "], excludedTitleFragments: ["Private", ""])
        let ordinary = ScreenContext(app: "Mail", bundle: "fixture.mail", title: "Inbox")
        let secret = ScreenContext(app: "Secret", bundle: "FIXTURE.SECRET", title: "Vault")
        XCTAssertTrue(policy.skipsSample(frontmost: ordinary, visibleWindows: [ordinary, secret]))
        XCTAssertTrue(policy.skipsSample(frontmost: secret, visibleWindows: []))
        XCTAssertTrue(policy.excludes(ScreenContext(title: "A PRIVATE document")))
        XCTAssertFalse(policy.excludes(ordinary))
        XCTAssertFalse(PrivacyPolicy().skipsSample(frontmost: ordinary, visibleWindows: [secret]))
        XCTAssertFalse(PrivacyPolicy(excludedBundleIDs: ["fixture"]).excludes(secret))
    }

    func testImagePipelineProducesLocalJPEGAndCorrectGrid() throws {
        let frame = try FixtureDirectory.frame()
        XCTAssertEqual(frame.jpeg.prefix(2), Data([0xff, 0xd8]))
        XCTAssertEqual(frame.fingerprint?.count, 32 * 32 * 2)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 90)
        let prepared = try ImagePipeline.prepare(image, settings: CaptureSettings(), context: ScreenContext())
        XCTAssertEqual(prepared.fingerprint?.count, 2048)
    }

    func testVisionUsesGeneratedBlankFixtureAndRejectsUnreadableImage() async throws {
        let image = try FixtureDirectory.frame()
        let recognizer = VisionTextRecognizer()
        let answer = try await recognizer.recognize(image.jpeg)
        XCTAssertGreaterThanOrEqual(answer.lines, 0)
        XCTAssertTrue((0...1).contains(answer.confidence))
        do {
            _ = try await recognizer.recognize(Data("not an image".utf8))
            XCTFail("invalid image was silently turned into empty OCR")
        } catch RewindError.imageEncoding {}
    }

    func testVisionReadsHighContrastGeneratedTextThroughNativeJPEGPath() async throws {
        let canvas = try XCTUnwrap(CGContext(
            data: nil, width: 900, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
        canvas.textPosition = CGPoint(x: 40, y: 100)
        let text = NSAttributedString(string: "REWIND FIXTURE LEDGER 4821", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 44, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), canvas)
        let image = try XCTUnwrap(canvas.makeImage())
        let prepared = try ImagePipeline.prepare(image, settings: CaptureSettings(), context: ScreenContext(app: "Generated fixture"))
        let recognized = try await VisionTextRecognizer().recognize(prepared.jpeg)
        XCTAssertTrue(recognized.text.uppercased().contains("LEDGER"), recognized.text)
        XCTAssertGreaterThan(recognized.lines, 0)
    }
}
