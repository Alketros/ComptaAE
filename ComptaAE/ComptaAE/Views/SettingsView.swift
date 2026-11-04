import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct SettingsView: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    TextField("Nom commercial", text: $store.s.businessName)
                    TextField("Nom et prénom", text: $store.s.ownerName)
                    TextField("SIRET", text: $store.s.siret)
                        .keyboardType(.numberPad)
                    TextField("Adresse", text: $store.s.address, axis: .vertical)
                } header: {
                    Text("Mon entreprise")
                } footer: {
                    Text("Ces informations apparaissent en tête des exports.")
                }

                Section {
                    Picker("Activité principale", selection: $store.s.mainCategory) {
                        ForEach(ActivityCategory.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Déclaration URSSAF", selection: $store.s.frequency) {
                        ForEach(DeclarationFrequency.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Formation pro. (CFP)", selection: $store.s.cfp) {
                        ForEach(CFPType.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Versement libératoire de l'impôt", isOn: $store.s.versementLiberatoire)
                } header: {
                    Text("Activité")
                } footer: {
                    Text("La catégorie choisie est proposée par défaut à chaque vente ; vous pouvez la changer vente par vente si vous avez une activité mixte.")
                }

                Section {
                    Toggle("Je bénéficie de l'ACRE", isOn: $store.s.acreEnabled.animation())
                    if store.s.acreEnabled {
                        DatePicker("Fin de l'ACRE", selection: $store.s.acreEndDate, displayedComponents: .date)
                        PercentField(title: "Réduction des cotisations", value: $store.s.acreReductionPercent)
                    }
                } header: {
                    Text("ACRE")
                } footer: {
                    Text("L'ACRE réduit les cotisations jusqu'à la fin du 3e trimestre civil suivant le début d'activité (50 % pour les créations avant le 1er juillet 2026, 25 % ensuite). Vérifiez votre taux sur votre espace URSSAF.")
                }

                Section {
                    PercentField(title: "Vente de marchandises", value: $store.s.rateVente)
                    PercentField(title: "Services BIC", value: $store.s.rateBIC)
                    PercentField(title: "Libéral BNC", value: $store.s.rateBNC)
                    PercentField(title: "Libéral CIPAV", value: $store.s.rateCIPAV)
                    Button("Rétablir les taux 2026") {
                        let d = AppSettings()
                        store.s.rateVente = d.rateVente
                        store.s.rateBIC = d.rateBIC
                        store.s.rateBNC = d.rateBNC
                        store.s.rateCIPAV = d.rateCIPAV
                    }
                } header: {
                    Text("Taux de cotisations sociales")
                } footer: {
                    Text("Taux 2026 pré-remplis. Ils évoluent régulièrement : vérifiez-les sur urssaf.fr ou sur votre espace autoentrepreneur.urssaf.fr.")
                }

                Section("Plafonds et seuils (€)") {
                    EuroField(title: "Plafond micro — ventes", value: $store.s.plafondVente)
                    EuroField(title: "Plafond micro — services", value: $store.s.plafondServices)
                    EuroField(title: "Franchise TVA — ventes", value: $store.s.seuilTVAVente)
                    EuroField(title: "Franchise TVA — services", value: $store.s.seuilTVAServices)
                }

                Section {
                    Toggle("Verrouiller avec Face ID", isOn: $store.s.faceIDEnabled)
                    Toggle("Rappels de déclaration", isOn: $store.s.remindersEnabled)
                        .onChange(of: store.s.remindersEnabled) { _, on in
                            Task {
                                if on { _ = await NotificationScheduler.requestAuthorization() }
                                NotificationScheduler.reschedule(store.s)
                            }
                        }
                } header: {
                    Text("Sécurité et rappels")
                } footer: {
                    Text("Une notification 7 jours puis 1 jour avant chaque échéance de déclaration.")
                }

                Section {
                    Toggle("Utiliser Apple Intelligence", isOn: $store.s.useAI)
                    LabeledContent("Disponibilité", value: aiStatus)
                } header: {
                    Text("Lecture des factures")
                } footer: {
                    Text("Les factures sont lues directement sur l'iPhone (texte du PDF ou reconnaissance de texte pour les scans). Si Apple Intelligence est disponible, le modèle local améliore la détection. Aucune donnée n'est envoyée sur internet.")
                }

                Section("Aide-mémoire") {
                    HelpRow(title: "CA à déclarer", text: "Le chiffre d'affaires encaissé sur la période (pas celui facturé), sans déduire les achats ni les frais.")
                    HelpRow(title: "Achats", text: "En micro-entreprise, les achats ne réduisent pas les cotisations. Le registre des achats est obligatoire pour la vente de marchandises, et utile pour tous pour suivre votre rentabilité réelle.")
                    HelpRow(title: "Conservation", text: "Gardez factures et justificatifs 10 ans. Pensez à exporter une sauvegarde régulièrement.")
                    HelpRow(title: "Salarié + micro", text: "Vos cotisations micro s'ajoutent à celles prélevées sur votre salaire. Côté impôts, le CA est déclaré chaque printemps sur la 2042-C-PRO.")
                    Link("Site URSSAF auto-entrepreneur", destination: URL(string: "https://www.autoentrepreneur.urssaf.fr")!)
                }
            }
            .navigationTitle("Réglages")
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.s.frequency) { _, _ in NotificationScheduler.reschedule(store.s) }
        }
    }

    private var aiStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Disponible"
            default: return "Non disponible"
            }
        }
        #endif
        return "Nécessite iOS 26"
    }
}

struct PercentField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: $value, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Text("%").foregroundStyle(.secondary)
        }
    }
}

struct EuroField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: $value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
            Text("€").foregroundStyle(.secondary)
        }
    }
}

struct HelpRow: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
