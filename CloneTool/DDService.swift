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
    nonisolated static let resize2fsPath = Bundle.main.path(forAuxiliaryExecutable: "resize2fs") ?? "resize2fs"
    nonisolated static let e2fsckPath = Bundle.main.path(forAuxiliaryExecutable: "e2fsck") ?? "e2fsck"
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

    func diskToImage(source: DiskInfo, destinationPath: String, compress: Bool, shrinkFilesystem: Bool) async {
        let script: String
        if shrinkFilesystem {
            let tempPath = destinationPath + ".tmp.img"
            let shrinkSection = shrinkRootfsScript(imageFile: tempPath)
            let finalize: String
            if compress {
                finalize = """
                echo "Compressing image..."
                '\(DDService.pigzPath)' -c '\(tempPath)' > '\(destinationPath)'
                rm -f '\(tempPath)'
                """
            } else {
                finalize = "mv -f '\(tempPath)' '\(destinationPath)'"
            }
            script = """
            #!/bin/bash
            set -o pipefail
            diskutil unmountDisk \(source.devicePath) > /dev/null 2>&1
            dd if=\(source.rawDevicePath) of='\(tempPath)' bs=16m conv=sparse status=progress
            DD_STATUS=$?
            if [ $DD_STATUS -ne 0 ]; then rm -f '\(tempPath)'; exit $DD_STATUS; fi
            \(shrinkSection)
            \(finalize)
            """
        } else if compress {
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
            dd if=\(source.rawDevicePath) of='\(destinationPath)' bs=16m conv=sparse status=progress
            """
        }
        await runOperation(totalSize: source.sizeBytes, script: script)
    }

    private func shrinkRootfsScript(imageFile: String) -> String {
        return """

        # --- Shrink last MBR ext4 partition to minimum, patch MBR, truncate ---
        echo "Analyzing partition table..."
        BEST_OFFSET=0; BEST_START=0; BEST_TYPE=0; BEST_SLOT=-1
        for i in 0 1 2 3; do
            OFF=$((446 + i * 16))
            TYPE=$(dd if='\(imageFile)' bs=1 skip=$((OFF + 4)) count=1 2>/dev/null | od -An -tu1 | tr -d ' \\n')
            [ -z "$TYPE" ] && continue
            [ "$TYPE" -eq 0 ] && continue
            START=$(dd if='\(imageFile)' bs=1 skip=$((OFF + 8)) count=4 2>/dev/null | od -An -tu4 | tr -d ' \\n')
            if [ "$START" -gt "$BEST_START" ]; then
                BEST_START=$START; BEST_OFFSET=$OFF; BEST_TYPE=$TYPE; BEST_SLOT=$i
            fi
        done

        if [ "$BEST_SLOT" -lt 0 ]; then
            echo "No partitions in MBR; skipping shrink."
        elif [ "$BEST_TYPE" != "131" ]; then
            echo "Last partition not Linux ext4 (MBR type=$BEST_TYPE); skipping shrink."
        else
            echo "Attaching image as virtual disk..."
            ATTACH_OUT=$(hdiutil attach -nomount '\(imageFile)' 2>&1)
            echo "$ATTACH_OUT"
            # Find the ext4 partition node by matching the "Linux" type label in hdiutil output.
            ROOTFS_DEV=$(echo "$ATTACH_OUT" | awk '/Linux/ {print $1; exit}')
            DEV_DISK=$(echo "$ATTACH_OUT" | awk 'NR==1 {print $1}')
            if [ -z "$ROOTFS_DEV" ]; then
                echo "ERROR: hdiutil did not expose a Linux partition node. Aborting shrink."
                echo "Full hdiutil output above. Image left at full size."
                [ -n "$DEV_DISK" ] && hdiutil detach "$DEV_DISK" > /dev/null 2>&1 || true
            else
                echo "Rootfs partition node: $ROOTFS_DEV"

                # First fsck so resize2fs has a clean filesystem.
                echo "Running e2fsck on $ROOTFS_DEV..."
                if ! '\(DDService.e2fsckPath)' -fy "$ROOTFS_DEV"; then
                    echo "WARN: e2fsck returned non-zero (auto-corrected). Continuing."
                fi

                # Probe the minimum size resize2fs CAN achieve (counts only used blocks,
                # accounts for relocation). This is the true "data size" target.
                echo "Probing minimum filesystem size..."
                PROBE_OUT=$('\(DDService.resize2fsPath)' -P "$ROOTFS_DEV" 2>&1)
                echo "$PROBE_OUT"
                MIN_BLOCKS=$(echo "$PROBE_OUT" | grep -oE 'minimum size of the filesystem: [0-9]+' | grep -oE '[0-9]+$' | tail -1)

                RESIZE_OUT=""; RESIZE_STATUS=1
                if [ -n "$MIN_BLOCKS" ] && [ "$MIN_BLOCKS" -gt 0 ]; then
                    # Pad by 5% (min 4096 blocks ~= 16 MB at 4k) to avoid edge cases.
                    PAD=$((MIN_BLOCKS / 20))
                    [ $PAD -lt 4096 ] && PAD=4096
                    TARGET_BLOCKS=$((MIN_BLOCKS + PAD))
                    echo "Forcing shrink to $TARGET_BLOCKS blocks (probed min $MIN_BLOCKS + pad $PAD)."
                    echo "resize2fs will RELOCATE blocks as needed to hit this target."
                    RESIZE_OUT=$('\(DDService.resize2fsPath)' -f "$ROOTFS_DEV" "$TARGET_BLOCKS" 2>&1)
                    RESIZE_STATUS=$?
                    echo "$RESIZE_OUT"
                fi

                if [ "$RESIZE_STATUS" -ne 0 ]; then
                    echo "Forced shrink failed or unavailable. Falling back to resize2fs -M..."
                    '\(DDService.e2fsckPath)' -fy "$ROOTFS_DEV" || true
                    RESIZE_OUT=$('\(DDService.resize2fsPath)' -M "$ROOTFS_DEV" 2>&1)
                    RESIZE_STATUS=$?
                    echo "$RESIZE_OUT"
                fi

                hdiutil detach "$DEV_DISK" > /dev/null 2>&1 || true

                if [ "$RESIZE_STATUS" -ne 0 ]; then
                    echo "ERROR: resize2fs failed (exit $RESIZE_STATUS). Image left at full size."
                else
                    NEW_BLOCKS=$(echo "$RESIZE_OUT" | grep -oE 'is now [0-9]+' | tail -1 | awk '{print $3}')
                    BLOCK_KB=$(echo "$RESIZE_OUT" | grep -oE '\\([0-9]+k\\)' | tail -1 | tr -dc '0-9')

                    if [ -z "$NEW_BLOCKS" ] || [ -z "$BLOCK_KB" ]; then
                        echo "ERROR: Could not parse resize2fs output. Image left at full size."
                    else
                        NEW_SECTORS=$((NEW_BLOCKS * BLOCK_KB * 2))
                        echo "Shrunk to $NEW_SECTORS sectors ($NEW_BLOCKS ${BLOCK_KB}k blocks)."

                        B0=$((NEW_SECTORS & 0xFF))
                        B1=$(((NEW_SECTORS >> 8) & 0xFF))
                        B2=$(((NEW_SECTORS >> 16) & 0xFF))
                        B3=$(((NEW_SECTORS >> 24) & 0xFF))
                        printf "$(printf '\\\\x%02x\\\\x%02x\\\\x%02x\\\\x%02x' $B0 $B1 $B2 $B3)" \\
                            | dd of='\(imageFile)' bs=1 seek=$((BEST_OFFSET + 12)) count=4 conv=notrunc 2>/dev/null

                        OLD_FILE_BYTES=$(stat -f "%z" '\(imageFile)')
                        NEW_FILE_BYTES=$(( (BEST_START + NEW_SECTORS) * 512 ))
                        /usr/bin/truncate -s $NEW_FILE_BYTES '\(imageFile)'
                        echo "Image truncated: $((OLD_FILE_BYTES / 1024 / 1024)) MB -> $((NEW_FILE_BYTES / 1024 / 1024)) MB."
                    fi
                fi
            fi
        fi
        # --- End shrink ---
        """
    }

    // MARK: - Image to Disk

    func imageToDisk(sourcePath: String, target: DiskInfo, expandRootfs: Bool) async {
        let decompress = sourcePath.hasSuffix(".gz")
        let ddLine: String
        if decompress {
            ddLine = "'\(DDService.pigzPath)' -d -c '\(sourcePath)' | dd of=\(target.rawDevicePath) bs=16m status=progress"
        } else {
            ddLine = "dd if='\(sourcePath)' of=\(target.rawDevicePath) bs=16m status=progress"
        }
        let expandSection = expandRootfs ? expandRootfsScript(target: target) : ""
        let script = """
        #!/bin/bash
        set -o pipefail
        diskutil unmountDisk \(target.devicePath) > /dev/null 2>&1
        \(ddLine)
        DD_STATUS=$?
        if [ $DD_STATUS -ne 0 ]; then exit $DD_STATUS; fi
        \(expandSection)
        """
        await runOperation(totalSize: target.sizeBytes, script: script)
    }

    private func expandRootfsScript(target: DiskInfo) -> String {
        return """

        # --- Expand last MBR partition to fill disk + resize2fs ---
        echo "Expanding rootfs to fill disk..."
        diskutil unmountDisk force \(target.devicePath) > /dev/null 2>&1 || true

        TOTAL_BYTES=$(diskutil info -plist \(target.devicePath) | plutil -extract Size raw - 2>/dev/null || echo 0)
        if [ "$TOTAL_BYTES" -eq 0 ]; then
            echo "Could not determine disk size; skipping expand."
        else
            TOTAL_SECTORS=$((TOTAL_BYTES / 512))
            # Raw char device only supports sector-aligned reads — copy MBR to temp file first.
            MBR_TMP=$(mktemp /tmp/clonetool-mbr.XXXXXX)
            dd if=\(target.rawDevicePath) of="$MBR_TMP" bs=512 count=1 2>/dev/null
            BEST_OFFSET=0; BEST_START=0; BEST_TYPE=0; BEST_SLOT=-1
            for i in 0 1 2 3; do
                OFF=$((446 + i * 16))
                TYPE=$(od -An -j$((OFF + 4)) -N1 -tu1 "$MBR_TMP" | tr -d ' \\n')
                [ -z "$TYPE" ] && continue
                [ "$TYPE" -eq 0 ] && continue
                START=$(od -An -j$((OFF + 8)) -N4 -tu4 "$MBR_TMP" | tr -d ' \\n')
                if [ "$START" -gt "$BEST_START" ]; then
                    BEST_START=$START; BEST_OFFSET=$OFF; BEST_TYPE=$TYPE; BEST_SLOT=$i
                fi
            done

            if [ "$BEST_SLOT" -lt 0 ]; then
                echo "No MBR partition found; skipping expand."
            elif [ "$BEST_TYPE" != "131" ]; then
                echo "Last partition is not Linux ext4 (MBR type=$BEST_TYPE); skipping expand."
            else
                NEW_SIZE=$((TOTAL_SECTORS - BEST_START))
                if [ "$NEW_SIZE" -le 0 ]; then
                    echo "Computed invalid partition size; skipping expand."
                else
                    echo "Growing partition slot $BEST_SLOT: start=$BEST_START sectors, new size=$NEW_SIZE sectors"
                    # Patch new sector count into the in-memory MBR, then write the whole sector back.
                    B0=$((NEW_SIZE & 0xFF))
                    B1=$(((NEW_SIZE >> 8) & 0xFF))
                    B2=$(((NEW_SIZE >> 16) & 0xFF))
                    B3=$(((NEW_SIZE >> 24) & 0xFF))
                    printf "$(printf '\\\\x%02x\\\\x%02x\\\\x%02x\\\\x%02x' $B0 $B1 $B2 $B3)" \\
                        | dd of="$MBR_TMP" bs=1 seek=$((BEST_OFFSET + 12)) count=4 conv=notrunc 2>/dev/null
                    dd if="$MBR_TMP" of=\(target.rawDevicePath) bs=512 count=1 conv=notrunc 2>/dev/null
                    sync

                    PART_NUM=$((BEST_SLOT + 1))
                    echo "Partition table grown to fill disk."
                    echo "Filesystem will be resized on first Linux boot (Pi OS / cloud-init do this automatically)."
                    echo "If your image doesn't auto-resize, run on the target: sudo resize2fs /dev/mmcblk0p${PART_NUM}"
                    # macOS can't re-read the partition table after writing it, so the kernel
                    # still reports the old size for the partition node — running e2fsck or
                    # resize2fs here would corrupt the filesystem. Linux will handle it on boot.
                fi
            fi
            rm -f "$MBR_TMP"
        fi
        # --- End expand ---
        """
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
