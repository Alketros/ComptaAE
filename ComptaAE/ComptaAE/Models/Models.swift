import Foundation
import SwiftData

// MARK: - Catégories d'activité (détermine le taux URSSAF)

enum ActivityCategory: String, Codable, CaseIterable, Identifiable {
    case venteMarchandises
    case prestationBIC
    case prestationBNC
    case liberalCIPAV

    var id: String { rawValue }

    var label: String {
        switch self {
        case .venteMarchandises: return "Vente de marchandises (BIC)"
        case .prestationBIC: return "Prestation de services (BIC)"
        case .prestationBNC: return "Prestation libérale (BNC)"
        case .liberalCIPAV: return "Libéral réglementé (CIPAV)"
        }
    }

    var shortLabel: String {
        switch self {
        case .venteMarchandises: return "Vente"
        case .prestationBIC: return "Services BIC"
        case .prestationBNC: return "Libéral BNC"
        case .liberalCIPAV: return "CIPAV"
        }
    }

    /// Activité de services (soumise au plafond « services »)
    var isService: Bool { self != .venteMarchandises }

    /// Abattement forfaitaire appliqué par les impôts (régime micro)
    var taxAllowance: Double {
        switch self {
        case .venteMarchandises: return 0.71
        case .prestationBIC: return 0.50
        case .prestationBNC, .liberalCIPAV: return 0.34
        }
    }

    /// Case de la déclaration 2042-C-PRO
    func taxBox(versementLiberatoire: Bool) -> String {
        switch self {
        case .venteMarchandises: return versementLiberatoire ? "5TA" : "5KO"
        case .prestationBIC: return versementLiberatoire ? "5TB" : "5KP"
        case .prestationBNC, .liberalCIPAV: return versementLiberatoire ? "5TE" : "5HQ"
        }
    }
}

enum PaymentMethod: String, Codable, CaseIterable, Identifiable {
    case virement, carte, especes, cheque, paypal, prelevement, autre
    var id: String { rawValue }
    var label: String {
        switch self {
        case .virement: return "Virement"
        case .carte: return "Carte bancaire"
        case .especes: return "Espèces"
        case .cheque: return "Chèque"
        case .paypal: return "PayPal / Stripe…"
        case .prelevement: return "Prélèvement"
        case .autre: return "Autre"
        }
    }
}

enum PurchaseCategory: String, Codable, CaseIterable, Identifiable {
    case marchandises, materiel, logiciel, fournitures, deplacement, telecom,
         formation, sousTraitance, publicite, banqueAssurance, autre
    var id: String { rawValue }
    var label: String {
        switch self {
        case .marchandises: return "Marchandises / matières premières"
        case .materiel: return "Matériel / équipement"
        case .logiciel: return "Logiciel / abonnement"
        case .fournitures: return "Fournitures de bureau"
        case .deplacement: return "Déplacements / transport"
        case .telecom: return "Téléphone / internet"
        case .formation: return "Formation"
        case .sousTraitance: return "Sous-traitance"
        case .publicite: return "Publicité / communication"
        case .banqueAssurance: return "Banque / assurance"
        case .autre: return "Autre"
        }
    }
    var icon: String {
        switch self {
        case .marchandises: return "shippingbox"
        case .materiel: return "desktopcomputer"
        case .logiciel: return "app.badge"
        case .fournitures: return "paperclip"
        case .deplacement: return "car"
        case .telecom: return "antenna.radiowaves.left.and.right"
        case .formation: return "graduationcap"
        case .sousTraitance: return "person.2"
        case .publicite: return "megaphone"
        case .banqueAssurance: return "building.columns"
        case .autre: return "ellipsis.circle"
        }
    }
}

// MARK: - Vente (livre des recettes)

@Model
final class Sale {
    var id: UUID = UUID()
    var invoiceDate: Date = Date()
    /// Date d'encaissement. `nil` = facture en attente de paiement.
    var paymentDate: Date? = nil
    var client: String = ""
    var label: String = ""
    var amount: Double = 0
    var paymentMethodRaw: String = PaymentMethod.virement.rawValue
    var categoryRaw: String = ActivityCategory.prestationBNC.rawValue
    var invoiceNumber: String = ""
    var attachmentName: String? = nil
    var notes: String = ""
    var createdAt: Date = Date()

    init() {}

    var paymentMethod: PaymentMethod {
        get { PaymentMethod(rawValue: paymentMethodRaw) ?? .autre }
        set { paymentMethodRaw = newValue.rawValue }
    }
    var category: ActivityCategory {
        get { ActivityCategory(rawValue: categoryRaw) ?? .prestationBNC }
        set { categoryRaw = newValue.rawValue }
    }
    var isPaid: Bool { paymentDate != nil }
    /// Date utilisée pour le classement : encaissement si payé, sinon facture.
    var effectiveDate: Date { paymentDate ?? invoiceDate }
}

// MARK: - Achat (registre des achats)

@Model
final class Purchase {
    var id: UUID = UUID()
    var date: Date = Date()
    var supplier: String = ""
    var label: String = ""
    var amount: Double = 0      // TTC
    var vatAmount: Double = 0   // TVA incluse (information)
    var paymentMethodRaw: String = PaymentMethod.carte.rawValue
    var categoryRaw: String = PurchaseCategory.autre.rawValue
    var invoiceNumber: String = ""
    var attachmentName: String? = nil
    var notes: String = ""
    var createdAt: Date = Date()

    init() {}

    var paymentMethod: PaymentMethod {
        get { PaymentMethod(rawValue: paymentMethodRaw) ?? .autre }
        set { paymentMethodRaw = newValue.rawValue }
    }
    var category: PurchaseCategory {
        get { PurchaseCategory(rawValue: categoryRaw) ?? .autre }
        set { categoryRaw = newValue.rawValue }
    }
}

// MARK: - Brouillon de saisie (pré-remplissage depuis document / duplication)

struct EntryDraft: Identifiable {
    let id = UUID()
    var attachmentName: String? = nil
    var party: String? = nil
    var label: String? = nil
    var amount: Double? = nil
    var vat: Double? = nil
    var date: Date? = nil
    var invoiceNumber: String? = nil
    var saleCategory: ActivityCategory? = nil
    var purchaseCategory: PurchaseCategory? = nil
    var method: PaymentMethod? = nil
    var fromDocument = false
    var usedAI = false
}
