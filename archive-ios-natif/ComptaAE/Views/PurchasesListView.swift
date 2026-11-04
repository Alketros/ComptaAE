import SwiftUI
import SwiftData
import QuickLook

struct PurchasesListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Purchase.date, order: .reverse) private var purchases: [Purchase]

    @State private var year = Fiscal.currentYear()
    @State private var search = ""
    @State private var categoryFilter: PurchaseCategory?
    @State private var importAction: ImportAction?
    @State private var draft: EntryDraft?
    @State private var editing: Purchase?
    @State private var previewURL: URL?

    private var years: [Int] {
        Set(purchases.map { Fmt.calendar.component(.year, from: $0.date) } + [Fiscal.currentYear()]).sorted(by: >)
    }

    private var filtered: [Purchase] {
        let q = search.lowercased()
        return purchases.filter { p in
            guard Fmt.calendar.component(.year, from: p.date) == year else { return false }
            if let c = categoryFilter, p.category != c { return false }
            guard !q.isEmpty else { return true }
            return p.supplier.lowercased().contains(q) || p.label.lowercased().contains(q) || p.invoiceNumber.lowercased().contains(q)
        }
    }

    private var groups: [(key: Date, items: [Purchase])] {
        let grouped = Dictionary(grouping: filtered) { Fiscal.monthInterval(containing: $0.date).start }
        return grouped.keys.sorted(by: >).map { (key: $0, items: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Total achats \(String(year))")
                        Spacer()
                        Text(Fmt.eur(filtered.map(\.amount).reduce(0, +))).font(.headline.monospacedDigit())
                    }
                    let missing = filtered.filter { $0.attachmentName == nil }.count
                    if missing > 0 {
                        Label("\(missing) achat\(missing > 1 ? "s" : "") sans justificatif", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                if filtered.isEmpty {
                    ContentUnavailableView("Aucun achat", systemImage: "cart",
                                           description: Text("Touchez + pour importer une facture (PDF, scan, photo) ou saisir un achat."))
                }

                ForEach(groups, id: \.key) { group in
                    Section {
                        ForEach(group.items) { p in row(p) }
                    } header: {
                        HStack {
                            Text(Fmt.monthYear.string(from: group.key).capitalizedFirst)
                            Spacer()
                            Text(Fmt.eur(group.items.map(\.amount).reduce(0, +)))
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Fournisseur, nature, n° pièce")
            .navigationTitle("Achats")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Année", selection: $year) {
                            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                        }
                        Picker("Catégorie", selection: $categoryFilter) {
                            Text("Toutes catégories").tag(PurchaseCategory?.none)
                            ForEach(PurchaseCategory.allCases) { Text($0.label).tag(PurchaseCategory?.some($0)) }
                        }
                    } label: {
                        Label(String(year), systemImage: categoryFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    AddEntryMenu(action: $importAction)
                }
            }
            .entryImport(kind: .purchase, action: $importAction, draft: $draft)
            .sheet(item: $draft) { d in PurchaseFormView(existing: nil, draft: d) }
            .sheet(item: $editing) { p in PurchaseFormView(existing: p, draft: nil) }
            .quickLookPreview($previewURL)
        }
    }

    @ViewBuilder
    private func row(_ p: Purchase) -> some View {
        Button { editing = p } label: {
            HStack(spacing: 12) {
                Image(systemName: p.category.icon)
                    .frame(width: 28)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.supplier).font(.body.weight(.medium))
                        if p.attachmentName != nil {
                            Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(p.label.isEmpty ? p.category.label : p.label)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(Fmt.day.string(from: p.date)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.eur(p.amount)).font(.body.monospacedDigit())
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(p) } label: { Label("Supprimer", systemImage: "trash") }
        }
        .contextMenu {
            if let name = p.attachmentName, AttachmentStore.exists(name) {
                Button { previewURL = AttachmentStore.url(for: name) } label: { Label("Voir le justificatif", systemImage: "doc.richtext") }
            }
            Button { duplicate(p) } label: { Label("Dupliquer", systemImage: "plus.square.on.square") }
            Button(role: .destructive) { delete(p) } label: { Label("Supprimer", systemImage: "trash") }
        }
    }

    private func duplicate(_ p: Purchase) {
        var d = EntryDraft()
        d.party = p.supplier
        d.label = p.label
        d.amount = p.amount
        d.vat = p.vatAmount > 0 ? p.vatAmount : nil
        d.purchaseCategory = p.category
        d.method = p.paymentMethod
        draft = d
    }

    private func delete(_ p: Purchase) {
        AttachmentStore.delete(p.attachmentName)
        context.delete(p)
        try? context.save()
    }
}
