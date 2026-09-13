import CoreGraphics
import CSQLite
import Foundation
import RAPPRewindCore
import XCTest

final class FixtureDirectory: @unchecked Sendable {
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let paths: RewindPaths

    init() throws {
        let root = Self.package.appendingPathComponent(".build/test-fixtures/\(UUID().uuidString)", isDirectory: true)
        paths = RewindPaths(root: root)
        try RewindPaths.createPrivateDirectory(root)
    }

    func clean() throws {
        try FileManager.default.removeItem(at: paths.root)
    }

    func sql(_ sql: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(paths.database.path, &pointer) == SQLITE_OK, let pointer else {
            throw RewindError.database("fixture open failed")
        }
        defer { sqlite3_close(pointer) }
        guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else {
            throw RewindError.database(String(cString: sqlite3_errmsg(pointer)))
        }
    }

    func scalar(_ sql: String) throws -> String? {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(paths.database.path, &pointer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let pointer else {
            throw RewindError.database("fixture read failed")
        }
        defer { sqlite3_close(pointer) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RewindError.database(String(cString: sqlite3_errmsg(pointer)))
        }
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) {
            return String(cString: value)
        }
        return nil
    }

    static func frame(
        byte: UInt8 = 50, context: ScreenContext = ScreenContext(app: "Fixture Mail", bundle: "fixture.mail", title: "Ledger")
    ) throws -> CapturedFrame {
        guard let canvas = CGContext(
            data: nil, width: 160, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RewindError.imageEncoding }
        canvas.setFillColor(CGColor(gray: Double(byte) / 255, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        guard let image = canvas.makeImage() else { throw RewindError.imageEncoding }
        var frame = try ImagePipeline.prepare(image, settings: CaptureSettings(), context: context)
        frame.fingerprint = Fingerprint.hex(Array(repeating: byte, count: 32 * 32))
        return frame
    }

    func createCLISchema() throws {
        let source = try String(contentsOf: Self.package.deletingLastPathComponent().appendingPathComponent("rewind"), encoding: .utf8)
        guard let start = source.range(of: "SCHEMA = \"\"\""),
              let end = source[start.upperBound...].range(of: "\"\"\"") else {
            throw RewindError.incompatibleSchema("CLI schema fixture missing")
        }
        try sql(String(source[start.upperBound..<end.lowerBound]))
    }
}

extension XCTestCase {
    func fixture() throws -> FixtureDirectory {
        let fixture = try FixtureDirectory()
        addTeardownBlock { try fixture.clean() }
        return fixture
    }
}

@MainActor
final class FakeScreen: ScreenCapturing {
    var permission: ScreenPermission = .granted
    var requestedPermission: ScreenPermission = .granted
    var requestCount = 0
    var captures = 0
    var cancels = 0
    var responses: [Result<CapturedFrame, Error>] = []
    var holdCapture = false
    var holdPermission = false
    var captureBegan: (() -> Void)?
    var permissionBegan: (() -> Void)?
    private var captureReply: CheckedContinuation<CapturedFrame, Error>?
    private var permissionReply: CheckedContinuation<ScreenPermission, Never>?

    func authorizationStatus() -> ScreenPermission { permission }
    func requestAuthorization() async -> ScreenPermission {
        requestCount += 1
        if holdPermission {
            permission = await withCheckedContinuation {
                permissionReply = $0
                permissionBegan?()
            }
        } else {
            permission = requestedPermission
        }
        return permission
    }
    func capture(settings: CaptureSettings) async throws -> CapturedFrame {
        captures += 1
        if holdCapture {
            return try await withCheckedThrowingContinuation {
                captureReply = $0
                captureBegan?()
            }
        }
        guard !responses.isEmpty else { throw RewindError.captureUnavailable("fixture responses exhausted") }
        return try responses.removeFirst().get()
    }
    func cancel() { cancels += 1 }
    func finishCapture(_ frame: CapturedFrame) {
        captureReply?.resume(returning: frame)
        captureReply = nil
    }
    func finishPermission(_ value: ScreenPermission) {
        permissionReply?.resume(returning: value)
        permissionReply = nil
    }
}

actor FakeRecognizer: TextRecognizing {
    private(set) var calls = 0
    var failure: RewindError?
    var answer = RecognizedText(text: "Quarterly ledger fixture", lines: 1, confidence: 0.99)

    func setFailure(_ failure: RewindError?) { self.failure = failure }
    func recognize(_ image: Data) async throws -> RecognizedText {
        calls += 1
        if let failure { throw failure }
        return answer
    }
}

actor SuspendedRecognizer: TextRecognizing {
    private var reply: CheckedContinuation<RecognizedText, Error>?
    let began: @Sendable () -> Void

    init(began: @escaping @Sendable () -> Void) { self.began = began }

    func recognize(_ image: Data) async throws -> RecognizedText {
        try await withCheckedThrowingContinuation {
            reply = $0
            began()
        }
    }

    func complete() {
        reply?.resume(returning: RecognizedText(text: "Discard this late fixture", lines: 1, confidence: 1))
        reply = nil
    }
}

@MainActor
final class FakeClock: CaptureClock {
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
    func sleep(seconds: TimeInterval) async throws {
        throw RewindError.captureUnavailable("manual clock must not schedule timers")
    }
}

@MainActor
final class StepClock: CaptureClock {
    var now = Date(timeIntervalSince1970: 1_750_000_000)
    var requestedInterval: TimeInterval?
    var sleeping: (() -> Void)?
    var resumed: (() -> Void)?
    private var reply: CheckedContinuation<Void, Error>?

    func sleep(seconds: TimeInterval) async throws {
        requestedInterval = seconds
        try await withCheckedThrowingContinuation {
            reply = $0
            sleeping?()
        }
        resumed?()
    }

    func finishSleep() {
        now = now.addingTimeInterval(requestedInterval ?? 0)
        reply?.resume()
        reply = nil
    }
}
