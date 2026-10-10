#if os(macOS)
import SwiftUI
import SupersEmuKit

/// Add Games: drop or pick files, folders and .zip archives; they're uploaded into Incoming and scanned.
struct LibraryImportView: View {
    let model: LibraryManagerModel
    var onReview: () -> Void

    var body: some View {
        Form {
            Section {
                DropZone(title: "Drop games, folders or .zip files anywhere in this window",
                         subtitle: "They're copied to the server, sorted by console, and checked for duplicates.",
                         systemImage: "square.and.arrow.down.on.square")
                HStack {
                    Button("Add Games…") { model.chooseAndImport() }.disabled(!model.canImport)
                    Button("Scan Incoming") { Task { await model.scan() } }.disabled(!model.canImport)
                    if model.server.isLocal {
                        Button("Open Incoming Folder") { model.openIncoming() }.disabled(model.storage == nil)
                    }
                }
                if model.server.isLocal {
                    Text("Files you copy into the Incoming folder yourself are imported when you press Scan Incoming.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let progress = model.progress { progressSection(progress) }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if let report = model.report { summary(report) }
        }
        .formStyle(.grouped)
        .navigationTitle("Add Games")
        .task { await model.refreshStorage() }
    }

    private func progressSection(_ progress: LibraryManagerModel.ImportProgress) -> some View {
        Section("Importing") {
            if progress.scanning {
                ProgressView { Text("Sorting and checking files on the server…") }
            } else {
                ProgressView(value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1))) {
                    Text("Uploading \(min(progress.filesDone + 1, progress.filesTotal)) of \(progress.filesTotal): \(progress.current)")
                        .lineLimit(1).truncationMode(.middle)
                } currentValueLabel: {
                    Text("\(Self.bytes(progress.bytesDone)) of \(Self.bytes(progress.bytesTotal))")
                }
            }
        }
    }

    private func summary(_ report: ImportReport) -> some View {
        Section("Result") {
            HStack(spacing: 24) {
                count(report.imported.count, "Imported", "checkmark.circle.fill", .green)
                count(report.duplicates, "Duplicates", "doc.on.doc", .secondary)
                count(report.needsReview.count, "Review needed", "exclamationmark.bubble.fill", .orange)
                count(report.unsupported.count, "Unsupported", "nosign", .red)
                if let bios = report.bios, !bios.isEmpty { count(bios.count, "BIOS", "cpu", .blue) }
            }
            .padding(.vertical, 4)
            if !report.imported.isEmpty {
                DisclosureGroup("Imported games") {
                    ForEach(report.imported) { game in
                        LabeledContent(game.title, value: game.system.displayName)
                    }
                }
            }
            if !report.unsupported.isEmpty {
                DisclosureGroup("Unsupported") {
                    ForEach(report.unsupported, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                }
            }
            if !report.needsReview.isEmpty || !report.unsupported.isEmpty {
                Button("Open Review Needed") { onReview() }
            }
        }
    }

    private func count(_ value: Int, _ label: String, _ image: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Label("\(value)", systemImage: image).font(.title2.weight(.semibold)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

struct DropZone: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.headline).multilineTextAlignment(.center)
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7])).foregroundStyle(.tertiary))
    }
}
#endif
