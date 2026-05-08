import Foundation
import SwiftUI

@MainActor @Observable
final class CloneViewModel {
    var schema: OperationSchema = .diskToImage
    var disks: [DiskInfo] = []
    var selectedSourceId: String?
    var selectedTargetId: String?
    var imagePath: String = ""
    var imageName: String = ""
    var imageVersion: String = ""
    var state: OperationState = .idle
    var showConfirmation = false

    let ddService = DDService()

    private let defaultImageDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/CloneTool/DiskImages")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var defaultImageDirectory: URL { defaultImageDir }

    // MARK: - Computed

    var sourceDisk: DiskInfo? {
        disks.first { $0.id == selectedSourceId }
    }

    var targetDisk: DiskInfo? {
        disks.first { $0.id == selectedTargetId }
    }

    var sourceDisks: [DiskInfo] {
        disks.filter { !$0.isSynthesized }
    }

    var targetDisks: [DiskInfo] {
        switch schema {
        case .diskToImage:
            return [] // target is a file path
        case .imageToDisk, .diskToDisk:
            return disks.filter { $0.isExternal && !$0.isSynthesized }
        }
    }

    var generatedFileName: String {
        if imageName.isEmpty {
            return "\(sourceDisk?.id ?? "disk")_\(dateStamp()).img.gz"
        }
        if imageVersion.isEmpty {
            return "\(imageName).img.gz"
        }
        return "\(imageName)_v\(imageVersion.trimmingCharacters(in: .whitespaces)).img.gz"
    }

    var canStart: Bool {
        guard state != .running else { return false }
        switch schema {
        case .diskToImage:
            return sourceDisk != nil
        case .imageToDisk:
            return !imagePath.isEmpty && targetDisk != nil
        case .diskToDisk:
            return sourceDisk != nil && targetDisk != nil && selectedSourceId != selectedTargetId
        }
    }

    // MARK: - Actions

    func refreshDisks() async {
        do {
            var fetchedDisks = try await DiskService.listDisks()
            // Fill in byte sizes
            for i in fetchedDisks.indices {
                let bytes = try await DiskService.diskSizeBytes(fetchedDisks[i].id)
                fetchedDisks[i] = DiskInfo(
                    id: fetchedDisks[i].id,
                    mediaType: fetchedDisks[i].mediaType,
                    size: fetchedDisks[i].size,
                    sizeBytes: bytes,
                    partitionNames: fetchedDisks[i].partitionNames
                )
            }
            disks = fetchedDisks
        } catch {
            ddService.statusLog += "Error listing disks: \(error.localizedDescription)\n"
        }
    }

    func startClone() async {
        state = .running

        switch schema {
        case .diskToImage:
            guard let source = sourceDisk else { return }
            let destPath = defaultImageDir.appendingPathComponent(generatedFileName).path
            imagePath = destPath
            await ddService.diskToImage(source: source, destinationPath: destPath, compress: true)

        case .imageToDisk:
            guard let target = targetDisk else { return }
            await ddService.imageToDisk(sourcePath: imagePath, target: target)

        case .diskToDisk:
            guard let source = sourceDisk, let target = targetDisk else { return }
            await ddService.diskToDisk(source: source, target: target)
        }

        state = ddService.isRunning ? .running : .completed
    }

    func cancelClone() {
        ddService.cancel()
        state = .idle
    }

    func browseForImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = defaultImageDir
        panel.title = "Select Disk Image"
        if panel.runModal() == .OK, let url = panel.url {
            imagePath = url.path
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
