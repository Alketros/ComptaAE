import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum ExportPeriodKind: String, CaseIterable, Identifiable {
    case year = "Année", quarter = "Trimestre", month = "Mois"
    var id: String { rawValue }
}

struct ExportView: View {
    @Environment(\.modelContext) private var context
    @Environment(SettingsStore.self) private var settings
    @Query private var sales: [Sale]
    @Query private var purchases: [Purchase]

    @State private var year = Fiscal.currentYear()
    @State private var kind: ExportPeriodKind = .year
    @State private var quarter = (Fmt.calendar.component(.month, from: Date()) - 1) / 3 + 1
    @State private var month = Fmt.calendar.component(.month, from: Date())
    @State private var shareItem: ShareItem?
    @State private var working = false
    @State private var message: String?
    @State private var showRestore = false

    private var scope: ExportScope {
        switch kind {
        case .year: return .year(year)
        case .quarter: return .quarter(year, quarter)
        case .month: return .month(year, month)
        }
    }

    private var preview: Summary {
        Summary.compute(sales: sales, purchases: purchases, in: scope.interval, settings: settings.s)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Période") {
                    Picker("Type", selection: $kind) {
                        ForEach(ExportPeriodKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Année", selection: $year) {
                        ForEach((Fiscal.currentYear() - 6...Fiscal.currentYear()).reversed(), id: \.self) { Text(String($0)).tag($0) }
                    }
                    if kind == .quarter {
                        Picker("Trimestre", selection: $quarter) {
                            ForEach(1...4, id: \.self) { Text("T\($0)").tag($0) }
                        }
                    }
                    if kind == .month {
                        Picker("Mois", selection: $month) {
                            ForEach(1...12, id: \.self) { m in
                                Text(Fmt.calendar.monthSymbols[m - 1].capitalizedFirst).tag(m)
                            }
                        }
                    }
                }

                Section("Contenu") {
                    LabeledContent("Recettes encaissées", value: "\(preview.salesCount) — \(Fmt.eur(preview.ca))")
                    LabeledContent("Achats", value: "\(preview.purchasesCount) — \(Fmt.eur(preview.purchases))")
                    if preview.pendingCount > 0 {
                        LabeledContent("Factures non encaissées", value: "\(preview.pendingCount)")
                    }
                }

                Section {
                    Button { run { try Exporter.dossier(sales: sales, purchases: purchases, scope: scope, settings: settings.s) } } label: {
                        Label("Dossier complet (.zip)", systemImage: "archivebox.fill")
                    }
                    Button { run { try Exporter.pdf(sales: sales, purchases: purchases, scope: scope, settings: settings.s) } } label: {
                        Label("Registre PDF", systemImage: "doc.richtext.fill")
                    }
                    Button { run { try Exporter.xlsx(sales: sales, purchases: purchases, scope: scope, settings: settings.s) } } label: {
                        Label("Tableur Excel (.xlsx)", systemImage: "tablecells.fill")
                    }
                } header: {
                    Text("Exporter")
                } footer: {
                    Text("En cas de contrôle, envoyez le dossier complet : il contient le livre des recettes et le registre des achats en PDF (lisible, non modifiable) et en Excel (exploitable), ainsi que tous les justificatifs renommés par date.")
                }

                Section {
                    Button { run { try Exporter.backup(sales: sales, purchases: purchases, settings: settings.s) } } label: {
                        Label("Créer une sauvegarde", systemImage: "externaldrive.fill.badge.plus")
                    }
                    Button { showRestore = true } label: {
                        Label("Restaurer une sauvegarde", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Sauvegarde")
                } footer: {
                    Text("Enregistrez régulièrement une sauvegarde dans iCloud Drive (via « Enregistrer dans Fichiers »). La restauration ajoute les écritures manquantes sans écraser les existantes.")
                }
            }
            .navigationTitle("Export")
            .disabled(working)
            .overlay { if working { ProgressView().controlSize(.large) } }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url]).ignoresSafeArea()
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.zip]) { result in
                guard case .success(let url) = result else { return }
                do {
                    let r = try Exporter.restore(from: url, context: context, settingsStore: settings)
                    message = "Restauration terminée : \(r.sales) vente(s) et \(r.purchases) achat(s) ajoutés."
                } catch {
                    message = error.localizedDescription
                }
            }
            .alert("Compta AE", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private func run(_ job: @escaping () throws -> URL) {
        working = true
        // Laisse l'indicateur s'afficher avant le calcul
        DispatchQueue.main.async {
            do {
                shareItem = ShareItem(url: try job())
            } catch {
                message = error.localizedDescription
            }
            working = false
        }
    }
}
