import SwiftUI
import UniformTypeIdentifiers

/// Vulnerabilities and packages for one image. Nothing downloads until a button is pressed.
struct ImageSecurityTab: View {
    let env: AppEnvironment
    let image: ImageSummary
    private var store: SecurityStore { env.security }
    @State private var confirmScan = false
    @State private var confirmSBOM = false
    @State private var confirmClear = false
    @State private var exporting = false
    @State private var exportDocument: SBOMExport?
    @State private var exportError: String?
    @State private var history: [ScanHistoryEntry] = []
    @State private var historyError: String?
    @State private var selectedScan: UUID?

    private var report: ScanReport? {
        (history.first { $0.id == selectedScan } ?? history.first)?.result
    }
    private var sbom: SecurityStore.SBOMResult? { store.sbom?.imageID == image.id ? store.sbom : nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let error = exportError ?? store.error(for: image.id) ?? historyError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                vulnerabilities
                Divider()
                packages
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let notice = store.notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                    Button("Clear Scan Database…") { confirmClear = true }.disabled(store.busy)
                        .help("Removes the downloaded vulnerability database. Saved results are kept.")
                }
            }.padding(Space.panel).frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: store.historyVersion) {
            await loadHistory()
            if env.demo, sbom == nil, !Task.isCancelled {
                await store.generateSBOM(imageID: image.id, demo: true)
            }
        }
        .alert("Download scanner and database?", isPresented: $confirmScan) {
            Button("Continue", action: scan)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The first scan downloads a scanner and a vulnerability database that uses about 3.2 GB on disk. This can take several minutes. Clear Scan Database removes it again.")
        }
        .alert("Download the package lister?", isPresented: $confirmSBOM) {
            Button("Continue", action: listPackages)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Listing packages may download the Syft first.") }
        .alert("Clear the scan database?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { Task { await store.clearCache(demo: env.demo) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The next scan downloads the database again. Saved results are kept.") }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentType: .json, defaultFilename: "sbom.json") { result in
            exportDocument = nil
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .motion(Motion.standard, value: store.busy)
    }

    private func loadHistory() async {
        do {
            let entries = try await SecurityStore.history(for: image.id, demo: env.demo)
            guard !Task.isCancelled else { return }
            history = entries
            selectedScan = nil
            historyError = nil
        } catch {
            if !Task.isCancelled { historyError = error.localizedDescription }
        }
    }

    private func scan() {
        exportError = nil
        Task { await store.scan(imageID: image.id, demo: env.demo) }
    }

    private func listPackages() {
        exportError = nil
        Task { await store.generateSBOM(imageID: image.id, demo: env.demo) }
    }

    @ViewBuilder private var vulnerabilities: some View {
        if report == nil || store.notice != nil {
            Text("Scans run on this Mac. The first scan downloads a database that uses about 3.2 GB on disk.")
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            Text("Vulnerabilities").font(.headline)
            Spacer()
            if store.busy, store.operationImageID == image.id { ProgressView().controlSize(.small) }
            Button(report == nil ? "Scan" : "Scan Again") {
                if env.demo || store.scanApproved { scan() } else { confirmScan = true }
            }.disabled(store.busy)
        }
        if history.count > 1 {
            Picker("Scan history", selection: $selectedScan) {
                Text("Latest scan").tag(nil as UUID?)
                ForEach(history.dropFirst()) { entry in
                    Text(entry.created).tag(Optional(entry.id))
                }
            }
        }
        if let report {
            if report.matches.isEmpty {
                Text("No known vulnerabilities found.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(ScanReport.severities.filter { report.count($0) > 0 }, id: \.self) { severity in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(report.count(severity))").font(.title3.weight(.semibold).monospacedDigit())
                            Text(severity).font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                    }
                }
                ForEach(report.sorted) { match in
                    let fixes = match.vulnerability.fix?.versions ?? []
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(match.vulnerability.id).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(match.vulnerability.severity).font(.caption.weight(.semibold))
                                .foregroundStyle(ScanReport.rank(match.vulnerability.severity) < 2 ? Status.error : .secondary)
                        }
                        Text("\(match.artifact.name) \(match.artifact.version ?? "")").font(.callout)
                        Text(fixes.isEmpty ? "No fix listed" : "Fixed in \(fixes.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
            }
        } else {
            Text("Not scanned yet.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var packages: some View {
        HStack {
            Text("Packages").font(.headline)
            Spacer()
            if let sbom {
                Button("Export", systemImage: "square.and.arrow.up") {
                    exportError = nil
                    exportDocument = SBOMExport(data: sbom.data)
                    exporting = true
                }.disabled(store.busy).help("Save the list as CycloneDX JSON")
            } else {
                Button("List Packages") {
                    if env.demo || store.sbomApproved { listPackages() } else { confirmSBOM = true }
                }.disabled(store.busy)
            }
        }
        if let sbom = sbom?.document {
            Text(sbom.components.isEmpty ? "No packages found." : "\(sbom.components.count) packages").foregroundStyle(.secondary)
            ForEach(sbom.components) { component in
                HStack(alignment: .firstTextBaseline) {
                    Text(component.name).font(.callout).textSelection(.enabled)
                    Spacer()
                    Text(component.version ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }.help(component.purl ?? component.name)
            }
        } else {
            Text("The software bill of materials: every package in the image.").foregroundStyle(.secondary)
        }
    }
}

private struct SBOMExport: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
