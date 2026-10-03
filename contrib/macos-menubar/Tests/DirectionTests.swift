import AppKit

@main
struct DirectionTests {
    @MainActor static func main() throws {
        func state(_ src: String?, _ dst: String?, phase: TransferSnapshot.Phase = .active) -> TransferSnapshot {
            TransferSnapshot(phase: phase, files: [ActiveFile(name: "test.mov", srcFs: src, dstFs: dst)])
        }
        precondition(state("kd-drive{84KcY}:", "/Volumes/SSD").indicator == .download)
        precondition(state("/Volumes/SSD: Media", "drive:folder").indicator == .upload)
        precondition(state(":local:/tmp/source", "drive:folder").indicator == .upload)
        precondition(state("drive:", ":local{ABC}:/tmp").indicator == .download)
        precondition(state("drive:a", "drive:b").indicator == .copy)
        precondition(state("/tmp/a", "/tmp/b").indicator == .copy)
        precondition(state(nil, "drive:").indicator == .working)
        precondition(state("drive:", nil).indicator == .working)
        var mixed = state("drive:", "/tmp")
        mixed.files.append(ActiveFile(name: "upload", srcFs: "/tmp", dstFs: "drive:"))
        precondition(mixed.indicator == .both)
        precondition(TransferSnapshot(phase: .active, checking: 2).indicator == .checking)
        precondition(TransferSnapshot(phase: .active).indicator == .working)
        precondition(state("/tmp", "drive:", phase: .completed).indicator == .idle)
        precondition(state("/tmp", "drive:", phase: .offline).indicator == .warning)
        for indicator in TransferIndicator.allCases {
            let image = RcloneIcon.image(for: indicator)
            precondition(image.isTemplate && image.size == NSSize(width: 22, height: 18))
        }
        print("PASS: upload, download, local/cloud copy, both directions, unknown paths, checks, idle, offline, fixed-size template icons")
    }
}
