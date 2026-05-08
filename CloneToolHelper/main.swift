import Foundation

private final class StreamContext: @unchecked Sendable {
    var buffer = ""
    let proxy: HelperProgressProtocol?

    init(proxy: HelperProgressProtocol?) {
        self.proxy = proxy
    }
}

final class HelperCommandHandler: NSObject, HelperToolProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var runningProcesses: [String: Process] = [:]
    private static let lock = NSLock()
    weak var connection: NSXPCConnection?

    func execute(script: String, instanceID: String, withReply reply: @escaping (Int32, String) -> Void) {
        let lock = HelperCommandHandler.lock

        // Kill any previous operation for this instance
        lock.lock()
        if let old = HelperCommandHandler.runningProcesses[instanceID], old.isRunning {
            old.terminate()
            old.waitUntilExit()
        }
        HelperCommandHandler.runningProcesses[instanceID] = nil
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.lock()
        HelperCommandHandler.runningProcesses[instanceID] = process
        lock.unlock()

        // Read stderr/stdout for progress lines and forward via XPC
        let ctx = StreamContext(proxy: connection?.remoteObjectProxy as? HelperProgressProtocol)

        pipe.fileHandleForReading.readabilityHandler = { [ctx] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

            ctx.buffer += chunk
            // dd uses \r for in-place progress; errors arrive as \n-terminated lines.
            // Split on both so error output isn't held in the buffer until exit.
            while let idx = ctx.buffer.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
                let line = String(ctx.buffer[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                ctx.buffer.removeSubrange(...idx)
                if !line.isEmpty {
                    ctx.proxy?.progressUpdate(line)
                }
            }
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            reply(-1, error.localizedDescription)
            return
        }

        pipe.fileHandleForReading.readabilityHandler = nil

        // Flush remaining buffer
        let remaining = ctx.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            ctx.proxy?.progressUpdate(remaining)
        }

        reply(process.terminationStatus, "")

        lock.lock()
        HelperCommandHandler.runningProcesses.removeValue(forKey: instanceID)
        lock.unlock()
    }

    func cancelOperation(instanceID: String, withReply reply: @escaping () -> Void) {
        let lock = HelperCommandHandler.lock
        lock.lock()
        if let process = HelperCommandHandler.runningProcesses[instanceID], process.isRunning {
            process.terminate()
        }
        HelperCommandHandler.runningProcesses.removeValue(forKey: instanceID)
        lock.unlock()
        reply()
    }
}

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let handler = HelperCommandHandler()
        handler.connection = connection
        connection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProgressProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }
}

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: "com.clonetool.helper")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
