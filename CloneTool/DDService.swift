import AppKit
import ServiceManagement

// Receives progress callbacks from helper over XPC
final class ProgressHandler: NSObject, HelperProgressProtocol, @unchecked Sendable {
    private let progressHandler: @Sendable (UInt64, String) -> Void
    private let logHandler: @Sendable (String) -> Void

    init(
        progressHandler: @escaping @Sendable (UInt64, String) -> Void,
        logHandler: @escaping @Sendable (String) -> Void
    ) {
        self.progressHandler = progressHandler
        self.logHandler = logHandler
    }

    func progressUpdate(_ line: String) {
        let tokens = line.split(separator: " ")
        // dd's status=progress lines start with a byte count, e.g.
        //   "1024 bytes transferred in 0.001 secs (1024000 bytes/sec)"
        // Anything else (errors, dd's record-count summary, etc.) is a log line.
        if let firstToken = tokens.first, let bytes = UInt64(firstToken) {
            var speedStr = ""
            if let speedIdx = tokens.lastIndex(where: { $0.hasSuffix("/s") }),
               speedIdx > tokens.startIndex {
                let speedNum = tokens[tokens.index(before: speedIdx)]
                speedStr = "\(speedNum) \(tokens[speedIdx])"
            }
            progressHandler(bytes, speedStr)
        } else {
            logHandler(line)
        }
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
    var needsFullDiskAccess = false

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

        if service.status == .notFound {
            appendLog("Helper daemon not found in app bundle.")
            return
        }

        if service.status == .requiresApproval {
            appendLog("Helper needs approval in System Settings > Login Items.")
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        // Always try to register (updates binary if already enabled)
        appendLog("Registering helper daemon...")
        do {
            try service.register()
            appendLog("Helper daemon is active.")
        } catch {
            // If register fails because already enabled, try unregister then re-register
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
            set -o pipefail
            diskutil unmountDisk \(source.devicePath) > /dev/null 2>&1
            dd if=\(source.rawDevicePath) bs=16m status=progress | '\(DDService.pigzPath)' > '\(destinationPath)'
            """
        } else {
            script = """
            #!/bin/bash
            set -o pipefail
            diskutil unmountDisk \(source.devicePath) > /dev/null 2>&1
            dd if=\(source.rawDevicePath) of='\(destinationPath)' bs=16m status=progress
            """
        }
        await runOperation(totalSize: source.sizeBytes, script: script)
    }

    // MARK: - Image to Disk

    func imageToDisk(sourcePath: String, target: DiskInfo) async {
        let decompress = sourcePath.hasSuffix(".gz")
        let script: String
        if decompress {
            script = """
            #!/bin/bash
            set -o pipefail
            diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
            '\(DDService.pigzPath)' -d -c '\(sourcePath)' | dd of=\(target.rawDevicePath) bs=16m status=progress
            """
        } else {
            script = """
            #!/bin/bash
            set -o pipefail
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
        set -o pipefail
        diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
        dd if=\(source.rawDevicePath) of=\(target.rawDevicePath) bs=16m status=progress
        """
        await runOperation(totalSize: source.sizeBytes, script: script)
    }

    // MARK: - Full Disk Access

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
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

    private func runOperation(totalSize: UInt64, script: String) async {
        isRunning = true
        progress = 0
        bytesTransferred = 0
        speed = ""
        self.totalSize = totalSize
        statusLog = ""
        needsFullDiskAccess = false

        appendLog("Starting operation...")
        appendLog("Total size: \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file))")

        registerHelper()

        let handler = ProgressHandler(
            progressHandler: { [weak self] bytes, speedStr in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.bytesTransferred = bytes
                    if self.totalSize > 0 {
                        self.progress = min(Double(bytes) / Double(self.totalSize), 1.0)
                    }
                    if !speedStr.isEmpty {
                        self.speed = speedStr
                    }
                }
            },
            logHandler: { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.appendLog(line)
                    if line.localizedCaseInsensitiveContains("Operation not permitted") {
                        self.needsFullDiskAccess = true
                    }
                }
            }
        )

        let result = await executeViaXPC(script: script, progressHandler: handler)

        if result.status == 0 {
            progress = 1.0
            appendLog("Operation completed successfully.")
            if !result.output.isEmpty {
                appendLog(result.output)
            }
        } else if result.status == -1 {
            appendLog(result.output)
        } else {
            appendLog("Process exited with status \(result.status)")
        }

        isRunning = false
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        statusLog += "[\(timestamp)] \(message)\n"
    }
}
