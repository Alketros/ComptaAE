import SwiftUI
import SwiftData
import Charts
import UIKit

struct DashboardView: View {
    @Environment(SettingsStore.self) private var settings
    @Query private var sales: [Sale]
    @Query private var purchases: [Purchase]
    @Binding var selectedTab: Int

    @State private var year = Fiscal.currentYear()

    private var s: AppSettings { settings.s }
    private var now: Date { Date() }

    private var monthSummary: Summary {
        Summary.compute(sales: sales, purchases: purchases, in: Fiscal.monthInterval(containing: now), settings: s)
    }
    private var yearSummary: Summary {
        Summary.compute(sales: sales, purchases: purchases, in: Fiscal.yearInterval(year), settings: s)
    }
    private var declaration: Period { Fiscal.nextDeclaration(settings: s) }
    private var declarationSummary: Summary {
        Summary.compute(sales: sales, purchases: purchases, in: declaration.interval, settings: s)
    }
    private var pendingSales: [Sale] { sales.filter { !$0.isPaid } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if s.businessName.isEmpty && sales.isEmpty && purchases.isEmpty {
                        onboarding
                    }
                    declarationCard
                    monthCard
                    yearCard
                    chartCard
                    thresholdsCard
                    if !pendingSales.isEmpty { pendingCard }
                    incomeTaxCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Accueil")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Année", selection: $year) {
                            ForEach((Fiscal.currentYear() - 5...Fiscal.currentYear()).reversed(), id: \.self) {
                                Text(String($0)).tag($0)
                            }
                        }
                    } label: {
                        Label(String(year), systemImage: "calendar")
                    }
                }
            }
        }
    }

    // MARK: Cartes

    private var onboarding: some View {
        Card(title: "Bienvenue 👋", systemImage: "sparkles") {
            Text("Commencez par renseigner votre activité (type, fréquence de déclaration, ACRE…) dans les Réglages : les calculs URSSAF en dépendent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Ouvrir les réglages") { selectedTab = 4 }
                .buttonStyle(.borderedProminent)
        }
    }

    private var declarationCard: some View {
        let p = declaration
        let sum = declarationSummary
        let days = Fiscal.daysUntil(p.deadline)
        let declared = settings.isDeclared(p)
        let isCurrent = p.start <= now && now < p.end
        return Card(title: "Déclaration URSSAF", systemImage: "building.columns.fill", tint: .indigo) {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.label.capitalizedFirst).font(.title3.weight(.semibold))
                Group {
                    if declared {
                        Label("Déclarée", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else if isCurrent {
                        Text("Période en cours — à déclarer du \(Fmt.day.string(from: p.end)) au \(Fmt.day.string(from: p.deadline))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("À déclarer avant le \(Fmt.day.string(from: p.deadline)) (\(days) jour\(days > 1 ? "s" : ""))")
                            .foregroundStyle(days <= 7 ? Color.red : Color.orange)
                    }
                }
                .font(.subheadline)
            }

            Divider()

            if sum.caByCategory.isEmpty {
                AmountRow(label: "Chiffre d'affaires à déclarer", value: 0, bold: true)
            } else {
                ForEach(ActivityCategory.allCases.filter { (sum.caByCategory[$0] ?? 0) > 0 }) { c in
                    AmountRow(label: "CA à déclarer — \(c.shortLabel)", value: (sum.caByCategory[c] ?? 0).rounded(), bold: true)
                }
            }
            AmountRow(label: "Cotisations sociales", value: sum.cotisations)
            AmountRow(label: "Formation professionnelle (CFP)", value: sum.cfp)
            if s.versementLiberatoire {
                AmountRow(label: "Versement libératoire (impôt)", value: sum.impotVL)
            }
            AmountRow(label: "Total à payer (estimé)", value: sum.urssafTotal, bold: true, color: .indigo)

            HStack {
                Button {
                    UIPasteboard.general.string = String(Int(sum.ca.rounded()))
                } label: {
                    Label("Copier le CA", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                Spacer()
                if !isCurrent || declared {
                    Button {
                        settings.toggleDeclared(p)
                    } label: {
                        Label(declared ? "Annuler" : "Marquer déclarée", systemImage: declared ? "arrow.uturn.backward" : "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(declared ? .gray : .green)
                }
            }
            .font(.subheadline)

            Link(destination: URL(string: "https://www.autoentrepreneur.urssaf.fr")!) {
                Label("Déclarer sur autoentrepreneur.urssaf.fr", systemImage: "arrow.up.right.square")
                    .font(.footnote)
            }
        }
    }

    private var monthCard: some View {
        let m = monthSummary
        return Card(title: Fmt.monthYear.string(from: now).capitalizedFirst, systemImage: "calendar") {
            Grid(horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    StatTile(title: "CA encaissé", value: m.ca, color: .green)
                    StatTile(title: "Achats", value: m.purchases, color: .red)
                }
                GridRow {
                    StatTile(title: "URSSAF estimé", value: m.urssafTotal, color: .indigo)
                    StatTile(title: "Bénéfice estimé", value: m.profit)
                }
            }
            if m.urssafTotal > 0 {
                Label("Mettez de côté \(Fmt.eur(m.urssafTotal)) pour l'URSSAF.", systemImage: "banknote")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var yearCard: some View {
        let y = yearSummary
        return Card(title: "Année \(String(year))", systemImage: "chart.bar.fill", tint: .green) {
            AmountRow(label: "Chiffre d'affaires encaissé", value: y.ca, bold: true, color: .green)
            ForEach(ActivityCategory.allCases.filter { (y.caByCategory[$0] ?? 0) > 0 && y.caByCategory.count > 1 }) { c in
                AmountRow(label: "  dont \(c.shortLabel)", value: y.caByCategory[c] ?? 0)
            }
            AmountRow(label: "Achats", value: y.purchases, color: .red)
            AmountRow(label: "Cotisations + CFP", value: y.cotisations + y.cfp)
            if s.versementLiberatoire {
                AmountRow(label: "Impôt (versement libératoire)", value: y.impotVL)
            }
            Divider()
            AmountRow(label: "Bénéfice estimé", value: y.profit, bold: true)
            Text("Bénéfice = CA encaissé − achats − sommes versées à l'URSSAF\(s.versementLiberatoire ? "" : " (hors impôt sur le revenu)").")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private struct MonthPoint: Identifiable {
        let id = UUID()
        let month: String
        let kind: String
        let value: Double
    }

    private var chartData: [MonthPoint] {
        (1...12).flatMap { m -> [MonthPoint] in
            let start = Fmt.calendar.date(from: DateComponents(year: year, month: m, day: 1)) ?? now
            let sum = Summary.compute(sales: sales, purchases: purchases, in: Fiscal.monthInterval(containing: start), settings: s)
            let label = Fmt.shortMonth.string(from: start).replacingOccurrences(of: ".", with: "")
            return [MonthPoint(month: label, kind: "CA", value: sum.ca),
                    MonthPoint(month: label, kind: "Achats", value: sum.purchases)]
        }
    }

    private var chartCard: some View {
        Card(title: "Évolution \(String(year))", systemImage: "chart.xyaxis.line", tint: .teal) {
            Chart(chartData) { p in
                BarMark(x: .value("Mois", p.month), y: .value("Montant", p.value))
                    .foregroundStyle(by: .value("Type", p.kind))
                    .position(by: .value("Type", p.kind))
            }
            .chartForegroundStyleScale(["CA": Color.green, "Achats": Color.red.opacity(0.7)])
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(d >= 1000 ? "\(Int(d / 1000)) k" : "\(Int(d))") }
                    }
                }
            }
            .frame(height: 180)
        }
    }

    private var thresholdsCard: some View {
        let y = yearSummary
        let hasServices = y.caServices > 0 || s.mainCategory.isService
        let hasVente = y.caVente > 0 || !s.mainCategory.isService
        return Card(title: "Plafonds \(String(year))", systemImage: "gauge.with.dots.needle.67percent", tint: .orange) {
            if hasServices {
                ThresholdBar(title: "Plafond micro (services)", value: y.caServices, limit: s.plafondServices)
                ThresholdBar(title: "Franchise TVA (services)", value: y.caServices, limit: s.seuilTVAServices)
            }
            if hasVente {
                ThresholdBar(title: "Plafond micro (ventes)", value: hasServices ? y.ca : y.caVente, limit: s.plafondVente)
                ThresholdBar(title: "Franchise TVA (ventes)", value: hasServices ? y.ca : y.caVente, limit: s.seuilTVAVente)
            }
            Text("Au-delà du seuil de franchise, vous devez facturer la TVA. Seuils modifiables dans les réglages.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var pendingCard: some View {
        let total = pendingSales.map(\.amount).reduce(0, +)
        let oldest = pendingSales.map(\.invoiceDate).min()
        return Card(title: "Factures en attente de paiement", systemImage: "hourglass", tint: .orange) {
            AmountRow(label: "\(pendingSales.count) facture\(pendingSales.count > 1 ? "s" : "")", value: total, bold: true, color: .orange)
            if let oldest, Fiscal.daysUntil(oldest) < -30 {
                Label("La plus ancienne date du \(Fmt.day.string(from: oldest)) — pensez à relancer.", systemImage: "bell")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Voir les ventes") { selectedTab = 1 }
                .font(.subheadline)
        }
    }

    private var incomeTaxCard: some View {
        let previous = year - 1
        let sum = Summary.compute(sales: sales, purchases: purchases, in: Fiscal.yearInterval(previous), settings: s)
        return Card(title: "Déclaration de revenus \(String(year)) (revenus \(String(previous)))", systemImage: "doc.text.fill", tint: .purple) {
            if sum.ca == 0 {
                Text("Aucun CA enregistré en \(String(previous)).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("En plus de votre salaire, reportez votre CA brut sur la déclaration complémentaire 2042-C-PRO :")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(ActivityCategory.allCases.filter { (sum.caByCategory[$0] ?? 0) > 0 }) { c in
                    AmountRow(label: "Case \(c.taxBox(versementLiberatoire: s.versementLiberatoire)) — \(c.shortLabel)",
                              value: (sum.caByCategory[c] ?? 0).rounded(), bold: true)
                }
                if s.versementLiberatoire {
                    Text("Avec le versement libératoire, l'impôt est déjà payé : le CA sert seulement au calcul du revenu fiscal de référence.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    AmountRow(label: "Revenu imposable estimé (après abattement)", value: sum.taxableIncome)
                    Text("Les impôts appliquent automatiquement l'abattement (71 % ventes, 50 % services BIC, 34 % BNC). Ce revenu s'ajoute à votre salaire.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ThresholdBar: View {
    let title: String
    let value: Double
    let limit: Double

    private var ratio: Double { limit > 0 ? value / limit : 0 }
    private var color: Color { ratio >= 1 ? .red : (ratio >= 0.8 ? .orange : .green) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Fmt.eur(value)) / \(Fmt.eur(limit))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(ratio, 1))
                .tint(color)
        }
    }
}
