import SwiftUI

struct ContentView: View {
    @State private var viewModel = CloneViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Schema
            Text("Schema").font(.headline)
            Picker("Schema", selection: $viewModel.schema) {
                ForEach(OperationSchema.allCases) { schema in
                    Text(schema.rawValue).tag(schema)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Source / Target
            HStack(alignment: .top, spacing: 24) {
                sourceSection
                targetSection
            }

            // Status
            Text("Status").font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.ddService.statusLog)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("log")
                }
                .frame(height: 200)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: viewModel.ddService.statusLog) {
                    proxy.scrollTo("log", anchor: .bottom)
                }
            }

            // Progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: viewModel.ddService.progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.3), value: viewModel.ddService.progress)

                HStack {
                    Text(String(format: "%.2f%%", viewModel.ddService.progress * 100))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    if !viewModel.ddService.speed.isEmpty {
                        Text(viewModel.ddService.speed)
                            .font(.system(.body, design: .monospaced))
                    }
                    if viewModel.ddService.bytesTransferred > 0 {
                        let transferred = ByteCountFormatter.string(
                            fromByteCount: Int64(viewModel.ddService.bytesTransferred),
                            countStyle: .file
                        )
                        let total = ByteCountFormatter.string(
                            fromByteCount: Int64(viewModel.ddService.totalSize),
                            countStyle: .file
                        )
                        Text("\(transferred) / \(total)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }

            // Image Path + Actions
            HStack {
                if viewModel.schema == .diskToImage {
                    VStack(alignment: .leading) {
                        Text("Output Path:").font(.caption)
                        Text(viewModel.imagePath.isEmpty ? viewModel.defaultImageDirectory.path : viewModel.imagePath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if viewModel.state == .running {
                    Button("Cancel") {
                        viewModel.cancelClone()
                    }
                    .tint(.red)
                } else {
                    if viewModel.ddService.needsFullDiskAccess {
                        Button("Grant Full Disk Access...") {
                            viewModel.ddService.openFullDiskAccessSettings()
                        }
                        .tint(.orange)
                        .buttonStyle(.borderedProminent)
                    }

                    Button("Refresh Disks") {
                        Task { await viewModel.refreshDisks() }
                    }

                    Button("Clone") {
                        viewModel.showConfirmation = true
                    }
                    .disabled(!viewModel.canStart)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .padding(.bottom, 10)
        .frame(width: 620, height: 540)
        .task {
            viewModel.ddService.registerHelper()
            await viewModel.refreshDisks()
        }
        .alert("Confirm Operation", isPresented: $viewModel.showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Proceed", role: .destructive) {
                Task { await viewModel.startClone() }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    // MARK: - Source Section

    @ViewBuilder
    private var sourceSection: some View {
        VStack(alignment: .leading) {
            Text("Source").font(.headline)
            switch viewModel.schema {
            case .diskToImage, .diskToDisk:
                Picker("Source", selection: $viewModel.selectedSourceId) {
                    Text("Select Disk...").tag(nil as String?)
                    ForEach(viewModel.sourceDisks) { disk in
                        Text(disk.displayName).tag(disk.id as String?)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 250)
            case .imageToDisk:
                HStack {
                    TextField("Image file path", text: $viewModel.imagePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        viewModel.browseForImage()
                    }
                }
                .frame(minWidth: 250)
            }
        }
    }

    // MARK: - Target Section

    @ViewBuilder
    private var targetSection: some View {
        VStack(alignment: .leading) {
            Text("Target").font(.headline)
            switch viewModel.schema {
            case .diskToImage:
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $viewModel.imageName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Version", text: $viewModel.imageVersion)
                        .textFieldStyle(.roundedBorder)
                    Text(viewModel.generatedFileName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 250)
            case .imageToDisk, .diskToDisk:
                Picker("Target", selection: $viewModel.selectedTargetId) {
                    Text("Select Disk...").tag(nil as String?)
                    ForEach(viewModel.targetDisks) { disk in
                        Text(disk.displayName).tag(disk.id as String?)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 250)
            }
        }
    }

    // MARK: - Confirmation Message

    private var confirmationMessage: String {
        switch viewModel.schema {
        case .diskToImage:
            let src = viewModel.sourceDisk?.displayName ?? "?"
            return "Create image from \(src)?\nThis will read the entire disk."
        case .imageToDisk:
            let tgt = viewModel.targetDisk?.displayName ?? "?"
            return "Write image to \(tgt)?\nALL DATA on the target will be DESTROYED."
        case .diskToDisk:
            let src = viewModel.sourceDisk?.displayName ?? "?"
            let tgt = viewModel.targetDisk?.displayName ?? "?"
            return "Clone \(src) to \(tgt)?\nALL DATA on the target will be DESTROYED."
        }
    }
}
