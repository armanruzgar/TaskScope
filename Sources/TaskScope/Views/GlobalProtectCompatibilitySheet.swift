import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GlobalProtectCompatibilityButton: View {
    let keepOffRequested: Bool?
    @State private var isPresented = false

    var body: some View {
        Button("Compatibility Self-Check", systemImage: "checklist") {
            isPresented = true
        }
        .help("Read-only GlobalProtect status with a redacted support summary.")
        .sheet(isPresented: $isPresented) {
            GlobalProtectCompatibilitySheet(keepOffRequested: keepOffRequested) {
                isPresented = false
            }
        }
    }
}

struct GlobalProtectCompatibilitySheet: View {
    let keepOffRequested: Bool?
    let onClose: () -> Void
    var checker = GlobalProtectCompatibilityChecker()
    @State var report: GlobalProtectCompatibilityReport?
    @State private var refreshGeneration = 0
    @State private var isExporting = false
    @State private var shareMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GlobalProtect Compatibility")
                .font(.title2.bold())
            Text("Read-only self-check. Preview the exact redacted text that Copy and Export will share.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let report {
                ScrollView {
                    Text(report.redactedSummary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView("Reading local compatibility state…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let shareMessage {
                Text(shareMessage).font(.caption).accessibilityAddTraits(.updatesFrequently)
            }
            HStack {
                Button("Refresh") {
                    report = nil
                    shareMessage = nil
                    refreshGeneration += 1
                }
                .disabled(report == nil)
                Button("Copy Summary") {
                    guard let report else { return }
                    shareMessage = GlobalProtectCompatibilityDocument(report: report).copy(to: .general)
                        ? "Redacted summary copied." : "Could not copy the summary."
                }
                .disabled(report == nil)
                Button("Export…") { isExporting = true }
                    .disabled(report == nil)
                Spacer()
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 540)
        // A read-only report: Escape closes it as Return does.
        .onExitCommand(perform: onClose)
        .task(id: refreshGeneration) {
            let result = await checker.check(keepOffRequested: keepOffRequested)
            guard !Task.isCancelled else { return }
            report = result
        }
        .fileExporter(
            isPresented: $isExporting,
            document: report.map { GlobalProtectCompatibilityDocument(report: $0) },
            contentType: .plainText,
            defaultFilename: "TaskScope-GlobalProtect-compatibility.txt"
        ) { result in
            switch result {
            case .success: shareMessage = "Redacted summary exported."
            case .failure: shareMessage = "Could not export the summary. Try another location."
            }
        }
    }
}

struct GlobalProtectCompatibilityDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String

    init(report: GlobalProtectCompatibilityReport) {
        text = report.redactedSummary
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: utf8Data)
    }

    var utf8Data: Data { Data(text.utf8) }

    @MainActor
    func copy(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
