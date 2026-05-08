import AppKit
import ServiceManagement

// Receives progress callbacks from helper over XPC
final class ProgressHandler: NSObject, HelperProgressProtocol, @unchecked Sendable {
    private let handler: @Sendable (UInt64, String) -> Void

    init(handler: @escaping @Sendable (UInt64, String) -> Void) {
        self.handler = handler
    }

    func progressUpdate(_ line: String) {
        let tokens = line.split(separator: " ")
        guard let firstToken = tokens.first, let bytes = UInt64(firstToken) else { return }

        var speedStr = ""
        if let speedIdx = tokens.lastIndex(where: { $0.hasSuffix("/s") }),
           speedIdx > tokens.startIndex {
            let speedNum = tokens[tokens.index(before: speedIdx)]
            speedStr = "\(speedNum) \(tokens[speedIdx])"
        }

        handler(bytes, speedStr)
    }
}

@MainActor @Observable
final class DDService {
    var isRunning = false
    var progress: Double = 0
    var bytesTransferred: UInt64 = 0
    var speed: String = ""
    var statusLog: String = ""
    var totalSize: UInt64 = 0
    var timeRemaining: String = ""
    var operationSucceeded = false
    private var startTime: Date?

    nonisolated static let helperID = "com.clonetool.helper"
    nonisolated static let pigzPath = Bundle.main.path(forAuxiliaryExecutable: "pigz") ?? "pigz"
    nonisolated let instanceID = UUID().uuidString

    nonisolated init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [instanceID] _ in
            // Cancel this instance's operation on app quit
            let connection = NSXPCConnection(machServiceName: DDService.helperID, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in } as! HelperToolProtocol
            proxy.cancelOperation(instanceID: instanceID) {}
            connection.invalidate()
        }
    }

    // MARK: - Register Helper

    var helperReady: Bool {
        SMAppService.daemon(plistName: "com.clonetool.helper.plist").status == .enabled
    }

    func registerHelper() {
        let service = SMAppService.daemon(plistName: "com.clonetool.helper.plist")

        if service.status == .requiresApproval {
            appendLog("Helper needs approval in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        appendLog("Registering helper daemon...")
        do {
            try service.register()
            appendLog("Helper daemon is active.")
        } catch {
            if service.status == .enabled {
                appendLog("Updating helper daemon...")
                try? service.unregister()
                do {
                    try service.register()
                    appendLog("Helper daemon is active.")
                } catch {
                    appendLog("Helper update failed: \(error.localizedDescription)")
                }
            } else {
                appendLog("Registration failed: \(error.localizedDescription)")
            }
        }

        if service.status == .requiresApproval {
            appendLog("Please approve CloneTool in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    // MARK: - XPC Connection

    nonisolated private func makeConnection(progressHandler: ProgressHandler) -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: DDService.helperID, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: HelperProgressProtocol.self)
        connection.exportedObject = progressHandler
        connection.resume()
        return connection
    }

    nonisolated private func makeCancelConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: DDService.helperID, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.resume()
        return connection
    }

    // MARK: - Disk to Image

    func diskToImage(source: DiskInfo, destinationPath: String, compress: Bool) async {
        let script: String
        if compress {
            script = """
            #!/bin/bash
            diskutil unmountDisk \(source.devicePath) > /dev/null 2>&1
            dd if=\(source.rawDevicePath) bs=16m status=progress | '\(DDService.pigzPath)' > '\(destinationPath)'
            """
        } else {
            script = """
            #!/bin/bash
            diskutil unmountDisk \(source.devicePath) > /dev/null 2>&1
            dd if=\(source.rawDevicePath) of='\(destinationPath)' bs=16m status=progress
            """
        }
        await runOperation(totalSize: source.sizeBytes, script: script, outputPath: destinationPath)
    }

    // MARK: - Image to Disk

    func imageToDisk(sourcePath: String, target: DiskInfo) async {
        let decompress = sourcePath.hasSuffix(".gz")
        let script: String
        if decompress {
            script = """
            #!/bin/bash
            diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
            '\(DDService.pigzPath)' -d -c '\(sourcePath)' | dd of=\(target.rawDevicePath) bs=16m status=progress
            """
        } else {
            script = """
            #!/bin/bash
            diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
            dd if='\(sourcePath)' of=\(target.rawDevicePath) bs=16m status=progress
            """
        }
        await runOperation(totalSize: target.sizeBytes, script: script)
    }

    // MARK: - Disk to Disk

    func diskToDisk(source: DiskInfo, target: DiskInfo) async {
        let script = """
        #!/bin/bash
        diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
        dd if=\(source.rawDevicePath) of=\(target.rawDevicePath) bs=16m status=progress
        """
        await runOperation(totalSize: source.sizeBytes, script: script)
    }

    // MARK: - Cancel

    func cancel() {
        Task.detached {
            await self.cancelViaXPC()
        }
        isRunning = false
        appendLog("Operation cancelled.")
    }

    // MARK: - Nonisolated XPC helpers

    nonisolated private func executeViaXPC(script: String, progressHandler: ProgressHandler) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let connection = makeConnection(progressHandler: progressHandler)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: (-1, "XPC error: \(error.localizedDescription)"))
            } as! HelperToolProtocol

            proxy.execute(script: script, instanceID: self.instanceID) { status, output in
                connection.invalidate()
                continuation.resume(returning: (status, output))
            }
        }
    }

    nonisolated private func cancelViaXPC() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let connection = makeCancelConnection()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                continuation.resume()
            } as! HelperToolProtocol

            proxy.cancelOperation(instanceID: self.instanceID) {
                connection.invalidate()
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    private func runOperation(totalSize: UInt64, script: String, outputPath: String? = nil) async {
        isRunning = true
        progress = 0
        bytesTransferred = 0
        speed = ""
        timeRemaining = ""
        operationSucceeded = false
        self.totalSize = totalSize
        statusLog = ""
        startTime = Date()

        appendLog("Starting operation...")
        appendLog("Total size: \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))")

        registerHelper()

        let handler = ProgressHandler { [weak self] bytes, speedStr in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bytesTransferred = bytes
                if self.totalSize > 0 {
                    self.progress = min(Double(bytes) / Double(self.totalSize), 1.0)
                }
                if !speedStr.isEmpty {
                    self.speed = speedStr
                }
                if let startTime = self.startTime, self.progress > 0.01 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let estimatedTotal = elapsed / self.progress
                    let remaining = estimatedTotal - elapsed
                    if remaining > 0 {
                        self.timeRemaining = self.formatDuration(remaining)
                    }
                }
            }
        }

        let result = await executeViaXPC(script: script, progressHandler: handler)

        if result.status == 0 {
            progress = 1.0
            bytesTransferred = totalSize
            timeRemaining = ""
            if let startTime = startTime {
                let elapsed = Date().timeIntervalSince(startTime)
                appendLog("Operation completed successfully. Elapsed: \(formatDuration(elapsed))")
            } else {
                appendLog("Operation completed successfully.")
            }
            if let outputPath = outputPath {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? UInt64) ?? 0
                if fileSize > 0 {
                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
                    appendLog("Image size: \(sizeStr)")
                }
            }
            if !result.output.isEmpty {
                appendLog(result.output)
            }
            operationSucceeded = true
        } else if result.status == -1 {
            appendLog(result.output)
        } else {
            appendLog("Process exited with status \(result.status)")
        }

        isRunning = false
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        } else {
            return String(format: "%ds", secs)
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        let timestamp = formatter.string(from: Date())
        statusLog += "[\(timestamp)] \(message)\n"
    }
}
