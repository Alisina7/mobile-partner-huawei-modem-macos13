import SwiftUI
import AppKit

@main
struct MobilePartnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ModemModel()

    var body: some Scene {
        WindowGroup("Mobile Partner") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Modem") {
                Button("Connect") { model.connect() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Disconnect") { model.disconnect() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("Refresh") { model.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Copy Diagnostics") { model.copyDiagnostics() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: ModemModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.contains("--screenshot") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.captureWindow()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    private func captureWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.contentView != nil && $0.frame.width > 400
        }), let view = window.contentView else {
            return
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "/tmp/mp-ui.png"))
    }
}
