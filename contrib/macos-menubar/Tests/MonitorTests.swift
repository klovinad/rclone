import Foundation

@main
struct MonitorTests {
    @MainActor static func main() async throws {
        let scenario = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MENUBAR_TEST_SCENARIO"]!)
        let file: [String: Any] = ["name": "Camera/Example.mov", "bytes": 40, "size": 100,
                                 "group": "job/17", "srcFs": "/media/Demo", "dstFs": "remote:Demo"]
        func stage(running: [Int], finished: Bool = false, success: Bool = true) throws {
            let body: [String: Any] = [
                "running": running, "finished": finished, "success": success,
                "stats": ["bytes": 40, "totalBytes": 100, "speed": 10, "errors": 0,
                          "transfers": 0, "totalTransfers": 1, "transferring": finished ? [] : [file]],
            ]
            try JSONSerialization.data(withJSONObject: body).write(to: scenario, options: .atomic)
        }
        let monitor = TransferMonitor()
        try Data("{\"groups\":null}".utf8).write(to: scenario, options: .atomic)
        await monitor.refresh()
        precondition(monitor.hasConnection && monitor.snapshot.phase == .idle && monitor.snapshot.files.isEmpty,
                     "A fresh engine with null stats groups must show idle, not a connection failure")
        try stage(running: [17, 99])
        await monitor.refresh()
        precondition(monitor.hasConnection && monitor.snapshot.phase == .active)
        precondition(monitor.snapshot.bytes == 40 && monitor.snapshot.files.count == 1,
                     "Historical global stats and API-only jobs must not enter transfer totals")
        precondition(monitor.snapshot.title == "Demo")
        precondition(monitor.snapshot.eta == nil && TransferText.duration(nil) == "Calculating…")

        try stage(running: [], finished: true, success: false)
        await monitor.refresh()
        precondition(monitor.snapshot.phase == .failed, "A finished failed job must not show success")
        try Data("{}".utf8).write(to: scenario, options: .atomic)
        await monitor.refresh()
        precondition(monitor.snapshot.phase == .failed && monitor.hasConnection,
                     "Keep the completed result after the RC job expires")

        try Data("{\"pid\":54321}".utf8).write(to: scenario, options: .atomic)
        let runtimeURL = RcloneRuntime.support.appendingPathComponent("runtime.json")
        var runtime = try JSONSerialization.jsonObject(with: Data(contentsOf: runtimeURL)) as! [String: Any]
        runtime["rclone_pid"] = 54321
        try JSONSerialization.data(withJSONObject: runtime).write(to: runtimeURL, options: .atomic)
        await monitor.refresh()
        precondition(monitor.snapshot.phase == .idle && monitor.snapshot.bytes == 0,
                     "A new engine must not inherit the previous engine's completion")

        try Data("{\"offline\":true}".utf8).write(to: scenario, options: .atomic)
        await monitor.refresh()
        precondition(monitor.snapshot.phase == .offline && !monitor.hasConnection)
        precondition(monitor.snapshot.files.isEmpty && monitor.snapshot.eta == nil,
                     "Do not show stale files or ETA after losing the connection")

        let first = ActiveFile(name: "same.mov", group: "job/1")
        let second = ActiveFile(name: "same.mov", group: "job/2")
        precondition(first.id != second.id, "Files from different jobs must keep distinct row identities")
        print("PASS: empty startup, active-job filtering, failure, expired history, engine change, offline state, unknown ETA, row identity")
    }
}
