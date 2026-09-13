import Foundation

public enum RewindError: LocalizedError, Equatable {
    case database(String)
    case legacyContentlessIndex
    case incompatibleSchema(String)
    case invalidSetting(String)
    case invalidAction(String)
    case permissionDenied
    case captureUnavailable(String)
    case imageEncoding
    case excluded
    case unsafePath
    case missingImage
    case alreadyCapturing

    public var errorDescription: String? {
        switch self {
        case .database(let detail): return "SQLite: \(detail)"
        case .legacyContentlessIndex:
            return "This early index has a contentless FTS table. It was not changed. Back it up before using the compatibility CLI's rebuild/re-OCR migration, then reopen it in Rewind."
        case .incompatibleSchema(let detail): return "Unrecognized index schema; no migration was performed. \(detail)"
        case .invalidSetting(let detail): return "Invalid setting: \(detail)"
        case .invalidAction(let detail): return "Invalid action: \(detail)"
        case .permissionDenied:
            return "Screen Recording is not granted to RAPP Rewind. Enable this app in System Settings → Privacy & Security → Screen Recording, then quit and reopen it if macOS requests it. A Terminal or Python grant is not inherited."
        case .captureUnavailable(let detail): return "Screen capture unavailable: \(detail)"
        case .imageEncoding: return "The captured image could not be encoded. Nothing was indexed."
        case .excluded: return "Capture skipped by a privacy exclusion."
        case .unsafePath: return "The frame path is outside this index's frames directory or is not a regular file."
        case .missingImage: return "No image for this moment. It was pruned, removed, or the frame does not exist. Indexed text is retained."
        case .alreadyCapturing:
            return "Another Rewind capture process is using this index. Stop that process explicitly before starting native capture."
        }
    }
}

public struct ScreenContext: Equatable, Sendable {
    public var app: String
    public var bundle: String
    public var title: String

    public init(app: String = "", bundle: String = "", title: String = "") {
        self.app = app
        self.bundle = bundle
        self.title = title
    }
}

public struct CapturedFrame: Sendable {
    public var jpeg: Data
    public var fingerprint: String?
    public var context: ScreenContext

    public init(jpeg: Data, fingerprint: String?, context: ScreenContext) {
        self.jpeg = jpeg
        self.fingerprint = fingerprint
        self.context = context
    }
}

public struct RecognizedText: Equatable, Sendable {
    public var text: String
    public var lines: Int
    public var confidence: Double

    public init(text: String, lines: Int, confidence: Double) {
        self.text = text
        self.lines = lines
        self.confidence = confidence
    }
}

public struct Moment: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let until: Date
    public let app: String
    public let bundle: String
    public let title: String
    public let relativePath: String?
    public let bytes: Int64
    public let text: String
    public let snippet: String
    public let lines: Int
    public let confidence: Double
}

public struct IndexStatistics: Equatable, Sendable {
    public let frames: Int64
    public let bytes: Int64
    public let newShots: Int64
    public let sameShots: Int64
    public let first: Date?
    public let last: Date?
    public let heldSeconds: Double

    public var shots: Int64 { newShots + sameShots }
    public var deduplicationRate: Double { shots > 0 ? Double(sameShots) / Double(shots) : 0 }

    public func projectedBytesPerDay(interval: TimeInterval) -> Double? {
        let active = Double(shots) * interval
        return active > 60 ? Double(bytes) / active * 86_400 : nil
    }
}

public struct PrunePreview: Equatable, Sendable {
    public let cutoff: Date
    public let images: Int
    public let bytes: Int64
}

public enum ScreenPermission: String, Sendable {
    case notDetermined
    case denied
    case granted
}

public enum CaptureState: Equatable, Sendable {
    case stopped
    case requestingPermission
    case capturing
    case paused
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: return "Stopped — not recording"
        case .requestingPermission: return "Waiting for Screen Recording permission"
        case .capturing: return "Recording this display"
        case .paused: return "Paused — not recording"
        case .failed: return "Stopped after an error"
        }
    }

    public var isCapturing: Bool { self == .capturing }
}

public struct DiagnosticEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.id = UUID()
        self.date = date
        self.message = message
    }
}
