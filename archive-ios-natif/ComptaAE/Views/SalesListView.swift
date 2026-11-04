import SwiftUI
import SwiftData
import QuickLook

enum SaleFilter: String, CaseIterable, Identifiable {
    case all = "Toutes", paid = "Encaissées", pending = "En attente"
    var id: String { rawValue }
}

struct SalesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Sale.invoiceDate, order: .reverse) private var sales: [Sale]

    @State private var year = Fiscal.currentYear()
    @State private var filter: SaleFilter = .all
    @State private var search = ""
    @State private var importAction: ImportAction?
    @State private var draft: EntryDraft?
    @State private var editing: Sale?
    @State private var previewURL: URL?

    private var years: [Int] {
        let ys = Set(sales.map { Fmt.calendar.component(.year, from: $0.effectiveDate) } + [Fiscal.currentYear()])
        return ys.sorted(by: >)
    }

    private var filtered: [Sale] {
        let q = search.lowercased()
        return sales.filter { s in
            let inYear = Fmt.calendar.component(.year, from: s.effectiveDate) == year || (!s.isPaid && filter == .pending)
            guard inYear else { return false }
            switch filter {
            case .all: break
            case .paid: if !s.isPaid { return false }
            case .pending: if s.isPaid { return false }
            }
            guard !q.isEmpty else { return true }
            return s.client.lowercased().contains(q) || s.label.lowercased().contains(q) || s.invoiceNumber.lowercased().contains(q)
        }
        .sorted { $0.effectiveDate > $1.effectiveDate }
    }

    private var groups: [(key: Date, items: [Sale])] {
        let grouped = Dictionary(grouping: filtered) { Fiscal.monthInterval(containing: $0.effectiveDate).start }
        return grouped.keys.sorted(by: >).map { (key: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Filtre", selection: $filter) {
                        ForEach(SaleFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text(filter == .pending ? "Total en attente" : "Total encaissé \(String(year))")
                        Spacer()
                        Text(Fmt.eur(filtered.filter { filter == .pending ? !$0.isPaid : $0.isPaid }.map(\.amount).reduce(0, +)))
                            .font(.headline.monospacedDigit())
                    }
                }

                if filtered.isEmpty {
                    ContentUnavailableView("Aucune vente", systemImage: "eurosign.circle",
                                           description: Text("Touchez + pour saisir une vente ou importer une facture PDF."))
                }

                ForEach(groups, id: \.key) { group in
                    Section {
                        ForEach(group.items) { sale in
                            row(sale)
                        }
                    } header: {
                        HStack {
                            Text(Fmt.monthYear.string(from: group.key).capitalizedFirst)
                            Spacer()
                            Text(Fmt.eur(group.items.filter(\.isPaid).map(\.amount).reduce(0, +)))
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Client, prestation, n° facture")
            .navigationTitle("Ventes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Année", selection: $year) {
                            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                        }
                    } label: {
                        Label(String(year), systemImage: "calendar")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AddEntryMenu(action: $importAction)
                }
            }
            .entryImport(kind: .sale, action: $importAction, draft: $draft)
            .sheet(item: $draft) { d in SaleFormView(existing: nil, draft: d) }
            .sheet(item: $editing) { s in SaleFormView(existing: s, draft: nil) }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder
    private func row(_ sale: Sale) -> some View {
        Button { editing = sale } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(sale.client).font(.body.weight(.medium))
                        if sale.attachmentName != nil {
                            Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text([sale.label, sale.invoiceNumber].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if sale.isPaid {
                        Text("Encaissée le \(Fmt.day.string(from: sale.effectiveDate))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("En attente — facturée le \(Fmt.day.string(from: sale.invoiceDate))")
                            .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(Fmt.eur(sale.amount))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(sale.isPaid ? Color.primary : Color.orange)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(sale) } label: { Label("Supprimer", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            if !sale.isPaid {
                Button {
                    sale.paymentDate = Date()
                    try? context.save()
                } label: { Label("Encaissée", systemImage: "checkmark.circle") }
                .tint(.green)
            }
        }
        .contextMenu {
            if let name = sale.attachmentName, AttachmentStore.exists(name) {
                Button { previewURL = AttachmentStore.url(for: name) } label: { Label("Voir le justificatif", systemImage: "doc.richtext") }
            }
            Button { duplicate(sale) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            if !sale.isPaid {
                Button {
                    sale.paymentDate = Date()
                    try? context.save()
                } label: { Label("Marquer encaissée aujourd'hui", systemImage: "checkmark.circle") }
            }
            Button(role: .destructive) { delete(sale) } label: { Label("Supprimer", systemImage: "trash") }
        }
    }

    private func duplicate(_ s: Sale) {
        var d = EntryDraft()
        d.party = s.client
        d.label = s.label
        d.amount = s.amount
        d.saleCategory = s.category
        d.method = s.paymentMethod
        draft = d
    }

    private func delete(_ s: Sale) {
        AttachmentStore.delete(s.attachmentName)
        context.delete(s)
        try? context.save()
    }
}
