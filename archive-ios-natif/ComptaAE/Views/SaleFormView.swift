import SwiftUI
import SwiftData
import QuickLook

struct SaleFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    @Query(sort: \Sale.invoiceDate, order: .reverse) private var allSales: [Sale]

    let existing: Sale?
    let draft: EntryDraft?

    @State private var client = ""
    @State private var label = ""
    @State private var amountText = ""
    @State private var invoiceDate = Date()
    @State private var isPaid = true
    @State private var paymentDate = Date()
    @State private var method: PaymentMethod = .virement
    @State private var category: ActivityCategory = .prestationBNC
    @State private var invoiceNumber = ""
    @State private var notes = ""
    @State private var attachmentName: String?
    @State private var originalAttachment: String?
    @State private var previewURL: URL?
    @State private var loaded = false
    @State private var saved = false

    private var amount: Double? { amountText.parsedAmount }
    private var canSave: Bool { (amount ?? 0) > 0 && !client.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if let draft, draft.fromDocument {
                    Section {
                        Label(draft.usedAI ? "Pré-rempli par Apple Intelligence — vérifiez les valeurs."
                                           : "Pré-rempli depuis le document — vérifiez les valeurs.",
                              systemImage: "wand.and.stars")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Client") {
                    TextField("Nom du client", text: $client)
                        .textInputAutocapitalization(.words)
                    SuggestionChips(items: clientSuggestions) { pickClient($0) }
                }

                Section("Prestation / vente") {
                    TextField("Nature (ex : Création site web)", text: $label, axis: .vertical)
                    SuggestionChips(items: labelSuggestions) { label = $0 }
                    Picker("Catégorie", selection: $category) {
                        ForEach(ActivityCategory.allCases) { Text($0.shortLabel).tag($0) }
                    }
                }

                Section {
                    AmountField(title: "Montant", text: $amountText)
                } header: {
                    Text("Montant")
                } footer: {
                    Text("En franchise de TVA : montant facturé, sans TVA.")
                }

                Section("Facture") {
                    TextField("N° de facture", text: $invoiceNumber)
                        .textInputAutocapitalization(.characters)
                    DatePicker("Date de facture", selection: $invoiceDate, displayedComponents: .date)
                }

                Section {
                    Toggle("Paiement reçu", isOn: $isPaid.animation())
                    if isPaid {
                        DatePicker("Date d'encaissement", selection: $paymentDate, displayedComponents: .date)
                    }
                    Picker("Mode de règlement", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Encaissement")
                } footer: {
                    Text("Le chiffre d'affaires à déclarer à l'URSSAF est celui encaissé : c'est la date d'encaissement qui compte.")
                }

                AttachmentSection(attachmentName: $attachmentName, previewURL: $previewURL)

                Section("Notes") {
                    TextField("Facultatif", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(existing == nil ? "Nouvelle vente" : "Modifier la vente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") { save() }.disabled(!canSave)
                }
            }
            .quickLookPreview($previewURL)
            .onAppear(perform: load)
            .onDisappear(perform: cleanup)
        }
    }

    // MARK: Suggestions

    private var clientSuggestions: [String] {
        var seen = Set<String>()
        let names = allSales.map(\.client).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let q = client.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(names.prefix(8)) }
        if names.contains(where: { $0.lowercased() == q }) { return [] }
        return Array(names.filter { $0.lowercased().contains(q) }.prefix(8))
    }

    private var labelSuggestions: [String] {
        var counts: [String: Int] = [:]
        let source = client.isEmpty ? allSales : allSales.filter { $0.client.lowercased() == client.lowercased() }
        for s in source where !s.label.isEmpty { counts[s.label, default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }.map(\.key)
        return Array(sorted.filter { $0 != label }.prefix(6))
    }

    private func pickClient(_ name: String) {
        client = name
        guard let last = allSales.first(where: { $0.client == name && $0.id != existing?.id }) else { return }
        if label.isEmpty { label = last.label }
        if amountText.isEmpty { amountText = Fmt.amountInput(last.amount) }
        category = last.category
        method = last.paymentMethod
    }

    /// Propose le numéro suivant : F2026-007 → F2026-008
    private func nextInvoiceNumber() -> String {
        guard let last = allSales.sorted(by: { $0.createdAt > $1.createdAt }).map(\.invoiceNumber).first(where: { !$0.isEmpty }) else {
            return "F\(Fiscal.currentYear())-001"
        }
        let digits = last.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let n = Int(String(digits.reversed())) else { return "" }
        let prefix = last.dropLast(digits.count)
        let next = String(n + 1)
        let padded = String(repeating: "0", count: max(0, digits.count - next.count)) + next
        return String(prefix) + padded
    }

    // MARK: Chargement / enregistrement

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = existing {
            client = s.client
            label = s.label
            amountText = Fmt.amountInput(s.amount)
            invoiceDate = s.invoiceDate
            isPaid = s.paymentDate != nil
            paymentDate = s.paymentDate ?? Date()
            method = s.paymentMethod
            category = s.category
            invoiceNumber = s.invoiceNumber
            notes = s.notes
            attachmentName = s.attachmentName
            originalAttachment = s.attachmentName
            return
        }
        category = settings.s.mainCategory
        if let lastMethod = allSales.first?.paymentMethod { method = lastMethod }
        if let d = draft {
            client = d.party ?? ""
            label = d.label ?? ""
            if let a = d.amount { amountText = Fmt.amountInput(a) }
            if let date = d.date { invoiceDate = date }
            if let c = d.saleCategory { category = c }
            if let m = d.method { method = m }
            invoiceNumber = d.invoiceNumber ?? (d.fromDocument ? "" : nextInvoiceNumber())
            attachmentName = d.attachmentName
            originalAttachment = d.attachmentName
            if d.fromDocument { isPaid = false }
        }
        if invoiceNumber.isEmpty && draft?.fromDocument != true { invoiceNumber = nextInvoiceNumber() }
    }

    private func save() {
        guard let amount else { return }
        let s = existing ?? Sale()
        s.client = client.trimmingCharacters(in: .whitespaces)
        s.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        s.amount = round2(amount)
        s.invoiceDate = invoiceDate
        s.paymentDate = isPaid ? paymentDate : nil
        s.paymentMethod = method
        s.category = category
        s.invoiceNumber = invoiceNumber.trimmingCharacters(in: .whitespaces)
        s.notes = notes
        s.attachmentName = attachmentName
        if existing == nil { context.insert(s) }
        try? context.save()
        if let original = originalAttachment, original != attachmentName { AttachmentStore.delete(original) }
        saved = true
        dismiss()
    }

    /// Supprime les fichiers importés mais non conservés (annulation).
    private func cleanup() {
        guard !saved else { return }
        let keep = existing?.attachmentName
        for name in Set([attachmentName, draft?.attachmentName].compactMap { $0 }) where name != keep {
            AttachmentStore.delete(name)
        }
    }
}
