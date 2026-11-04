import Foundation
import Observation

enum DeclarationFrequency: String, Codable, CaseIterable, Identifiable {
    case monthly, quarterly
    var id: String { rawValue }
    var label: String { self == .monthly ? "Mensuelle" : "Trimestrielle" }
}

enum CFPType: String, Codable, CaseIterable, Identifiable {
    case commercant, artisan, liberal
    var id: String { rawValue }
    var label: String {
        switch self {
        case .commercant: return "Commerçant (0,1 %)"
        case .artisan: return "Artisan (0,3 %)"
        case .liberal: return "Libéral (0,2 %)"
        }
    }
    var rate: Double {
        switch self {
        case .commercant: return 0.001
        case .artisan: return 0.003
        case .liberal: return 0.002
        }
    }
}

struct AppSettings: Codable, Equatable {
    // Entreprise
    var businessName = ""
    var ownerName = ""
    var siret = ""
    var address = ""

    // Activité
    var mainCategory: ActivityCategory = .prestationBNC
    var frequency: DeclarationFrequency = .monthly
    var cfp: CFPType = .liberal
    var versementLiberatoire = false
    var acreEnabled = false
    var acreEndDate = Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date()
    var acreReductionPercent = 50.0

    // Taux de cotisations sociales (en %) — valeurs 2026, modifiables
    var rateVente = 12.3
    var rateBIC = 21.2
    var rateBNC = 25.6
    var rateCIPAV = 23.2

    // Plafonds (en €)
    var plafondVente = 203_100.0
    var plafondServices = 83_600.0
    var seuilTVAVente = 85_000.0
    var seuilTVAServices = 37_500.0

    // Divers
    var faceIDEnabled = false
    var remindersEnabled = true
    var useAI = true
    var declaredPeriods: [String] = []

    init() {}

    // Décodage tolérant : un champ ajouté dans une future version ne fait pas perdre les réglages.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        businessName = try c.decodeIfPresent(String.self, forKey: .businessName) ?? d.businessName
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? d.ownerName
        siret = try c.decodeIfPresent(String.self, forKey: .siret) ?? d.siret
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? d.address
        mainCategory = (try? c.decodeIfPresent(ActivityCategory.self, forKey: .mainCategory)) ?? d.mainCategory
        frequency = (try? c.decodeIfPresent(DeclarationFrequency.self, forKey: .frequency)) ?? d.frequency
        cfp = (try? c.decodeIfPresent(CFPType.self, forKey: .cfp)) ?? d.cfp
        versementLiberatoire = try c.decodeIfPresent(Bool.self, forKey: .versementLiberatoire) ?? d.versementLiberatoire
        acreEnabled = try c.decodeIfPresent(Bool.self, forKey: .acreEnabled) ?? d.acreEnabled
        acreEndDate = try c.decodeIfPresent(Date.self, forKey: .acreEndDate) ?? d.acreEndDate
        acreReductionPercent = try c.decodeIfPresent(Double.self, forKey: .acreReductionPercent) ?? d.acreReductionPercent
        rateVente = try c.decodeIfPresent(Double.self, forKey: .rateVente) ?? d.rateVente
        rateBIC = try c.decodeIfPresent(Double.self, forKey: .rateBIC) ?? d.rateBIC
        rateBNC = try c.decodeIfPresent(Double.self, forKey: .rateBNC) ?? d.rateBNC
        rateCIPAV = try c.decodeIfPresent(Double.self, forKey: .rateCIPAV) ?? d.rateCIPAV
        plafondVente = try c.decodeIfPresent(Double.self, forKey: .plafondVente) ?? d.plafondVente
        plafondServices = try c.decodeIfPresent(Double.self, forKey: .plafondServices) ?? d.plafondServices
        seuilTVAVente = try c.decodeIfPresent(Double.self, forKey: .seuilTVAVente) ?? d.seuilTVAVente
        seuilTVAServices = try c.decodeIfPresent(Double.self, forKey: .seuilTVAServices) ?? d.seuilTVAServices
        faceIDEnabled = try c.decodeIfPresent(Bool.self, forKey: .faceIDEnabled) ?? d.faceIDEnabled
        remindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? d.remindersEnabled
        useAI = try c.decodeIfPresent(Bool.self, forKey: .useAI) ?? d.useAI
        declaredPeriods = try c.decodeIfPresent([String].self, forKey: .declaredPeriods) ?? d.declaredPeriods
    }

    /// Taux de cotisations sociales (fraction, ex. 0.256)
    func socialRate(_ c: ActivityCategory) -> Double {
        switch c {
        case .venteMarchandises: return rateVente / 100
        case .prestationBIC: return rateBIC / 100
        case .prestationBNC: return rateBNC / 100
        case .liberalCIPAV: return rateCIPAV / 100
        }
    }

    /// Taux du versement libératoire de l'impôt sur le revenu (fraction)
    func vlRate(_ c: ActivityCategory) -> Double {
        guard versementLiberatoire else { return 0 }
        switch c {
        case .venteMarchandises: return 0.01
        case .prestationBIC: return 0.017
        case .prestationBNC, .liberalCIPAV: return 0.022
        }
    }

    /// Coefficient ACRE à appliquer aux cotisations sociales pour une date d'encaissement
    func acreFactor(at date: Date) -> Double {
        guard acreEnabled, date <= acreEndDate else { return 1 }
        return max(0, 1 - acreReductionPercent / 100)
    }
}

@Observable
final class SettingsStore {
    private static let key = "app.settings.v1"

    var s: AppSettings {
        didSet { save() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            s = decoded
        } else {
            s = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func isDeclared(_ p: Period) -> Bool { s.declaredPeriods.contains(p.key) }

    func toggleDeclared(_ p: Period) {
        if let i = s.declaredPeriods.firstIndex(of: p.key) {
            s.declaredPeriods.remove(at: i)
        } else {
            s.declaredPeriods.append(p.key)
        }
        NotificationScheduler.reschedule(s)
    }
}
