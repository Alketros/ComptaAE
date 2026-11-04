import Foundation

// MARK: - Formatage

enum Fmt {
    static let fr = Locale(identifier: "fr_FR")

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = fr
        c.firstWeekday = 2
        return c
    }

    private static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = fr
        f.currencyCode = "EUR"
        return f
    }()

    private static let plain: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = fr
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f
    }()

    static func eur(_ v: Double) -> String { currency.string(from: NSNumber(value: v)) ?? "\(v) €" }

    /// "12,50" — pour pré-remplir un champ de saisie
    static func amountInput(_ v: Double) -> String { plain.string(from: NSNumber(value: v)) ?? "\(v)" }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = fr
        f.dateFormat = "dd/MM/yyyy"
        return f
    }()

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = fr
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    static let shortMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = fr
        f.dateFormat = "LLL"
        return f
    }()

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func percent(_ v: Double) -> String { String(format: "%.0f %%", v * 100) }
}

extension String {
    /// Convertit "1 234,56" / "1234.56" / "12" en Double
    var parsedAmount: Double? {
        let cleaned = self
            .replacingOccurrences(of: "€", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}

func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

// MARK: - Périodes de déclaration

struct Period: Hashable, Identifiable {
    let start: Date
    let end: Date          // exclusive
    let key: String        // "2026-10" ou "2026-T3"
    let label: String      // "octobre 2026" ou "3e trimestre 2026"
    var id: String { key }

    var interval: DateInterval { DateInterval(start: start, end: end) }

    /// Date limite : dernier jour du mois suivant la fin de la période
    var deadline: Date {
        let cal = Fmt.calendar
        let afterNext = cal.date(byAdding: .month, value: 1, to: end) ?? end
        return cal.date(byAdding: .day, value: -1, to: afterNext) ?? end
    }
}

enum Fiscal {
    static var cal: Calendar { Fmt.calendar }

    static func currentYear() -> Int { cal.component(.year, from: Date()) }

    static func monthInterval(containing date: Date) -> DateInterval {
        cal.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 1)
    }

    static func yearInterval(_ year: Int) -> DateInterval {
        let start = cal.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
        let end = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? Date()
        return DateInterval(start: start, end: end)
    }

    static func quarterInterval(year: Int, quarter: Int) -> DateInterval {
        let start = cal.date(from: DateComponents(year: year, month: (quarter - 1) * 3 + 1, day: 1)) ?? Date()
        let end = cal.date(byAdding: .month, value: 3, to: start) ?? Date()
        return DateInterval(start: start, end: end)
    }

    static func period(containing date: Date, frequency: DeclarationFrequency) -> Period {
        let comps = cal.dateComponents([.year, .month], from: date)
        let year = comps.year ?? 2026
        let month = comps.month ?? 1
        switch frequency {
        case .monthly:
            let iv = monthInterval(containing: date)
            return Period(start: iv.start, end: iv.end,
                          key: String(format: "%04ld-%02ld", year, month),
                          label: Fmt.monthYear.string(from: iv.start))
        case .quarterly:
            let q = (month - 1) / 3 + 1
            let iv = quarterInterval(year: year, quarter: q)
            return Period(start: iv.start, end: iv.end,
                          key: "\(year)-T\(q)",
                          label: "\(q == 1 ? "1er" : "\(q)e") trimestre \(year)")
        }
    }

    static func previous(_ p: Period, frequency: DeclarationFrequency) -> Period {
        period(containing: p.start.addingTimeInterval(-3600), frequency: frequency)
    }

    static func next(_ p: Period, frequency: DeclarationFrequency) -> Period {
        period(containing: p.end.addingTimeInterval(3600), frequency: frequency)
    }

    /// Période à déclarer en priorité : la période close si son échéance n'est pas passée
    /// et qu'elle n'est pas encore marquée comme déclarée, sinon la période en cours.
    static func nextDeclaration(settings: AppSettings, now: Date = Date()) -> Period {
        let current = period(containing: now, frequency: settings.frequency)
        let prev = previous(current, frequency: settings.frequency)
        let endOfDeadline = cal.date(byAdding: .day, value: 1, to: prev.deadline) ?? prev.deadline
        if now < endOfDeadline && !settings.declaredPeriods.contains(prev.key) {
            return prev
        }
        return current
    }

    static func daysUntil(_ date: Date) -> Int {
        let a = cal.startOfDay(for: Date())
        let b = cal.startOfDay(for: date)
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

// MARK: - Synthèse chiffrée

struct Summary {
    var caByCategory: [ActivityCategory: Double] = [:]
    var purchases: Double = 0
    var cotisations: Double = 0   // cotisations sociales (ACRE incluse)
    var cfp: Double = 0           // contribution formation professionnelle
    var impotVL: Double = 0       // versement libératoire
    var pendingCount = 0
    var pendingAmount: Double = 0
    var salesCount = 0
    var purchasesCount = 0

    var ca: Double { caByCategory.values.reduce(0, +) }
    var caServices: Double { caByCategory.filter { $0.key.isService }.map(\.value).reduce(0, +) }
    var caVente: Double { caByCategory[.venteMarchandises] ?? 0 }
    var urssafTotal: Double { cotisations + cfp + impotVL }
    /// Bénéfice réel estimé : CA - achats - sommes versées à l'URSSAF
    var profit: Double { ca - purchases - urssafTotal }
    /// Revenu imposable estimé après abattement forfaitaire (hors versement libératoire)
    var taxableIncome: Double {
        caByCategory.reduce(0) { $0 + $1.value * (1 - $1.key.taxAllowance) }
    }

    static func compute(sales: [Sale], purchases: [Purchase], in interval: DateInterval, settings: AppSettings) -> Summary {
        var s = Summary()
        for sale in sales {
            if let paid = sale.paymentDate {
                guard interval.start <= paid && paid < interval.end else { continue }
                let cat = sale.category
                s.caByCategory[cat, default: 0] += sale.amount
                s.cotisations += sale.amount * settings.socialRate(cat) * settings.acreFactor(at: paid)
                s.cfp += sale.amount * settings.cfp.rate
                s.impotVL += sale.amount * settings.vlRate(cat)
                s.salesCount += 1
            } else if interval.start <= sale.invoiceDate && sale.invoiceDate < interval.end {
                s.pendingCount += 1
                s.pendingAmount += sale.amount
            }
        }
        for p in purchases where interval.start <= p.date && p.date < interval.end {
            s.purchases += p.amount
            s.purchasesCount += 1
        }
        s.cotisations = round2(s.cotisations)
        s.cfp = round2(s.cfp)
        s.impotVL = round2(s.impotVL)
        return s
    }
}
