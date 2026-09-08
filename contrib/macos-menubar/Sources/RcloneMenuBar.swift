import AppKit
import SwiftUI

@MainActor
final class StatusPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var service: Process?
    private var serviceOutput: FileHandle?
    private var statusItem: NSStatusItem?
    private let statusPanel = StatusPanelWindow(contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let monitor = TransferMonitor()
    private var previewWindow: NSWindow?
    private var quitting = false
    private var confirmedQuit = false
    private var shutdownRuntime: RcloneRuntime?
    private var preview = false
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
            showPreview(CommandLine.arguments[index + 1])
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: 29)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.setAccessibilityLabel("Rclone transfers")
        statusItem = item
        statusPanel.title = "Rclone transfers"
        statusPanel.level = .statusBar
        statusPanel.isReleasedWhenClosed = false
        statusPanel.isOpaque = false
        statusPanel.backgroundColor = .clear
        statusPanel.hasShadow = true
        statusPanel.hidesOnDeactivate = false
        statusPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        statusPanel.contentViewController = NSHostingController(rootView: panel.clipShape(.rect(cornerRadius: 12)))
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: statusPanel, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
        monitor.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.statusPanel.isVisible == true { self?.closePanel(); return nil }
            return event
        }
        Task { await connectOrStart() }
    }

    private var panel: TransferPanel {
        TransferPanel(monitor: monitor, openInterface: { [weak self] in self?.openInterface() },
                      quit: { NSApp.terminate(nil) }, preview: preview)
    }

    private func connectOrStart() async {
        if let runtime = try? RcloneRuntime.read(), runtime.wrapperIsAlive {
            do {
                try await RcloneClient(runtime: runtime).verify()
                // Reattaching the menu preserves the engine's upload sessions.
                monitor.start()
                return
            } catch {
                monitor.snapshot = TransferSnapshot(phase: .offline, title: "Existing rclone service is unavailable")
                monitor.start()
                return
            }
        }
        do {
            let support = RcloneRuntime.support
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let log = support.appendingPathComponent("service.log")
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let output = try FileHandle(forWritingTo: log)
            try output.seekToEnd()
            serviceOutput = output
            let process = Process()
            process.executableURL = try pythonExecutable()
            guard let script = Bundle.main.url(forResource: "service", withExtension: "py") else {
                throw StatusError.unavailable
            }
            process.arguments = [script.path]
            var environment = ProcessInfo.processInfo.environment
            environment["RCLONE_MENUBAR_STATE_DIR"] = support.path
            process.environment = environment
            process.currentDirectoryURL = support
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.quitting else { return }
                    await self.monitor.refresh()
                }
            }
            service = process
            try process.run()
            for _ in 0..<80 {
                if let state = try? RcloneRuntime.read(), state.wrapperIsAlive,
                   (try? await RcloneClient(runtime: state).verify()) != nil {
                    monitor.start()
                    if !CommandLine.arguments.contains("--no-open") { openInterface() }
                    return
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            throw StatusError.unavailable
        } catch {
            monitor.snapshot = TransferSnapshot(phase: .offline, title: "Could not start rclone")
            updateIcon()
            monitor.start()
        }
    }

    private func pythonExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["RCLONE_MENUBAR_PYTHON"] {
            guard explicit.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: explicit) else {
                throw StatusError.unavailable
            }
            return URL(fileURLWithPath: explicit)
        }
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for directory in directories where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("python3")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw StatusError.unavailable
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = RcloneIcon.image
        button.imagePosition = .imageOnly
        button.title = ""
        button.toolTip = "Rclone · " + monitor.snapshot.status
        button.setAccessibilityValue(monitor.snapshot.status)
        if statusPanel.isVisible {
            DispatchQueue.main.async { [weak self] in self?.positionPanel() }
        }
    }

    @objc private func togglePanel() {
        guard statusItem?.button != nil else { return }
        if statusPanel.isVisible { closePanel(); return }
        monitor.isVisible = true
        positionPanel()
        statusPanel.makeKeyAndOrderFront(nil)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.statusItem?.button?.accessibilityFrame().contains(NSEvent.mouseLocation) != true { self.closePanel() }
            }
        }
        Task { await monitor.refresh() }
    }

    private func positionPanel() {
        guard let button = statusItem?.button, let host = statusPanel.contentViewController else { return }
        host.view.layoutSubtreeIfNeeded()
        let anchor = button.accessibilityFrame()
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? button.window?.screen ?? NSScreen.main
        guard let screen else { return }
        let safe = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let height = min(ceil(host.view.fittingSize.height), safe.height)
        let width: CGFloat = 408
        let x = min(max(anchor.midX - width / 2, safe.minX), safe.maxX - width)
        // Anchor to the actual display's menu bar. NSPopover can misplace this status item on external displays.
        statusPanel.setFrame(NSRect(x: x, y: safe.maxY - height, width: width, height: height), display: true)
    }

    private func closePanel() {
        statusPanel.orderOut(nil)
        monitor.isVisible = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor); self.outsideClickMonitor = nil }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return false
    }

    private func openInterface() {
        guard !preview, let state = try? RcloneRuntime.read(),
              let url = URL(string: state.login_url), url.host == "127.0.0.1" else { return }
        closePanel()
        NSWorkspace.shared.open(url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !preview, !confirmedQuit else { return .terminateNow }
        Task {
            var active: Bool? = nil
            shutdownRuntime = nil
            if let state = try? RcloneRuntime.read() {
                let client = RcloneClient(runtime: state)
                do {
                    try await client.verify()
                    shutdownRuntime = state
                    struct Jobs: Decodable { let runningIds: [Int] }
                    struct Groups: Decodable { let groups: [String] }
                    let jobs: Jobs = try await client.call("job/list")
                    let groups: Groups = try await client.call("core/group-list")
                    let ids = Set(jobs.runningIds.map { "job/\($0)" })
                    active = groups.groups.contains { ids.contains($0) }
                } catch { active = nil }
            }
            if active != false {
                let alert = NSAlert()
                alert.messageText = "Quit Rclone Menu Bar?"
                alert.informativeText = active == true
                    ? "Active transfers will stop. Close this panel to keep them running."
                    : "Transfer status is unavailable. Quitting rclone may stop active transfers."
                alert.addButton(withTitle: "Keep running")
                alert.addButton(withTitle: "Quit")
                confirmedQuit = alert.runModal() == .alertSecondButtonReturn
            } else { confirmedQuit = true }
            if confirmedQuit, let state = shutdownRuntime {
                do {
                    let client = RcloneClient(runtime: state)
                    try await client.verify()
                    struct Empty: Decodable {}
                    let _: Empty = try await client.call("core/quit")
                } catch {
                    confirmedQuit = false
                    let alert = NSAlert()
                    alert.messageText = "Could not stop rclone"
                    alert.informativeText = "Check the service and try again. The menu bar app will stay open."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            sender.reply(toApplicationShouldTerminate: confirmedQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        quitting = true
        monitor.stop()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        if confirmedQuit {
            if service?.isRunning == true { service?.terminate() }
        }
        try? serviceOutput?.close()
    }

    private func showPreview(_ path: String) {
        preview = true
        do {
            struct Fixture: Decodable { let phase: String; let title: String; let stats: TransferStats }
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            monitor.snapshot = .combine([fixture.stats], phase: .init(rawValue: fixture.phase) ?? .active,
                                        previousTitle: fixture.title)
            monitor.hasConnection = monitor.snapshot.phase != .offline
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 408, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Rclone Menu Bar — demo"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: panel)
            if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
            if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
            window.orderFrontRegardless()
            previewWindow = window
        } catch { NSApp.terminate(nil) }
    }
}

@main
struct RcloneMenuBarApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
