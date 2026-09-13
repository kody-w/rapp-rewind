import AppKit
import RAPPRewindCore
import SwiftUI

@main
enum RewindLauncher {
    @MainActor
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--self-test" {
            exit(await NativeCommands.selfTest())
        }
        if arguments.first == "--rewind-command" {
            exit(await NativeCommands.run(Array(arguments.dropFirst())))
        }
        RAPPRewindApplication.main()
    }
}

@MainActor
private final class RewindAppDelegate: NSObject, NSApplicationDelegate {
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in RewindModel.shared.capture?.pause() }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { _ in
            Task { @MainActor in RewindModel.shared.capture?.pause() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if RewindModel.shared.settings.keepRunningWhenWindowClosed { return false }
        RewindModel.shared.capture?.stop()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        RewindModel.shared.capture?.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }
}

private struct RAPPRewindApplication: App {
    @NSApplicationDelegateAdaptor(RewindAppDelegate.self) private var delegate
    @StateObject private var model = RewindModel.shared

    var body: some Scene {
        Window("RAPP Rewind", id: "main") {
            RewindWindow(model: model)
        }
        .defaultSize(width: 1140, height: 760)
        .commands { RewindWindowCommands() }
        MenuBarExtra {
            RewindMenu(model: model)
        } label: {
            Image(systemName: model.captureState.isCapturing ? "record.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(model.captureState.isCapturing ? Color.red : Color.primary)
                .accessibilityLabel("RAPP Rewind: \(model.captureState.label)")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct RewindWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Show Rewind") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct RewindMenu: View {
    @ObservedObject var model: RewindModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text(model.captureState.label)
                .accessibilityIdentifier("rewind.menu.state")
            Button(model.captureState == .paused ? "Resume Capture" : "Start Capture") {
                Task { await model.capture?.start() }
            }
            .disabled(model.capture == nil || model.captureState == .capturing || model.captureState == .requestingPermission)
            .accessibilityIdentifier("rewind.menu.start")
            Button("Pause Capture") { model.capture?.pause() }
                .disabled(model.captureState != .capturing && model.captureState != .requestingPermission)
                .accessibilityIdentifier("rewind.menu.pause")
            Button("Stop Capture") { model.capture?.stop() }
                .disabled(model.capture == nil || model.captureState == .stopped)
                .accessibilityIdentifier("rewind.menu.stop")
            Divider()
            Button("Show Rewind") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier("rewind.menu.show")
            Button("Quit Rewind") {
                model.capture?.stop()
                NSApp.terminate(nil)
            }
            .accessibilityIdentifier("rewind.menu.quit")
        }
    }
}
