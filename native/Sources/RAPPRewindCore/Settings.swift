import Foundation

public struct PrivacyPolicy: Codable, Equatable, Sendable {
    public var excludedBundleIDs: [String]
    public var excludedTitleFragments: [String]

    public init(excludedBundleIDs: [String] = [], excludedTitleFragments: [String] = []) {
        self.excludedBundleIDs = excludedBundleIDs
        self.excludedTitleFragments = excludedTitleFragments
    }

    public func excludes(_ context: ScreenContext) -> Bool {
        excludedBundleIDs.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && context.bundle.caseInsensitiveCompare($0.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        } || excludedTitleFragments.contains {
            let fragment = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !fragment.isEmpty && context.title.localizedCaseInsensitiveContains(fragment)
        }
    }

    public func skipsSample(frontmost: ScreenContext, visibleWindows: [ScreenContext]) -> Bool {
        excludes(frontmost) || visibleWindows.contains(where: excludes)
    }
}

public struct CaptureSettings: Codable, Equatable, Sendable {
    public var interval: Double = 4
    public var maximumDimension: Int = 1280
    public var jpegQuality: Int = 60
    public var fingerprintGrid: Int = 32
    public var sameMean: Double = 0.5
    public var sameMaximum: Double = 12
    public var maximumConsecutiveErrors: Int = 5
    public var privacy = PrivacyPolicy()
    public var automaticImageRetentionDays: Int?
    public var keepRunningWhenWindowClosed = false

    public init() {}

    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var result = Self()
        func number(_ name: String, _ fallback: Double) throws -> Double {
            guard let raw = environment[name] else { return fallback }
            guard let value = Double(raw), value.isFinite else { throw RewindError.invalidSetting(name) }
            return value
        }
        func integer(_ name: String, _ fallback: Int) throws -> Int {
            guard let raw = environment[name] else { return fallback }
            guard let value = Int(raw) else { throw RewindError.invalidSetting(name) }
            return value
        }
        result.interval = try number("REWIND_INTERVAL", result.interval)
        result.maximumDimension = try integer("REWIND_WIDTH", result.maximumDimension)
        result.jpegQuality = try integer("REWIND_QUALITY", result.jpegQuality)
        result.fingerprintGrid = try integer("REWIND_FP_GRID", result.fingerprintGrid)
        result.sameMean = try number("REWIND_SAME_MEAN", result.sameMean)
        result.sameMaximum = try number("REWIND_SAME_MAX", result.sameMaximum)
        result.maximumConsecutiveErrors = try integer("REWIND_MAX_ERRORS", result.maximumConsecutiveErrors)
        return try result.validated()
    }

    public func validated() throws -> Self {
        guard interval.isFinite, (0.5...3600).contains(interval) else {
            throw RewindError.invalidSetting("capture interval must be 0.5–3600 seconds")
        }
        guard (128...8192).contains(maximumDimension), (0...100).contains(jpegQuality),
              (1...256).contains(fingerprintGrid) else {
            throw RewindError.invalidSetting("image dimension, JPEG quality, or fingerprint grid is out of range")
        }
        guard sameMean.isFinite, sameMaximum.isFinite, (0...255).contains(sameMean),
              (0...255).contains(sameMaximum), (1...100).contains(maximumConsecutiveErrors) else {
            throw RewindError.invalidSetting("deduplication thresholds or failure limit is out of range")
        }
        if let days = automaticImageRetentionDays, !(1...36500).contains(days) {
            throw RewindError.invalidSetting("automatic image retention must be 1–36500 days")
        }
        guard privacy.excludedBundleIDs.count <= 500, privacy.excludedTitleFragments.count <= 500,
              privacy.excludedBundleIDs.allSatisfy({ $0.utf8.count <= 512 }),
              privacy.excludedTitleFragments.allSatisfy({ $0.utf8.count <= 512 }) else {
            throw RewindError.invalidSetting("privacy exclusions are too large")
        }
        return self
    }
}

public struct RewindPaths: Sendable {
    public let root: URL
    public var database: URL { root.appendingPathComponent("index.sqlite3") }
    public var frames: URL { root.appendingPathComponent("frames", isDirectory: true) }
    public var settings: URL { root.appendingPathComponent("native-settings.json") }

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        if let value = environment["REWIND_HOME"], !value.isEmpty {
            return Self(root: URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true))
        }
        return Self(root: home.appendingPathComponent(".rapprewind", isDirectory: true))
    }

    public func loadSettings(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CaptureSettings {
        guard FileManager.default.fileExists(atPath: settings.path) else {
            return try CaptureSettings.defaults(environment: environment)
        }
        return try JSONDecoder().decode(CaptureSettings.self, from: Data(contentsOf: settings)).validated()
    }

    public func saveSettings(_ value: CaptureSettings) throws {
        let checked = try value.validated()
        try Self.createPrivateDirectory(root)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(checked).write(to: settings, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
    }

    public static func createPrivateDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    public func safeFrameURL(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            throw RewindError.unsafePath
        }
        let base = frames.resolvingSymlinksInPath().standardizedFileURL
        let result = base.appendingPathComponent(relativePath).standardizedFileURL
        guard result.path.hasPrefix(base.path + "/"),
              result.resolvingSymlinksInPath().standardizedFileURL == result,
              ["jpg", "jpeg", "png"].contains(result.pathExtension.lowercased()) else {
            throw RewindError.unsafePath
        }
        if FileManager.default.fileExists(atPath: result.path) {
            let values = try result.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw RewindError.unsafePath }
        }
        return result
    }
}

public enum SinceParser {
    public static func date(_ input: String, now: Date = Date()) -> Date {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86400, "w": 604800]
        if let suffix = input.last, let multiplier = units[suffix] {
            let number = String(input.dropLast())
            if !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
               let value = Double(number), value.isFinite {
                return now.addingTimeInterval(-value * multiplier)
            }
        }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: input.uppercased()) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: input.uppercased()) { return date }
        }
        // The compatibility CLI deliberately treats an invalid --since as epoch.
        return Date(timeIntervalSince1970: 0)
    }
}
