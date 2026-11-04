import Foundation
import SwiftData
import UIKit

struct ExportScope {
    var interval: DateInterval
    var title: String
    var fileStem: String

    static func year(_ y: Int) -> ExportScope {
        ExportScope(interval: Fiscal.yearInterval(y), title: "Année \(y)", fileStem: "\(y)")
    }

    static func quarter(_ y: Int, _ q: Int) -> ExportScope {
        ExportScope(interval: Fiscal.quarterInterval(year: y, quarter: q),
                    title: "\(q == 1 ? "1er" : "\(q)e") trimestre \(y)", fileStem: "\(y)-T\(q)")
    }

    static func month(_ y: Int, _ m: Int) -> ExportScope {
        let start = Fmt.calendar.date(from: DateComponents(year: y, month: m, day: 1)) ?? Date()
        let iv = Fiscal.monthInterval(containing: start)
        return ExportScope(interval: iv, title: Fmt.monthYear.string(from: start).capitalizedFirst,
                           fileStem: String(format: "%04ld-%02ld", y, m))
    }
}

enum ExportError: LocalizedError {
    case invalidBackup
    var errorDescription: String? { "Ce fichier n'est pas une sauvegarde Compta AE valide." }
}

enum Exporter {

    // MARK: Données filtrées

    struct Dataset {
        let receipts: [Sale]     // encaissées sur la période
        let pending: [Sale]      // facturées sur la période, non encaissées
        let purchases: [Purchase]
        let summary: Summary
        let attachmentPaths: [String: String]   // nom interne → chemin dans l'export
    }

    static func dataset(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) -> Dataset {
        let iv = scope.interval
        let receipts = sales.filter { s in
            guard let p = s.paymentDate else { return false }
            return iv.start <= p && p < iv.end
        }.sorted { ($0.paymentDate ?? $0.invoiceDate) < ($1.paymentDate ?? $1.invoiceDate) }
        let pending = sales.filter { $0.paymentDate == nil && iv.start <= $0.invoiceDate && $0.invoiceDate < iv.end }
            .sorted { $0.invoiceDate < $1.invoiceDate }
        let buys = purchases.filter { iv.start <= $0.date && $0.date < iv.end }.sorted { $0.date < $1.date }
        let summary = Summary.compute(sales: sales, purchases: purchases, in: iv, settings: settings)

        var paths: [String: String] = [:]
        var used = Set<String>()
        func register(_ name: String?, folder: String, date: Date, party: String, ref: String) {
            guard let name, AttachmentStore.exists(name) else { return }
            var base = "\(Fmt.isoDay.string(from: date))_\(sanitize(party))"
            if !ref.isEmpty { base += "_\(sanitize(ref))" }
            let ext = (name as NSString).pathExtension.isEmpty ? "pdf" : (name as NSString).pathExtension
            var candidate = "\(folder)/\(base).\(ext)"
            var n = 2
            while used.contains(candidate) { candidate = "\(folder)/\(base)_\(n).\(ext)"; n += 1 }
            used.insert(candidate)
            paths[name] = candidate
        }
        for s in receipts + pending { register(s.attachmentName, folder: "Ventes", date: s.invoiceDate, party: s.client, ref: s.invoiceNumber) }
        for p in buys { register(p.attachmentName, folder: "Achats", date: p.date, party: p.supplier, ref: p.invoiceNumber) }
        return Dataset(receipts: receipts, pending: pending, purchases: buys, summary: summary, attachmentPaths: paths)
    }

    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let folded = s.folding(options: .diacriticInsensitive, locale: Fmt.fr)
        let mapped = folded.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = mapped.split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(40)).isEmpty ? "document" : String(collapsed.prefix(40))
    }

    private static func monthlyRows(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) -> [(String, Summary)] {
        var rows: [(String, Summary)] = []
        var cursor = scope.interval.start
        while cursor < scope.interval.end {
            let iv = Fiscal.monthInterval(containing: cursor)
            rows.append((Fmt.monthYear.string(from: cursor).capitalizedFirst,
                         Summary.compute(sales: sales, purchases: purchases, in: iv, settings: settings)))
            cursor = iv.end
        }
        return rows
    }

    private static func outputURL(_ filename: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private static func stem(_ settings: AppSettings) -> String {
        settings.businessName.isEmpty ? "Compta" : "Compta_\(sanitize(settings.businessName))"
    }

    // MARK: Excel

    static func xlsxData(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) -> Data {
        let ds = dataset(sales: sales, purchases: purchases, scope: scope, settings: settings)
        let methodLabel: (PaymentMethod) -> String = { $0.label }

        // Récapitulatif
        var recap: [[XLSXCell]] = [
            [.bold("Registre comptable — \(scope.title)")],
            [.text("Entreprise"), .text(settings.businessName)],
            [.text("Exploitant"), .text(settings.ownerName)],
            [.text("SIRET"), .text(settings.siret)],
            [.text("Adresse"), .text(settings.address)],
            [.text("Régime"), .text("Micro-entreprise — franchise en base de TVA")],
            [.text("Généré le"), .date(Date())],
            [],
            [.header("Mois"), .header("Ventes marchandises"), .header("Services BIC"), .header("Libéral BNC"),
             .header("Libéral CIPAV"), .header("Total CA encaissé"), .header("Achats"), .header("Cotisations estimées")]
        ]
        let months = monthlyRows(sales: sales, purchases: purchases, scope: scope, settings: settings)
        let firstDataRow = recap.count + 1
        for (label, s) in months {
            recap.append([.text(label),
                          .money(s.caByCategory[.venteMarchandises] ?? 0),
                          .money(s.caByCategory[.prestationBIC] ?? 0),
                          .money(s.caByCategory[.prestationBNC] ?? 0),
                          .money(s.caByCategory[.liberalCIPAV] ?? 0),
                          .money(s.ca), .money(s.purchases), .money(s.urssafTotal)])
        }
        let lastDataRow = recap.count
        let t = ds.summary
        recap.append([.bold("TOTAL"),
                      .sum(column: 1, fromRow: firstDataRow, toRow: lastDataRow, cached: t.caByCategory[.venteMarchandises] ?? 0),
                      .sum(column: 2, fromRow: firstDataRow, toRow: lastDataRow, cached: t.caByCategory[.prestationBIC] ?? 0),
                      .sum(column: 3, fromRow: firstDataRow, toRow: lastDataRow, cached: t.caByCategory[.prestationBNC] ?? 0),
                      .sum(column: 4, fromRow: firstDataRow, toRow: lastDataRow, cached: t.caByCategory[.liberalCIPAV] ?? 0),
                      .sum(column: 5, fromRow: firstDataRow, toRow: lastDataRow, cached: t.ca),
                      .sum(column: 6, fromRow: firstDataRow, toRow: lastDataRow, cached: t.purchases),
                      .sum(column: 7, fromRow: firstDataRow, toRow: lastDataRow, cached: t.urssafTotal)])
        recap.append([])
        recap.append([.text("Les cotisations sont des estimations calculées avec les taux paramétrés dans l'application.")])

        // Livre des recettes
        var receipts: [[XLSXCell]] = [[
            .header("Date d'encaissement"), .header("N° facture"), .header("Date facture"), .header("Client"),
            .header("Nature de la prestation / vente"), .header("Catégorie"), .header("Mode de règlement"),
            .header("Montant encaissé"), .header("Justificatif")
        ]]
        for s in ds.receipts {
            receipts.append([.date(s.paymentDate ?? s.invoiceDate), .text(s.invoiceNumber), .date(s.invoiceDate),
                             .text(s.client), .text(s.label), .text(s.category.shortLabel),
                             .text(methodLabel(s.paymentMethod)), .money(s.amount),
                             .text(s.attachmentName.flatMap { ds.attachmentPaths[$0] } ?? "")])
        }
        receipts.append([.bold("TOTAL"), .empty, .empty, .empty, .empty, .empty, .empty,
                         .sum(column: 7, fromRow: 2, toRow: receipts.count, cached: ds.summary.ca)])

        var sheets = [
            XLSXSheet(name: "Récapitulatif", widths: [22, 18, 16, 16, 16, 18, 14, 20], rows: recap, freezeHeader: false),
            XLSXSheet(name: "Livre des recettes", widths: [16, 14, 13, 26, 36, 14, 18, 16, 40], rows: receipts)
        ]

        if !ds.pending.isEmpty {
            var pending: [[XLSXCell]] = [[.header("Date facture"), .header("N° facture"), .header("Client"),
                                          .header("Nature"), .header("Montant"), .header("Justificatif")]]
            for s in ds.pending {
                pending.append([.date(s.invoiceDate), .text(s.invoiceNumber), .text(s.client), .text(s.label),
                                .money(s.amount), .text(s.attachmentName.flatMap { ds.attachmentPaths[$0] } ?? "")])
            }
            pending.append([.bold("TOTAL"), .empty, .empty, .empty,
                            .sum(column: 4, fromRow: 2, toRow: pending.count, cached: ds.pending.map(\.amount).reduce(0, +))])
            sheets.append(XLSXSheet(name: "Factures non encaissées", widths: [13, 14, 26, 36, 14, 40], rows: pending))
        }

        var buys: [[XLSXCell]] = [[
            .header("Date"), .header("N° pièce"), .header("Fournisseur"), .header("Nature de l'achat"),
            .header("Catégorie"), .header("Mode de règlement"), .header("Montant TTC"), .header("Dont TVA"), .header("Justificatif")
        ]]
        for p in ds.purchases {
            buys.append([.date(p.date), .text(p.invoiceNumber), .text(p.supplier), .text(p.label),
                         .text(p.category.label), .text(methodLabel(p.paymentMethod)), .money(p.amount), .money(p.vatAmount),
                         .text(p.attachmentName.flatMap { ds.attachmentPaths[$0] } ?? "")])
        }
        let lastBuy = buys.count
        buys.append([.bold("TOTAL"), .empty, .empty, .empty, .empty, .empty,
                     .sum(column: 6, fromRow: 2, toRow: lastBuy, cached: ds.summary.purchases),
                     .sum(column: 7, fromRow: 2, toRow: lastBuy, cached: ds.purchases.map(\.vatAmount).reduce(0, +))])
        sheets.append(XLSXSheet(name: "Registre des achats", widths: [12, 14, 26, 36, 26, 18, 14, 12, 40], rows: buys))

        return XLSXWriter.data(sheets: sheets)
    }

    static func xlsx(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) throws -> URL {
        let url = try outputURL("\(stem(settings))_\(scope.fileStem).xlsx")
        try xlsxData(sales: sales, purchases: purchases, scope: scope, settings: settings).write(to: url)
        return url
    }

    // MARK: PDF

    static func pdfData(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) -> Data {
        let ds = dataset(sales: sales, purchases: purchases, scope: scope, settings: settings)
        let footer = "\(settings.businessName.isEmpty ? "Registre comptable" : settings.businessName) — \(scope.title) — édité le \(Fmt.day.string(from: Date()))"
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 595))
        return renderer.pdfData { ctx in
            let pdf = PDFLayout(context: ctx, footer: footer)
            pdf.title("Registre comptable — \(scope.title)", size: 20)
            var ident: [String] = []
            if !settings.businessName.isEmpty { ident.append(settings.businessName) }
            if !settings.ownerName.isEmpty { ident.append(settings.ownerName) }
            if !settings.siret.isEmpty { ident.append("SIRET : \(settings.siret)") }
            if !settings.address.isEmpty { ident.append(settings.address) }
            ident.append("Micro-entreprise — TVA non applicable, art. 293 B du CGI (franchise en base)")
            pdf.text(ident.joined(separator: "\n"), size: 10)
            pdf.space(8)

            pdf.title("Synthèse", size: 14)
            var pairs: [(String, String)] = []
            for c in ActivityCategory.allCases {
                if let v = ds.summary.caByCategory[c], v > 0 { pairs.append(("CA encaissé — \(c.label)", Fmt.eur(v))) }
            }
            pairs.append(("Chiffre d'affaires encaissé total", Fmt.eur(ds.summary.ca)))
            pairs.append(("Achats", Fmt.eur(ds.summary.purchases)))
            pairs.append(("Cotisations et contributions estimées", Fmt.eur(ds.summary.urssafTotal)))
            if ds.summary.pendingCount > 0 {
                pairs.append(("Factures non encaissées (\(ds.summary.pendingCount))", Fmt.eur(ds.summary.pendingAmount)))
            }
            pdf.keyValues(pairs)
            pdf.space(12)

            pdf.title("Livre des recettes", size: 14)
            pdf.table([
                .init(title: "Encaissement", weight: 9),
                .init(title: "N° facture", weight: 9),
                .init(title: "Client", weight: 17),
                .init(title: "Nature", weight: 24),
                .init(title: "Catégorie", weight: 9),
                .init(title: "Règlement", weight: 10),
                .init(title: "Montant", weight: 10, align: .right),
                .init(title: "Justif.", weight: 5, align: .center)
            ], rows: ds.receipts.map { s in
                [Fmt.day.string(from: s.paymentDate ?? s.invoiceDate), s.invoiceNumber, s.client, s.label,
                 s.category.shortLabel, s.paymentMethod.label, Fmt.eur(s.amount), s.attachmentName == nil ? "—" : "oui"]
            }, total: ["TOTAL", "", "", "", "", "", Fmt.eur(ds.summary.ca), ""])

            if !ds.pending.isEmpty {
                pdf.title("Factures émises non encaissées (pour information)", size: 12)
                pdf.table([
                    .init(title: "Date facture", weight: 10),
                    .init(title: "N° facture", weight: 10),
                    .init(title: "Client", weight: 22),
                    .init(title: "Nature", weight: 34),
                    .init(title: "Montant", weight: 12, align: .right)
                ], rows: ds.pending.map { s in
                    [Fmt.day.string(from: s.invoiceDate), s.invoiceNumber, s.client, s.label, Fmt.eur(s.amount)]
                }, total: ["TOTAL", "", "", "", Fmt.eur(ds.summary.pendingAmount)])
            }

            pdf.title("Registre des achats", size: 14)
            pdf.table([
                .init(title: "Date", weight: 8),
                .init(title: "N° pièce", weight: 9),
                .init(title: "Fournisseur", weight: 16),
                .init(title: "Nature", weight: 20),
                .init(title: "Catégorie", weight: 15),
                .init(title: "Règlement", weight: 10),
                .init(title: "TTC", weight: 9, align: .right),
                .init(title: "TVA", weight: 7, align: .right),
                .init(title: "Justif.", weight: 5, align: .center)
            ], rows: ds.purchases.map { p in
                [Fmt.day.string(from: p.date), p.invoiceNumber, p.supplier, p.label, p.category.label,
                 p.paymentMethod.label, Fmt.eur(p.amount), p.vatAmount > 0 ? Fmt.eur(p.vatAmount) : "", p.attachmentName == nil ? "—" : "oui"]
            }, total: ["TOTAL", "", "", "", "", "", Fmt.eur(ds.summary.purchases),
                       Fmt.eur(ds.purchases.map(\.vatAmount).reduce(0, +)), ""])

            let months = monthlyRows(sales: sales, purchases: purchases, scope: scope, settings: settings)
            if months.count > 1 {
                pdf.title("Récapitulatif mensuel", size: 14)
                pdf.table([
                    .init(title: "Mois", weight: 14),
                    .init(title: "CA encaissé", weight: 12, align: .right),
                    .init(title: "Achats", weight: 12, align: .right),
                    .init(title: "Cotisations estimées", weight: 14, align: .right),
                    .init(title: "Bénéfice estimé", weight: 12, align: .right)
                ], rows: months.map { m in
                    [m.0, Fmt.eur(m.1.ca), Fmt.eur(m.1.purchases), Fmt.eur(m.1.urssafTotal), Fmt.eur(m.1.profit)]
                }, total: ["TOTAL", Fmt.eur(ds.summary.ca), Fmt.eur(ds.summary.purchases),
                           Fmt.eur(ds.summary.urssafTotal), Fmt.eur(ds.summary.profit)])
            }
            pdf.text("Document généré par l'application Compta AE. Montants en euros. Les recettes sont enregistrées à la date d'encaissement. Les cotisations indiquées sont des estimations.", size: 8, color: .gray)
        }
    }

    static func pdf(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) throws -> URL {
        let url = try outputURL("\(stem(settings))_\(scope.fileStem).pdf")
        try pdfData(sales: sales, purchases: purchases, scope: scope, settings: settings).write(to: url)
        return url
    }

    // MARK: Dossier complet (contrôle)

    /// ZIP contenant le PDF, l'Excel et tous les justificatifs renommés (Ventes/…, Achats/…).
    static func dossier(sales: [Sale], purchases: [Purchase], scope: ExportScope, settings: AppSettings) throws -> URL {
        let ds = dataset(sales: sales, purchases: purchases, scope: scope, settings: settings)
        var zip = ZipWriter()
        let base = "\(stem(settings))_\(scope.fileStem)"
        zip.add("\(base).pdf", pdfData(sales: sales, purchases: purchases, scope: scope, settings: settings))
        zip.add("\(base).xlsx", xlsxData(sales: sales, purchases: purchases, scope: scope, settings: settings))
        for (name, path) in ds.attachmentPaths.sorted(by: { $0.value < $1.value }) {
            if let data = try? Data(contentsOf: AttachmentStore.url(for: name)) {
                zip.add("Justificatifs/\(path)", data)
            }
        }
        let url = try outputURL("Dossier_\(base).zip")
        try zip.finalize().write(to: url)
        return url
    }

    // MARK: Sauvegarde / restauration

    struct SaleDTO: Codable {
        var id: UUID; var invoiceDate: Date; var paymentDate: Date?; var client: String; var label: String
        var amount: Double; var paymentMethodRaw: String; var categoryRaw: String; var invoiceNumber: String
        var attachmentName: String?; var notes: String; var createdAt: Date
    }

    struct PurchaseDTO: Codable {
        var id: UUID; var date: Date; var supplier: String; var label: String; var amount: Double; var vatAmount: Double
        var paymentMethodRaw: String; var categoryRaw: String; var invoiceNumber: String
        var attachmentName: String?; var notes: String; var createdAt: Date
    }

    struct Backup: Codable {
        var version = 1
        var exportedAt = Date()
        var settings: AppSettings
        var sales: [SaleDTO]
        var purchases: [PurchaseDTO]
    }

    static func backup(sales: [Sale], purchases: [Purchase], settings: AppSettings) throws -> URL {
        let b = Backup(
            settings: settings,
            sales: sales.map { SaleDTO(id: $0.id, invoiceDate: $0.invoiceDate, paymentDate: $0.paymentDate, client: $0.client,
                                       label: $0.label, amount: $0.amount, paymentMethodRaw: $0.paymentMethodRaw,
                                       categoryRaw: $0.categoryRaw, invoiceNumber: $0.invoiceNumber,
                                       attachmentName: $0.attachmentName, notes: $0.notes, createdAt: $0.createdAt) },
            purchases: purchases.map { PurchaseDTO(id: $0.id, date: $0.date, supplier: $0.supplier, label: $0.label,
                                                   amount: $0.amount, vatAmount: $0.vatAmount, paymentMethodRaw: $0.paymentMethodRaw,
                                                   categoryRaw: $0.categoryRaw, invoiceNumber: $0.invoiceNumber,
                                                   attachmentName: $0.attachmentName, notes: $0.notes, createdAt: $0.createdAt) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var zip = ZipWriter()
        zip.add("backup.json", try encoder.encode(b))
        let names = Set(sales.compactMap(\.attachmentName) + purchases.compactMap(\.attachmentName))
        for name in names.sorted() {
            if let data = try? Data(contentsOf: AttachmentStore.url(for: name)) {
                zip.add("Justificatifs/\(name)", data)
            }
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmm"
        let url = try outputURL("Sauvegarde_ComptaAE_\(df.string(from: Date())).zip")
        try zip.finalize().write(to: url)
        return url
    }

    /// Fusionne une sauvegarde : les écritures déjà présentes (même identifiant) sont ignorées.
    static func restore(from url: URL, context: ModelContext, settingsStore: SettingsStore) throws -> (sales: Int, purchases: Int) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let entries = ZipReader.entries(try Data(contentsOf: url))
        guard let json = entries["backup.json"] else { throw ExportError.invalidBackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let b = try decoder.decode(Backup.self, from: json)

        for (path, data) in entries where path.hasPrefix("Justificatifs/") {
            let name = String(path.dropFirst("Justificatifs/".count))
            if !name.isEmpty && !AttachmentStore.exists(name) {
                try? data.write(to: AttachmentStore.url(for: name))
            }
        }

        let existingSales = Set(((try? context.fetch(FetchDescriptor<Sale>())) ?? []).map(\.id))
        let existingPurchases = Set(((try? context.fetch(FetchDescriptor<Purchase>())) ?? []).map(\.id))
        var nS = 0, nP = 0
        for d in b.sales where !existingSales.contains(d.id) {
            let s = Sale()
            s.id = d.id; s.invoiceDate = d.invoiceDate; s.paymentDate = d.paymentDate; s.client = d.client
            s.label = d.label; s.amount = d.amount; s.paymentMethodRaw = d.paymentMethodRaw; s.categoryRaw = d.categoryRaw
            s.invoiceNumber = d.invoiceNumber; s.attachmentName = d.attachmentName; s.notes = d.notes; s.createdAt = d.createdAt
            context.insert(s); nS += 1
        }
        for d in b.purchases where !existingPurchases.contains(d.id) {
            let p = Purchase()
            p.id = d.id; p.date = d.date; p.supplier = d.supplier; p.label = d.label; p.amount = d.amount
            p.vatAmount = d.vatAmount; p.paymentMethodRaw = d.paymentMethodRaw; p.categoryRaw = d.categoryRaw
            p.invoiceNumber = d.invoiceNumber; p.attachmentName = d.attachmentName; p.notes = d.notes; p.createdAt = d.createdAt
            context.insert(p); nP += 1
        }
        try context.save()
        if settingsStore.s.businessName.isEmpty && settingsStore.s.siret.isEmpty {
            settingsStore.s = b.settings
        }
        return (nS, nP)
    }
}
