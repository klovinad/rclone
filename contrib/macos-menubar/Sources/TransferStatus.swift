import AppKit
import SwiftUI

struct RcloneRuntime: Decodable {
    let wrapper_pid: Int32
    let rclone_pid: Int32
    let api_url: String
    let login_url: String
    let user: String
    let password: String

    static var support: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--state-dir"), arguments.count > index + 1 {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let path = ProcessInfo.processInfo.environment["RCLONE_MENUBAR_STATE_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Rclone Menu Bar", isDirectory: true)
    }

    static func read() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: support.appendingPathComponent("runtime.json")))
    }

    var wrapperIsAlive: Bool { wrapper_pid > 1 && kill(wrapper_pid, 0) == 0 }
}

enum StatusError: Error { case unavailable, invalidIdentity }

struct RcloneClient {
    let runtime: RcloneRuntime
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }()

    func call<T: Decodable>(_ endpoint: String, _ body: [String: Any] = [:]) async throws -> T {
        guard let base = URL(string: runtime.api_url), base.scheme == "http",
              base.host == "127.0.0.1", base.port != nil else { throw StatusError.unavailable }
        var request = URLRequest(url: base.appendingPathComponent(endpoint))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(runtime.user):\(runtime.password)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StatusError.unavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func verify() async throws {
        struct Identity: Decodable { let pid: Int32 }
        let identity: Identity = try await call("core/pid")
        guard identity.pid == runtime.rclone_pid else { throw StatusError.invalidIdentity }
    }
}

struct ActiveFile: Decodable, Identifiable {
    var name: String
    var bytes: Double?
    var size: Double?
    var speed: Double?
    var speedAvg: Double?
    var eta: Double?
    var group: String?
    var srcFs: String?
    var dstFs: String?
    var id: String { [group ?? "", srcFs ?? "", dstFs ?? "", name].joined(separator: "\u{1f}") }
    var filename: String { (name as NSString).lastPathComponent }
    var directory: String { (name as NSString).deletingLastPathComponent }
    var fraction: Double? {
        guard let size, size > 0 else { return nil }
        return min(1, max(0, (bytes ?? 0) / size))
    }
}

struct TransferStats: Decodable {
    var bytes: Double?
    var totalBytes: Double?
    var speed: Double?
    var eta: Double?
    var errors: Int?
    var transfers: Int?
    var totalTransfers: Int?
    var transferring: [ActiveFile]?
    var checking: [CheckingFile]?
    struct CheckingFile: Decodable { let name: String? }
}

struct TransferSnapshot {
    enum Phase: String { case loading, active, idle, completed, failed, offline }
    var phase: Phase = .loading
    var title = "Connecting to rclone…"
    var bytes: Double = 0
    var totalBytes: Double = 0
    var speed: Double = 0
    var eta: Double?
    var errors = 0
    var completedFiles = 0
    var totalFiles = 0
    var checking = 0
    var files: [ActiveFile] = []
    var fraction: Double? { totalBytes > 0 ? min(1, max(0, bytes / totalBytes)) : nil }
    var symbol: String {
        switch phase {
        case .active: return "icloud.and.arrow.up"
        case .completed, .idle: return "checkmark.icloud"
        case .failed, .offline: return "exclamationmark.icloud"
        case .loading: return "icloud"
        }
    }
    var status: String {
        switch phase {
        case .loading: return "Connecting…"
        case .active: return files.isEmpty ? (checking > 0 ? "Checking files" : "Preparing transfer") : "Transferring · \(files.count)"
        case .idle: return "No active transfers"
        case .completed: return "Transfer completed"
        case .failed: return "Transfer failed"
        case .offline: return "Cannot reach rclone"
        }
    }

    static func combine(_ stats: [TransferStats], phase: Phase, previousTitle: String) -> Self {
        let files = stats.flatMap { $0.transferring ?? [] }.sorted { $0.id < $1.id }
        let roots = Set(files.compactMap { file -> String? in
            guard let source = file.srcFs else { return nil }
            return (source as NSString).lastPathComponent
        })
        let bytes = stats.reduce(0) { $0 + ($1.bytes ?? 0) }
        let total = stats.reduce(0) { $0 + ($1.totalBytes ?? 0) }
        let speed = stats.reduce(0) { $0 + max(0, $1.speed ?? 0) }
        let eta = stats.count == 1 ? stats.first?.eta : (speed > 0 ? max(0, total - bytes) / speed : nil)
        return Self(phase: phase, title: roots.count == 1 ? roots.first! : (roots.count > 1 ? "Multiple folders" : previousTitle),
                    bytes: bytes, totalBytes: total, speed: speed, eta: eta,
                    errors: stats.reduce(0) { $0 + ($1.errors ?? 0) },
                    completedFiles: stats.reduce(0) { $0 + ($1.transfers ?? 0) },
                    totalFiles: stats.reduce(0) { $0 + ($1.totalTransfers ?? 0) },
                    checking: stats.reduce(0) { $0 + ($1.checking?.count ?? 0) }, files: files)
    }
}

enum TransferText {
    static func bytes(_ value: Double) -> String {
        let safe = max(0, value.isFinite ? value : 0)
        let units = ["B", "kB", "MB", "GB", "TB"]
        var amount = safe
        var index = 0
        while amount >= 1000 && index < units.count - 1 { amount /= 1000; index += 1 }
        let format = index == 0 || amount >= 100 ? "%.0f" : "%.1f"
        return String(format: format, locale: Locale(identifier: "en_US_POSIX"), amount) + " " + units[index]
    }

    static func duration(_ seconds: Double?, coarse: Bool = false) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Calculating…" }
        if seconds < 60 { return "Less than a minute" }
        let step = coarse && seconds > 300 ? 5 : 1
        let minutes = Int(ceil(seconds / Double(step * 60))) * step
        let hours = minutes / 60
        if hours >= 24 { return "≈ \(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "≈ \(hours)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m") }
        return "≈ \(minutes)m"
    }
}

@MainActor
final class TransferMonitor: ObservableObject {
    @Published var snapshot = TransferSnapshot()
    @Published var hasConnection = false
    var onChange: (() -> Void)?
    var isVisible = false
    private var polling: Task<Void, Never>?
    private var refreshing = false
    private var lastGroups: [String] = []
    private var identity: Int32?
    private var lastEnginePID: Int32?
    private var title = "Current transfer"

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: self.isVisible ? 2_000_000_000 : 8_000_000_000)
            }
        }
    }

    func stop() { polling?.cancel(); polling = nil }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; onChange?() }
        do {
            let runtime = try RcloneRuntime.read()
            let client = RcloneClient(runtime: runtime)
            if identity != runtime.rclone_pid {
                try await client.verify()
                identity = runtime.rclone_pid
                if lastEnginePID != runtime.rclone_pid {
                    lastGroups = []
                    snapshot = TransferSnapshot()
                    title = "Current transfer"
                }
                lastEnginePID = runtime.rclone_pid
            }
            struct Jobs: Decodable { let runningIds: [Int] }
            struct Groups: Decodable { let groups: [String] }
            let jobs: Jobs = try await client.call("job/list")
            let groups: Groups = try await client.call("core/group-list")
            let running = Set(jobs.runningIds.map { "job/\($0)" })
            let active = groups.groups.filter { running.contains($0) }.sorted()
            var collected: [TransferStats] = []
            var phase: TransferSnapshot.Phase = .active
            if !active.isEmpty {
                // Session-wide stats include old transfers and errors. Show only the current jobs.
                lastGroups = active
                for group in active { collected.append(try await client.call("core/stats", ["group": group])) }
            } else if !lastGroups.isEmpty {
                struct Job: Decodable { let finished: Bool; let success: Bool }
                phase = .completed
                for group in lastGroups {
                    guard let number = Int(group.dropFirst(4)) else { continue }
                    let job: Job = try await client.call("job/status", ["jobid": number])
                    if !job.finished { phase = .active }
                    else if !job.success { phase = .failed }
                    collected.append(try await client.call("core/stats", ["group": group]))
                }
                if phase != .active { lastGroups = [] }
            } else if [.completed, .failed].contains(snapshot.phase) {
                hasConnection = true
                return
            } else { phase = .idle }
            snapshot = TransferSnapshot.combine(collected, phase: phase, previousTitle: title)
            title = snapshot.title
            hasConnection = true
        } catch {
            // Never present stale progress or a guessed completion time as live data.
            snapshot = TransferSnapshot(phase: .offline, title: "Status unavailable")
            hasConnection = false
            identity = nil
        }
    }
}

private enum StatusPalette {
    // Opaque semantic surfaces keep text readable against either menu-bar appearance.
    static let background = Color(nsColor: .windowBackgroundColor)
    static let secondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.73, green: 0.73, blue: 0.75, alpha: 1)
            : NSColor(srgbRed: 0.35, green: 0.35, blue: 0.37, alpha: 1)
    })
}

struct TransferPanel: View {
    @ObservedObject var monitor: TransferMonitor
    var openInterface: () -> Void
    var quit: () -> Void
    var preview = false

    private var state: TransferSnapshot { monitor.snapshot }
    private var showSummary: Bool { [.active, .completed, .failed].contains(state.phase) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "icloud").font(.system(size: 20, weight: .medium)).accessibilityHidden(true)
                Text("Rclone").font(.system(size: 15, weight: .semibold))
                if preview { Text("Demo").font(.caption).foregroundStyle(StatusPalette.secondary) }
                Spacer()
                Menu {
                    Button("Open Rclone Web", action: openInterface).keyboardShortcut("o")
                    Divider()
                    Button("Quit Rclone…", action: quit).keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 17)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Rclone actions").accessibilityLabel("Rclone actions")
            }
            .padding(.bottom, 18)

            if showSummary { summary }
            else { emptyState }

            if state.phase == .active && !state.files.isEmpty {
                HStack {
                    Text("Transferring now").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(state.files.count)").monospacedDigit().foregroundStyle(StatusPalette.secondary)
                }.padding(.top, 18).padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(state.files) { file in
                            FileTransferRow(file: file)
                            if file.id != state.files.last?.id { Divider().padding(.vertical, 10) }
                        }
                    }.padding(.trailing, 2)
                }
                .frame(height: min(CGFloat(state.files.count) * 84 - 20, 332))
                .scrollIndicators(.automatic)
                .accessibilityLabel("Active files")
            }

            Divider().padding(.top, 16).padding(.bottom, 12)
            HStack {
                if showSummary && state.totalFiles > 0 {
                    Text("Completed: \(state.completedFiles) of \(state.totalFiles)")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(StatusPalette.secondary)
                } else { Text("Local rclone").font(.system(size: 12)).foregroundStyle(StatusPalette.secondary) }
                Spacer(minLength: 8)
                Button("Open Rclone Web", action: openInterface)
                    .keyboardShortcut("o").controlSize(.regular)
                    .disabled(!monitor.hasConnection)
            }
        }
        .padding(16)
        .frame(width: 408)
        .background(StatusPalette.background)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(state.title).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle).help(state.title)
            HStack(alignment: .firstTextBaseline) {
                Text(state.status).font(.system(size: 12)).foregroundStyle(StatusPalette.secondary)
                Spacer(minLength: 4)
                Text(state.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .frame(width: 57, alignment: .trailing)
            }
            ProgressView(value: state.fraction ?? 0).progressViewStyle(.linear).frame(height: 6)
                .accessibilityLabel("Overall progress")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TransferText.bytes(state.bytes) + " of " + TransferText.bytes(state.totalBytes))
                        .monospacedDigit()
                    Text(state.phase == .active ? (state.speed > 0 ? TransferText.bytes(state.speed) + "/s" : "Waiting for data…") : state.status)
                        .foregroundStyle(StatusPalette.secondary).monospacedDigit()
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(state.phase == .active ? (state.eta == nil ? "Calculating…" : "Remaining " + TransferText.duration(state.eta, coarse: true).lowercased()) : "")
                        .monospacedDigit()
                    Text(state.phase == .active ? "At current speed" : "")
                        .foregroundStyle(StatusPalette.secondary)
                }.frame(minWidth: 150, alignment: .trailing)
            }.font(.system(size: 12))
            if state.errors > 0 || state.phase == .failed {
                Label(state.phase == .active ? "Errors reported. See Rclone Web." : "See Rclone Web for error details.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(StatusPalette.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: state.symbol).font(.system(size: 30)).accessibilityHidden(true)
            Text(state.status).font(.system(size: 14, weight: .semibold))
            Text(state.phase == .offline ? "Status updates automatically.\nClose this panel and check again later." :
                    state.phase == .loading ? "Reading active files and progress." : "New transfers appear here automatically.")
                .font(.system(size: 12)).foregroundStyle(StatusPalette.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if state.phase == .offline {
                Button("Refresh") { if !preview { Task { await monitor.refresh() } } }.controlSize(.regular)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

private struct FileTransferRow: View {
    let file: ActiveFile
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "doc").foregroundStyle(StatusPalette.secondary).accessibilityHidden(true)
                Text(file.filename).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(file.name)
                Spacer(minLength: 4)
                Text(file.fraction.map { "\(Int($0 * 100))%" } ?? "—")
                    .font(.system(size: 12)).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text(file.directory.isEmpty ? "Root folder" : file.directory)
                    .lineLimit(1).truncationMode(.middle).help(file.name)
                Spacer(minLength: 4)
                Text(TransferText.duration(file.eta)).monospacedDigit()
            }.font(.system(size: 11)).foregroundStyle(StatusPalette.secondary)
            ProgressView(value: file.fraction ?? 0).progressViewStyle(.linear).controlSize(.small).frame(height: 4)
                .accessibilityLabel("Progress for \(file.filename)")
            HStack(spacing: 4) {
                Text(TransferText.bytes(file.bytes ?? 0) + " / " + TransferText.bytes(file.size ?? 0))
                Spacer(minLength: 4)
                Text(TransferText.bytes(file.speedAvg ?? file.speed ?? 0) + "/s")
            }.font(.system(size: 11)).monospacedDigit().foregroundStyle(StatusPalette.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
