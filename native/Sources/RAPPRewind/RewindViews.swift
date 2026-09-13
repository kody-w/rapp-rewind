import AppKit
import RAPPRewindCore
import ServiceManagement
import SwiftUI

struct RewindWindow: View {
    @ObservedObject var model: RewindModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            CaptureControls(model: model)
            Divider()
            NavigationSplitView {
                List(RewindSection.allCases, selection: $model.section) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityIdentifier("rewind.navigation.\(section.id)")
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 205)
            } detail: {
                switch model.section {
                case .timeline: TimelineView(model: model)
                case .privacy: RewindSettingsView(model: model)
                case .retention: RetentionView(model: model)
                case .diagnostics: DiagnosticsView(model: model)
                }
            }
            Divider()
            HStack {
                Label("On this Mac only • No audio • Main display", systemImage: "lock.shield")
                Spacer()
                Text("RAPP Rewind 1.2.0")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(minWidth: 940, minHeight: 620)
        .onOpenURL { url in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.handle(url) }
        }
        .task { await model.refresh() }
        .onChange(of: model.capture?.completedSamples) { _, _ in Task { await model.refresh() } }
        .onChange(of: model.selectedID) { _, _ in Task { await model.selectMoment() } }
        .alert("Rewind needs your attention", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct CaptureControls: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: model.captureState.isCapturing ? "record.circle.fill" : "pause.circle")
                    .font(.title2)
                    .foregroundStyle(model.captureState.isCapturing ? Color.red : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.captureState.label).font(.headline)
                        .accessibilityIdentifier("rewind.capture.state")
                    Text(model.capture?.lastOutcome ?? model.startupError ?? "Not initialized")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("rewind.capture.outcome")
                }
                Spacer()
                Button(model.captureState == .paused ? "Resume" : "Start") {
                    Task { await model.capture?.start() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.capture == nil || model.captureState == .capturing || model.captureState == .requestingPermission)
                .accessibilityIdentifier("rewind.capture.start")
                Button("Pause") { model.capture?.pause() }
                    .disabled(model.captureState != .capturing && model.captureState != .requestingPermission)
                    .accessibilityIdentifier("rewind.capture.pause")
                Button("Stop") { model.capture?.stop() }
                    .disabled(model.capture == nil || model.captureState == .stopped)
                    .accessibilityIdentifier("rewind.capture.stop")
            }
            Text("Start opts in to screen capture and on-device OCR. Text and images may contain sensitive information. Recording never starts at launch.")
                .font(.caption)
        }
        .padding(16)
        .background(model.captureState.isCapturing ? Color.red.opacity(0.07) : Color.accentColor.opacity(0.04))
    }
}

private struct TimelineView: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Search text, \"exact phrase\", prefix*, AND / OR / NOT", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.refresh() } }
                        .accessibilityIdentifier("rewind.search.query")
                    Button("Search") { Task { await model.refresh() } }
                        .accessibilityIdentifier("rewind.search.submit")
                    if model.isLoading { ProgressView().controlSize(.small) }
                }
                HStack {
                    TextField("App contains", text: $model.appFilter)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.query.isEmpty)
                        .accessibilityIdentifier("rewind.search.app")
                    TextField("Since: 1d, 2h, ISO date, or empty for all", text: $model.since)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.refresh() } }
                        .accessibilityIdentifier("rewind.search.since")
                    Button("Timeline") {
                        model.query = ""
                        Task { await model.refresh() }
                    }
                    .accessibilityIdentifier("rewind.timeline.refresh")
                }
                Text("\(model.moments.count) moments shown • newest first • at most 400 per query")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            HSplitView {
                List(model.moments, selection: $model.selectedID) { moment in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(moment.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                            Spacer()
                            if moment.relativePath == nil { Image(systemName: "text.page").help("Image pruned; text kept") }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text(moment.app.isEmpty ? "Unknown app" : moment.app).font(.headline)
                        if !moment.title.isEmpty { Text(moment.title).font(.caption).lineLimit(1) }
                        if !moment.snippet.isEmpty { Text(moment.snippet).font(.caption).lineLimit(3) }
                    }
                    .padding(.vertical, 4)
                    .tag(moment.id)
                    .accessibilityIdentifier("rewind.moment.\(moment.id)")
                }
                .frame(minWidth: 230, idealWidth: 280)
                .accessibilityIdentifier("rewind.timeline.results")
                ScrollView {
                    if let moment = model.selectedMoment {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text("Moment #\(moment.id)").font(.title2.bold())
                                Spacer()
                                Button("Open Image") { Task { await model.openSelectedImage() } }
                                    .disabled(moment.relativePath == nil)
                                    .accessibilityIdentifier("rewind.moment.open")
                            }
                            Text("\(moment.app) — \(moment.title)").font(.headline)
                            Text("\(moment.timestamp.formatted()) • held \(Int(moment.until.timeIntervalSince(moment.timestamp))) seconds")
                                .font(.caption).foregroundStyle(.secondary)
                            if let image = model.selectedImage {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .accessibilityLabel("Stored screen image for moment \(moment.id)")
                                    .accessibilityIdentifier("rewind.moment.image")
                            } else {
                                Label("Image unavailable or pruned — text is kept.", systemImage: "text.page")
                                    .foregroundStyle(.secondary)
                            }
                            Text(moment.text.isEmpty ? "No text recognized in this frame." : moment.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("rewind.moment.text")
                        }
                        .padding(18)
                    } else {
                        ContentUnavailableView(
                            model.moments.isEmpty ? "No moments found" : "Choose a moment",
                            systemImage: "clock.arrow.circlepath",
                            description: Text("Start capture explicitly, search existing history, or widen the date range.")
                        )
                    }
                }
                .frame(minWidth: 340)
            }
        }
    }
}

private struct RewindSettingsView: View {
    @ObservedObject var model: RewindModel

    private var bundleIDs: Binding<String> {
        Binding(get: { model.draft.privacy.excludedBundleIDs.joined(separator: "\n") },
                set: { model.draft.privacy.excludedBundleIDs = $0.components(separatedBy: "\n") })
    }
    private var titles: Binding<String> {
        Binding(get: { model.draft.privacy.excludedTitleFragments.joined(separator: "\n") },
                set: { model.draft.privacy.excludedTitleFragments = $0.components(separatedBy: "\n") })
    }

    var body: some View {
        Form {
            Section("Screen Recording belongs to RAPP Rewind") {
                Text("A Terminal, Python, or launchd grant is not this app's grant. Only pressing Start requests permission. Denial stops capture; no TCC settings are changed automatically.")
                HStack {
                    Text("Permission: \(model.capture?.permission.rawValue ?? "unavailable")")
                        .accessibilityIdentifier("rewind.permissions.status")
                    Button("Open Screen Recording Settings") { model.openPermissionSettings() }
                        .accessibilityIdentifier("rewind.permissions.openSettings")
                }
            }
            Section("Capture") {
                TextField("Seconds between samples", value: $model.draft.interval, format: .number)
                    .accessibilityIdentifier("rewind.settings.interval")
                Text("Default: 4 seconds, 1280 px longest edge, JPEG quality 60, 32×32 grayscale deduplication. Vision OCR runs only for changed frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy exclusions — one rule per line") {
                Text("When an excluded app or window is visible on the main display, the entire sample is skipped before OCR. Known excluded windows/apps are also filtered by ScreenCaptureKit. Use app exclusions for sensitive work; titles can change. No default exclusions are added to your existing history.")
                LabeledContent("Bundle identifiers") {
                    TextEditor(text: bundleIDs).font(.system(.body, design: .monospaced))
                        .frame(height: 85)
                        .accessibilityIdentifier("rewind.exclusions.bundles")
                }
                Text("Example: com.apple.keychainaccess • Exact, case-insensitive identifiers. Rewind's own windows are always filtered.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Window title contains") {
                    TextEditor(text: titles).font(.system(.body, design: .monospaced))
                        .frame(height: 75)
                        .accessibilityIdentifier("rewind.exclusions.titles")
                }
            }
            Section("Optional background lifecycle") {
                Toggle("Keep running when the last window closes", isOn: $model.draft.keepRunningWhenWindowClosed)
                    .accessibilityIdentifier("rewind.settings.background")
                Text("Off by default: closing the last window quits and stops capture. If enabled and saved, capture can continue with visible menu-bar Pause/Stop controls. Sleep or lock pauses; resuming is always manual.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.loginStatus == .enabled || model.loginStatus == .requiresApproval ? "Disable Open at Login" : "Enable Open at Login (idle)") {
                        Task { await model.toggleLogin() }
                    }
                    .disabled(model.loginBusy)
                    .accessibilityIdentifier("rewind.settings.login")
                    Text(loginDescription).font(.caption)
                }
                if model.loginStatus == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
                Text("Enabling login never enables recording. macOS may require approval in Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Save changes") {
                Button("Save Settings") { model.saveSettings() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.startupError != nil)
                    .accessibilityIdentifier("rewind.settings.save")
                Text(model.settingsNotice).font(.caption)
                Text("Settings are written only when you save. Changing capture policy pauses capture and requires an explicit Resume.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var loginDescription: String {
        switch model.loginStatus {
        case .enabled: return "Enabled — opens idle"
        case .requiresApproval: return "Awaiting macOS approval"
        case .notRegistered: return "Disabled"
        case .notFound: return "Requires the installed application bundle"
        @unknown default: return "Unknown login status"
        }
    }
}

private struct RetentionView: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        Form {
            Section("Pixels are large. Text stays searchable.") {
                Text("Pruning removes only old image files and sets their image paths/byte counts to empty/zero. Moment rows, OCR text, FTS results, counters, and timestamps are preserved. There is no automatic pruning until you explicitly enable it.")
                TextField("Images older than this many days", value: $model.retentionDays, format: .number)
                    .accessibilityIdentifier("rewind.retention.days")
                HStack {
                    Button("Preview — Delete Nothing") { Task { await model.previewRetention() } }
                        .disabled(model.index == nil)
                        .accessibilityIdentifier("rewind.retention.preview")
                    Button("Remove Previewed Images…", role: .destructive) { model.confirmPrune = true }
                        .disabled((model.prunePreview?.images ?? 0) == 0)
                        .accessibilityIdentifier("rewind.retention.confirm")
                }
                Text(model.retentionNotice).textSelection(.enabled)
                    .accessibilityIdentifier("rewind.retention.result")
            }
            Section("Optional automatic image retention") {
                Toggle("Automatically prune old images while capture is active", isOn: Binding(
                    get: { model.draft.automaticImageRetentionDays != nil },
                    set: { model.draft.automaticImageRetentionDays = $0 ? max(1, model.retentionDays) : nil }
                ))
                .accessibilityIdentifier("rewind.retention.automatic")
                if model.draft.automaticImageRetentionDays != nil {
                    TextField("Keep image days", value: Binding(
                        get: { model.draft.automaticImageRetentionDays ?? 30 },
                        set: { model.draft.automaticImageRetentionDays = $0 }
                    ), format: .number)
                    .accessibilityIdentifier("rewind.retention.automaticDays")
                }
                Button("Save Retention Setting") { model.saveSettings() }
                    .disabled(model.startupError != nil)
                    .accessibilityIdentifier("rewind.retention.save")
                Text(model.settingsNotice).font(.caption)
                Text("Runs at most hourly during an explicitly started capture session, not at app launch. Saving pauses capture. Turning it off never removes anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Permanently remove \(model.prunePreview?.images ?? 0) old images?", isPresented: $model.confirmPrune) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Images, Keep Text", role: .destructive) {
                Task { await model.pruneConfirmedImages() }
            }
            .accessibilityIdentifier("rewind.retention.execute")
        } message: {
            Text("This cannot be undone. All indexed text remains searchable. No action from a RAPP agent or URL can confirm this deletion for you.")
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var model: RewindModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Local diagnostics").font(.largeTitle.bold())
                Text("This view does not request permission or take a screenshot. Diagnostic events never include OCR text, window titles, or images.")
                LabeledContent("Engine", value: "ScreenCaptureKit • Vision • SQLite \(RewindIndex.sqliteVersion) / FTS5")
                LabeledContent("Capture state", value: model.captureState.label)
                LabeledContent("Permission", value: model.capture?.permission.rawValue ?? "unavailable")
                LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "Unbundled development executable")
                LabeledContent("History", value: model.paths.database.path)
                LabeledContent("Settings", value: model.paths.settings.path)
                Text("History is not encrypted by Rewind. Use FileVault and protect your account. The compatibility RAPP agent's host LLM may see text returned by that agent; this app's capture/search path has no network calls.")
                    .font(.caption).foregroundStyle(.secondary)
                if let stats = model.statistics {
                    Divider()
                    LabeledContent("Stored moments", value: "\(stats.frames)")
                    LabeledContent("Image bytes", value: RewindModel.bytes(stats.bytes))
                    LabeledContent("Shots taken", value: "\(stats.shots) (\(stats.newShots) new, \(stats.sameShots) unchanged)")
                    LabeledContent("Deduplication", value: "\(Int(stats.deduplicationRate * 100))% of shots")
                    if let projected = stats.projectedBytesPerDay(interval: model.settings.interval) {
                        LabeledContent("Projected per 24h of active capture", value: RewindModel.bytes(Int64(projected)))
                    }
                }
                HStack {
                    Button("Refresh Diagnostics") {
                        model.refreshSystemStatus()
                        Task { await model.refresh() }
                    }
                    .accessibilityIdentifier("rewind.diagnostics.refresh")
                    Button("Screen Recording Settings") { model.openPermissionSettings() }
                }
                Divider()
                Text("Session events").font(.headline)
                if model.capture?.diagnostics.isEmpty != false {
                    Text("No capture activity. Pressing Start is the only way to request recording.")
                }
                ForEach(model.capture?.diagnostics.reversed() ?? []) { event in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        Text(event.message).textSelection(.enabled)
                    }
                }
            }
            .padding(24)
        }
        .accessibilityIdentifier("rewind.diagnostics")
    }
}
