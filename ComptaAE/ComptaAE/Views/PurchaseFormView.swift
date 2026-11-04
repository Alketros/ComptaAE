import SwiftUI
import SwiftData
import QuickLook

struct PurchaseFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Purchase.date, order: .reverse) private var allPurchases: [Purchase]

    let existing: Purchase?
    let draft: EntryDraft?

    @State private var supplier = ""
    @State private var label = ""
    @State private var amountText = ""
    @State private var vatText = ""
    @State private var date = Date()
    @State private var method: PaymentMethod = .carte
    @State private var category: PurchaseCategory = .autre
    @State private var invoiceNumber = ""
    @State private var notes = ""
    @State private var attachmentName: String?
    @State private var originalAttachment: String?
    @State private var previewURL: URL?
    @State private var loaded = false
    @State private var saved = false

    private var amount: Double? { amountText.parsedAmount }
    private var canSave: Bool { (amount ?? 0) > 0 && !supplier.trimmingCharacters(in: .whitespaces).isEmpty }

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

                Section("Fournisseur") {
                    TextField("Nom du fournisseur", text: $supplier)
                        .textInputAutocapitalization(.words)
                    SuggestionChips(items: supplierSuggestions) { pickSupplier($0) }
                }

                Section("Achat") {
                    TextField("Nature (ex : Abonnement Adobe)", text: $label, axis: .vertical)
                    Picker("Catégorie", selection: $category) {
                        ForEach(PurchaseCategory.allCases) { c in
                            Label(c.label, systemImage: c.icon).tag(c)
                        }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                }

                Section {
                    AmountField(title: "Montant TTC", text: $amountText)
                    AmountField(title: "Dont TVA", text: $vatText)
                } header: {
                    Text("Montant")
                } footer: {
                    Text("En franchise de TVA, la TVA payée n'est pas récupérable : c'est le montant TTC qui compte. La TVA est notée pour information.")
                }

                Section("Paiement") {
                    Picker("Mode de règlement", selection: $method) {
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("N° de facture / ticket", text: $invoiceNumber)
                }

                AttachmentSection(attachmentName: $attachmentName, previewURL: $previewURL)

                Section("Notes") {
                    TextField("Facultatif", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle(existing == nil ? "Nouvel achat" : "Modifier l'achat")
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

    private var supplierSuggestions: [String] {
        var seen = Set<String>()
        let names = allPurchases.map(\.supplier).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        let q = supplier.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return Array(names.prefix(8)) }
        if names.contains(where: { $0.lowercased() == q }) { return [] }
        return Array(names.filter { $0.lowercased().contains(q) }.prefix(8))
    }

    private func pickSupplier(_ name: String) {
        supplier = name
        guard let last = allPurchases.first(where: { $0.supplier == name && $0.id != existing?.id }) else { return }
        if label.isEmpty { label = last.label }
        if amountText.isEmpty { amountText = Fmt.amountInput(last.amount) }
        category = last.category
        method = last.paymentMethod
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let p = existing {
            supplier = p.supplier
            label = p.label
            amountText = Fmt.amountInput(p.amount)
            vatText = p.vatAmount > 0 ? Fmt.amountInput(p.vatAmount) : ""
            date = p.date
            method = p.paymentMethod
            category = p.category
            invoiceNumber = p.invoiceNumber
            notes = p.notes
            attachmentName = p.attachmentName
            originalAttachment = p.attachmentName
            return
        }
        if let lastMethod = allPurchases.first?.paymentMethod { method = lastMethod }
        guard let d = draft else { return }
        supplier = d.party ?? ""
        label = d.label ?? ""
        if let a = d.amount { amountText = Fmt.amountInput(a) }
        if let v = d.vat { vatText = Fmt.amountInput(v) }
        if let dt = d.date { date = dt }
        if let m = d.method { method = m }
        invoiceNumber = d.invoiceNumber ?? ""
        attachmentName = d.attachmentName
        originalAttachment = d.attachmentName
        // Catégorie : celle déjà utilisée pour ce fournisseur, sinon devinée depuis le document
        if !supplier.isEmpty, let known = allPurchases.first(where: { $0.supplier.lowercased() == supplier.lowercased() }) {
            category = known.category
            supplier = known.supplier
            if label.isEmpty { label = known.label }
        } else if let c = d.purchaseCategory {
            category = c
        }
    }

    private func save() {
        guard let amount else { return }
        let p = existing ?? Purchase()
        p.supplier = supplier.trimmingCharacters(in: .whitespaces)
        p.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        p.amount = round2(amount)
        p.vatAmount = round2(vatText.parsedAmount ?? 0)
        p.date = date
        p.paymentMethod = method
        p.category = category
        p.invoiceNumber = invoiceNumber.trimmingCharacters(in: .whitespaces)
        p.notes = notes
        p.attachmentName = attachmentName
        if existing == nil { context.insert(p) }
        try? context.save()
        if let original = originalAttachment, original != attachmentName { AttachmentStore.delete(original) }
        saved = true
        dismiss()
    }

    private func cleanup() {
        guard !saved else { return }
        let keep = existing?.attachmentName
        for name in Set([attachmentName, draft?.attachmentName].compactMap { $0 }) where name != keep {
            AttachmentStore.delete(name)
        }
    }
}
