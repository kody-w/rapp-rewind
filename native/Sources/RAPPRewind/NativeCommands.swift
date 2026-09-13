import AppKit
import CoreGraphics
import CoreText
import Foundation
import RAPPDesktopSupport
import RAPPRewindCore

@MainActor
enum NativeCommands {
    static func selfTest() async -> Int32 {
        do {
            try RewindIndex.verifyFTS5()
            let bundled = Bundle.main.bundleURL.pathExtension == "app"
            if bundled {
                guard Bundle.main.bundleIdentifier == "io.rapp.rewind",
                      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.2.1",
                      Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "14.0",
                      let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
                      types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains("rapp-rewind") == true }) else {
                    throw RewindError.invalidSetting("the application bundle has incorrect identity, version, deployment target, or URL registration metadata")
                }
            }
            #if SWIFT_PACKAGE
            let resource = Bundle.module.url(forResource: "LocalPrivacy", withExtension: "txt")
            #else
            let resource = Bundle.main.url(forResource: "LocalPrivacy", withExtension: "txt")
            #endif
            guard resource != nil else { throw RewindError.invalidSetting("the native privacy resource is missing from this build") }
            let output: [String: Any] = [
                "product": "RAPPRewind", "version": "1.2.1", "minimumMacOS": "14.0",
                "sqliteVersion": RewindIndex.sqliteVersion, "fts5": true,
                "captureStarted": false, "permissionRequested": false,
                "historyOpened": false, "sharedSupportLinked": true,
                "bundleMetadataVerified": bundled, "resourcesPresent": true,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled"
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return 0
        } catch { return report(error) }
    }

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let command = try NativeCommand.parse(arguments)
            let paths = RewindPaths.resolve()
            switch command.action {
            case .doctor:
                try RewindIndex.verifyFTS5()
                print("""
                    RAPP Rewind native 1.2.1 — local-only diagnostic
                      bundle: \(Bundle.main.bundleIdentifier ?? "unbundled (capture requires the installed .app)")
                      SQLite \(RewindIndex.sqliteVersion): FTS5 verified in memory
                      Screen Recording: \(ScreenCaptureService().authorizationStatus().rawValue)
                      history: \(paths.database.path)
                      ScreenCaptureKit / Vision: compiled native engines
                    No screenshot, permission prompt, history read, or network request was made.
                    """)
                return 0
            case .capture:
                // A bridge may reveal controls, never supply screen-recording consent.
                guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier == "io.rapp.rewind" else {
                    throw RewindError.invalidAction("open the installed RAPP Rewind.app and press Start; an unbundled executable cannot request capture")
                }
                _ = try await ProcessRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/open"),
                    arguments: ["-a", Bundle.main.bundleURL.path, "rapp-rewind://capture"]
                )
                print("Opened RAPP Rewind capture controls. No screenshot was taken. Press Start in the app to opt in.")
                return 0
            case .bench:
                return try await syntheticBenchmark()
            default: break
            }
            let index = try RewindIndex(paths: paths)
            switch command.action {
            case .search:
                let since = command.since.map { SinceParser.date($0) }
                let rows = try await index.search(command.query, app: command.app, since: since, limit: command.limit)
                if rows.isEmpty { print("no matches"); return 1 }
                printMoments(rows, snippets: true)
                print("\n\(rows.count) match(es)")
            case .timeline:
                let rows = try await index.timeline(since: command.since.map { SinceParser.date($0) }, limit: command.limit)
                printMoments(rows, snippets: false)
                print("\n\(rows.count) moment(s), newest first. Open RAPP Rewind for the native visual timeline.")
            case .stats:
                let stats = try await index.statistics()
                let settings = try paths.loadSettings()
                print("""
                    RAPP Rewind index
                      frames stored: \(stats.frames)
                      image bytes: \(stats.bytes)
                      shots taken: \(stats.shots) (\(stats.newShots) stored, \(stats.sameShots) deduped)
                      dedup rate: \(Int(stats.deduplicationRate * 100))% of shots
                      capture time: \(Double(stats.shots) * settings.interval) seconds at \(settings.interval)s intervals
                    """)
                if let projected = stats.projectedBytesPerDay(interval: settings.interval) {
                    print("  projected bytes per 24h of active capture: \(Int64(projected))")
                }
            case .prune:
                let result = try await index.previewPrune(before: Date().addingTimeInterval(-Double(command.days) * 86400))
                print("Would drop \(result.images) images (\(result.bytes) bytes) older than \(command.days) days.")
                print("DRY RUN. Nothing was deleted. Text is always retained. Confirm image removal yourself in RAPP Rewind → Image Retention.")
            case .open:
                guard let id = command.frameID else { throw RewindError.invalidAction("missing frame ID") }
                let imageURL = try await index.imageURL(id: id)
                guard NSImage(contentsOf: imageURL) != nil else { throw RewindError.imageEncoding }
                _ = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: [imageURL.path])
                print(imageURL.path)
            default: break
            }
            return 0
        } catch { return report(error) }
    }

    private static func printMoments(_ moments: [Moment], snippets: Bool) {
        for moment in moments {
            print("\n#\(moment.id)  \(moment.timestamp.formatted()) (+\(Int(moment.until.timeIntervalSince(moment.timestamp)))s)  \(moment.app) — \(moment.title)")
            let text = snippets ? moment.snippet : String(moment.text.prefix(4000))
            print("    \(text.replacingOccurrences(of: "\n", with: " "))")
            if moment.relativePath == nil { print("    Image pruned — indexed text kept.") }
        }
    }

    private static func syntheticBenchmark() async throws -> Int32 {
        guard let canvas = CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RewindError.imageEncoding }
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        canvas.textPosition = CGPoint(x: 90, y: 650)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "RAPP Rewind local synthetic benchmark",
            attributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: NSColor.black]
        ))
        CTLineDraw(line, canvas)
        guard let image = canvas.makeImage() else { throw RewindError.imageEncoding }
        let started = Date()
        let frame = try ImagePipeline.prepare(image, settings: CaptureSettings(), context: ScreenContext(app: "Fixture"))
        let prepared = Date()
        let recognized = try await VisionTextRecognizer().recognize(frame.jpeg)
        let result: [String: Any] = [
            "fixture": "generated text on a white image — NOT a live screen benchmark",
            "capturePerformed": false, "indexOpened": false,
            "scaleFingerprintMilliseconds": prepared.timeIntervalSince(started) * 1000,
            "ocrMilliseconds": Date().timeIntervalSince(prepared) * 1000,
            "jpegBytes": frame.jpeg.count, "ocrLines": recognized.lines,
            "ocrConfidence": recognized.confidence
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
        return 0
    }

    private static func report(_ error: Error) -> Int32 {
        FileHandle.standardError.write(Data("RAPP Rewind: \(error.localizedDescription)\n".utf8))
        return 2
    }
}
