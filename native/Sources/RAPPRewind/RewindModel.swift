import AppKit
import Combine
import Foundation
import RAPPRewindCore
import ServiceManagement

enum RewindSection: String, CaseIterable, Identifiable {
    case timeline = "Timeline"
    case privacy = "Privacy & Settings"
    case retention = "Image Retention"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .timeline: return "clock.arrow.circlepath"
        case .privacy: return "hand.raised"
        case .retention: return "externaldrive"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor
final class RewindModel: ObservableObject {
    static let shared = RewindModel()

    let paths: RewindPaths
    private(set) var index: RewindIndex?
    private(set) var capture: CaptureCoordinator?
    @Published var settings = CaptureSettings()
    @Published var draft = CaptureSettings()
    @Published var section: RewindSection = .timeline
    @Published var query = ""
    @Published var appFilter = ""
    @Published var since = "1d"
    @Published private(set) var moments: [Moment] = []
    @Published var selectedID: Int64?
    @Published private(set) var selectedMoment: Moment?
    @Published private(set) var selectedImage: NSImage?
    @Published private(set) var statistics: IndexStatistics?
    @Published var errorMessage: String?
    @Published private(set) var startupError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var settingsNotice = ""
    @Published var retentionDays = 30
    @Published private(set) var prunePreview: PrunePreview?
    @Published var confirmPrune = false
    @Published private(set) var retentionNotice = "Image retention is off by default. Indexed text is always kept."
    @Published private(set) var loginStatus = SMAppService.mainApp.status
    @Published private(set) var loginBusy = false
    private var observation: AnyCancellable?
    private var queryGeneration = 0
    private var detailGeneration = 0

    init(paths: RewindPaths = .resolve()) {
        self.paths = paths
        do {
            let settings = try paths.loadSettings()
            self.settings = settings
            self.draft = settings
            let index = try RewindIndex(paths: paths)
            self.index = index
            let capture = try CaptureCoordinator(
                source: ScreenCaptureService(), recognizer: VisionTextRecognizer(),
                index: index, settings: settings, lease: CaptureLease(paths: paths)
            )
            self.capture = capture
            observation = capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        } catch {
            startupError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    var captureState: CaptureState { capture?.state ?? .failed(startupError ?? "Index not initialized") }

    func refresh() async {
        guard let index else { return }
        queryGeneration += 1
        let token = queryGeneration
        isLoading = true
        defer { if queryGeneration == token { isLoading = false } }
        do {
            let cutoff = since.isEmpty ? nil : SinceParser.date(since)
            let rows: [Moment]
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows = try await index.timeline(since: cutoff, limit: 400)
            } else {
                rows = try await index.search(query, app: appFilter, since: cutoff, limit: 400)
            }
            let stats = try await index.statistics()
            guard token == queryGeneration else { return }
            moments = rows
            statistics = stats
            if let selectedID {
                if let updated = rows.first(where: { $0.id == selectedID }) {
                    selectedMoment = updated
                    if updated.relativePath == nil { selectedImage = nil }
                } else {
                    self.selectedID = nil
                    selectedMoment = nil
                    selectedImage = nil
                }
            }
        } catch {
            guard token == queryGeneration else { return }
            moments = []
            selectedID = nil
            selectedMoment = nil
            selectedImage = nil
            errorMessage = error.localizedDescription
        }
    }

    func selectMoment() async {
        detailGeneration += 1
        let token = detailGeneration
        selectedImage = nil
        selectedMoment = nil
        guard let index, let selectedID else { return }
        do {
            let moment = try await index.moment(id: selectedID)
            guard token == detailGeneration else { return }
            selectedMoment = moment
            if moment?.relativePath != nil {
                let url = try await index.imageURL(id: selectedID)
                guard token == detailGeneration else { return }
                guard let image = NSImage(contentsOf: url) else { throw RewindError.imageEncoding }
                selectedImage = image
            }
        } catch {
            guard token == detailGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func openSelectedImage() async {
        guard let index, let selectedID else { return }
        do {
            let url = try await index.imageURL(id: selectedID)
            guard NSWorkspace.shared.open(url) else { throw RewindError.captureUnavailable("no application could open this image") }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveSettings() {
        do {
            let value = try draft.validated()
            try paths.saveSettings(value)
            try capture?.updateSettings(value)
            settings = value
            settingsNotice = "Saved locally. Capture remains paused/stopped until you press Start."
        } catch { errorMessage = error.localizedDescription }
    }

    func previewRetention() async {
        guard let index else { return }
        guard (0...36500).contains(retentionDays) else {
            errorMessage = "Retention days must be between 0 and 36500."
            return
        }
        do {
            let preview = try await index.previewPrune(before: Date().addingTimeInterval(-Double(retentionDays) * 86400))
            prunePreview = preview
            retentionNotice = "Would remove \(preview.images) images (\(Self.bytes(preview.bytes))). All text and moment rows remain."
        } catch { errorMessage = error.localizedDescription }
    }

    func pruneConfirmedImages() async {
        guard let index, let preview = prunePreview else { return }
        prunePreview = nil
        do {
            let result = try await index.pruneImages(before: preview.cutoff)
            retentionNotice = "Removed \(result.images) images (\(Self.bytes(result.bytes))). Text is still searchable."
            await refresh()
            await selectMoment()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleLogin() async {
        guard !loginBusy else { return }
        loginBusy = true
        defer {
            loginStatus = SMAppService.mainApp.status
            loginBusy = false
        }
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try await SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch { errorMessage = "Login item: \(error.localizedDescription)" }
    }

    func refreshSystemStatus() {
        capture?.refreshPermission()
        loginStatus = SMAppService.mainApp.status
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            errorMessage = "Open System Settings → Privacy & Security → Screen Recording manually."
            return
        }
    }

    func handle(_ url: URL) async {
        do {
            switch try NativeRoute.parse(url) {
            case .capture: section = .timeline
            case .search(let text): query = text; since = ""; section = .timeline; await refresh()
            case .timeline: query = ""; section = .timeline; await refresh()
            case .diagnostics: section = .diagnostics
            case .stats: section = .diagnostics; await refresh()
            case .prune(let days): retentionDays = days; section = .retention; await previewRetention()
            case .open(let id): section = .timeline; selectedID = id; await selectMoment()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
