import Foundation
import PDFKit
import Vision
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum DocumentKind { case sale, purchase }

struct ExtractedInfo {
    var date: Date?
    var amount: Double?
    var vat: Double?
    var party: String?
    var invoiceNumber: String?
    var label: String?
    var purchaseCategory: PurchaseCategory?
    var usedAI = false

    func draft(attachmentName: String?) -> EntryDraft {
        var d = EntryDraft()
        d.attachmentName = attachmentName
        d.party = party
        d.label = label
        d.amount = amount
        d.vat = vat
        d.date = date
        d.invoiceNumber = invoiceNumber
        d.purchaseCategory = purchaseCategory
        d.fromDocument = true
        d.usedAI = usedAI
        return d
    }
}

/// Extraction des informations d'une facture : texte du PDF (ou OCR si PDF scanné),
/// puis analyse par règles. Si Apple Intelligence est disponible (iOS 26+),
/// le modèle local affine le résultat. Tout reste sur l'iPhone.
enum DocumentExtractor {

    static func extract(pdfURL: URL, kind: DocumentKind, useAI: Bool) async -> ExtractedInfo {
        let text = await Task.detached(priority: .userInitiated) { DocumentExtractor.fullText(pdfURL: pdfURL) }.value
        var info = parse(text: text, kind: kind)
        #if canImport(FoundationModels)
        if useAI, #available(iOS 26.0, *) {
            if let ai = await AIExtractor.extract(text: text, kind: kind) {
                info = merge(info, ai: ai, text: text)
            }
        }
        #endif
        return info
    }

    // MARK: Texte

    static func fullText(pdfURL: URL) -> String {
        guard let doc = PDFDocument(url: pdfURL) else { return "" }
        let text = doc.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30 {
            return text
        }
        // PDF scanné (image) → OCR
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 4) {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale = 2000 / max(bounds.width, bounds.height, 1)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            if let cg = page.thumbnail(of: size, for: .mediaBox).cgImage {
                pages.append(recognizeText(cg))
            }
        }
        return pages.joined(separator: "\n")
    }

    /// OCR Vision, en reconstituant les lignes (les libellés et montants alignés sont regroupés).
    static func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let observations = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            return (obs.boundingBox, s)
        }
        // Tri haut → bas (Vision : origine en bas à gauche)
        let sorted = observations.sorted { $0.box.midY > $1.box.midY }
        var lines: [[(box: CGRect, text: String)]] = []
        for o in sorted {
            if let last = lines.last, let ref = last.first,
               abs(ref.box.midY - o.box.midY) < max(ref.box.height, o.box.height) * 0.5 {
                lines[lines.count - 1].append(o)
            } else {
                lines.append([o])
            }
        }
        return lines
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: "  ") }
            .joined(separator: "\n")
    }

    // MARK: Analyse par règles

    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Fmt.fr).lowercased()
    }

    static func parse(text: String, kind: DocumentKind) -> ExtractedInfo {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let lines = rawLines.map(normalize)

        var info = ExtractedInfo()
        info.amount = findTotal(lines)
        info.vat = findVAT(lines, total: info.amount)
        info.date = findDate(lines)
        info.invoiceNumber = findInvoiceNumber(rawLines)
        switch kind {
        case .purchase:
            info.party = findSupplier(rawLines, normalized: lines)
            info.purchaseCategory = guessCategory(normalize(text))
        case .sale:
            info.party = findClient(rawLines, normalized: lines)
        }
        return info
    }

    // Montants

    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.,])(\d{1,3}(?:[   ]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{3})*(?:[.,]\d{1,2})?)(?![.,]?\d)(\s*%)?"#)

    static func amounts(in line: String) -> [Double] {
        let cleaned = stripDates(line)
        let ns = cleaned as NSString
        return amountRegex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            if m.range(at: 2).location != NSNotFound { return nil } // pourcentage
            guard let v = toDouble(ns.substring(with: m.range(at: 1))), v > 0, v < 10_000_000 else { return nil }
            return v
        }
    }

    static func toDouble(_ raw: String) -> Double? {
        var s = raw.filter { !" \u{00A0}\u{202F}".contains($0) }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            let decimal: Character = s.lastIndex(of: ",")! > s.lastIndex(of: ".")! ? "," : "."
            let thousands: Character = decimal == "," ? "." : ","
            s.removeAll { $0 == thousands }
            s = s.replacingOccurrences(of: String(decimal), with: ".")
        } else if hasComma || hasDot {
            let sep: Character = hasComma ? "," : "."
            let parts = s.split(separator: sep, omittingEmptySubsequences: false)
            if parts.count > 2 || (parts.count == 2 && parts[1].count == 3) {
                s.removeAll { $0 == sep } // séparateur de milliers
            } else {
                s = s.replacingOccurrences(of: String(sep), with: ".")
            }
        }
        return Double(s)
    }

    private static let totalKeywords = [
        "net a payer", "total ttc", "montant ttc", "total a payer", "montant a payer",
        "reste a payer", "montant total", "total general", "grand total", "amount due",
        "total due", "total paid", "montant regle", "total"
    ]

    static func findTotal(_ lines: [String]) -> Double? {
        for keyword in totalKeywords {
            var found: [Double] = []
            for (i, line) in lines.enumerated() where line.contains(keyword) {
                if keyword == "total" {
                    let excluded = ["sous-total", "sous total", "subtotal", " ht", "hors tax", "tva", "vat", "remise"]
                    if excluded.contains(where: { line.contains($0) }) || line.hasSuffix("ht") { continue }
                }
                var a = amounts(in: line)
                if a.isEmpty, i + 1 < lines.count { a = amounts(in: lines[i + 1]) }
                if let m = a.max() { found.append(m) }
            }
            if let m = found.max() { return round2(m) }
        }
        // Repli : plus grand montant sur une ligne contenant € / eur
        let euroLines = lines.filter { $0.contains("€") || $0.contains("eur") }
        return euroLines.flatMap(amounts).max().map(round2)
    }

    static func findVAT(_ lines: [String], total: Double?) -> Double? {
        let candidates = lines.filter {
            ($0.contains("tva") || $0.contains("vat")) &&
            !$0.contains("intracom") && !$0.contains("293") && !$0.contains("non applicable") &&
            !$0.contains("numero") && !$0.contains("n°")
        }
        let preferred = candidates.filter { $0.contains("total") || $0.contains("montant") }
        for group in [preferred, candidates] {
            let values = group.flatMap(amounts).filter { v in
                guard let t = total else { return true }
                return v < t * 0.5
            }
            if let v = values.max() { return round2(v) }
        }
        return nil
    }

    // Dates

    private static let numericDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{4}|\d{2})(?!\d)"#)
    private static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    private static let textDate = try! NSRegularExpression(pattern:
        #"(?<!\d)(\d{1,2})(?:er)?\s+(janv(?:ier)?|fevr?(?:ier)?|mars|avr(?:il)?|mai|juin|juil(?:let)?|aout|sept(?:embre)?|oct(?:obre)?|nov(?:embre)?|dec(?:embre)?|january|february|march|april|may|june|july|august|september|october|november|december)\.?\s+(\d{4})"#)

    static func stripDates(_ line: String) -> String {
        var s = line
        for r in [numericDate, isoDate, textDate] {
            s = r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s
    }

    static func monthNumber(_ m: String) -> Int? {
        if m.hasPrefix("juil") || m.hasPrefix("jul") { return 7 }
        if m.hasPrefix("juin") || m.hasPrefix("jun") { return 6 }
        let map: [String: Int] = ["jan": 1, "fev": 2, "feb": 2, "mar": 3, "avr": 4, "apr": 4, "mai": 5, "may": 5,
                                  "aou": 8, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
        return map[String(m.prefix(3))]
    }

    static func dates(in line: String) -> [Date] {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        var result: [Date] = []
        func make(_ y: Int, _ m: Int, _ d: Int) {
            let year = y < 100 ? 2000 + y : y
            guard (2000...(Fiscal.currentYear() + 1)).contains(year), (1...12).contains(m), (1...31).contains(d),
                  let date = Fmt.calendar.date(from: DateComponents(year: year, month: m, day: d, hour: 12)) else { return }
            result.append(date)
        }
        for m in isoDate.matches(in: line, range: range) {
            make(Int(ns.substring(with: m.range(at: 1))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 0, Int(ns.substring(with: m.range(at: 3))) ?? 0)
        }
        for m in numericDate.matches(in: line, range: range) {
            make(Int(ns.substring(with: m.range(at: 3))) ?? 0, Int(ns.substring(with: m.range(at: 2))) ?? 0, Int(ns.substring(with: m.range(at: 1))) ?? 0)
        }
        for m in textDate.matches(in: line, range: range) {
            if let month = monthNumber(ns.substring(with: m.range(at: 2))) {
                make(Int(ns.substring(with: m.range(at: 3))) ?? 0, month, Int(ns.substring(with: m.range(at: 1))) ?? 0)
            }
        }
        return result
    }

    static func findDate(_ lines: [String]) -> Date? {
        let preferred = ["date de facture", "date facture", "date d'emission", "date d emission", "date d'émission",
                         "facture du", "emise le", "invoice date", "date de la facture", "date :", "date:", "date"]
        let excluded = ["echeance", "due", "livraison", "naissance", "expiration", "validite", "limite"]
        for key in preferred {
            for (i, line) in lines.enumerated() where line.contains(key) && !excluded.contains(where: { line.contains($0) }) {
                if let d = dates(in: line).first { return d }
                if i + 1 < lines.count, let d = dates(in: lines[i + 1]).first { return d }
            }
        }
        for line in lines where !excluded.contains(where: { line.contains($0) }) {
            if let d = dates(in: line).first { return d }
        }
        return nil
    }

    // Numéro de facture

    private static let invoiceRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:n[°o]\s*(?:de\s*)?facture|num[ée]ro\s*(?:de\s*)?facture|invoice\s*(?:number|no\.?|#|n[°o]))\s*[:.]?\s*([A-Z0-9][A-Z0-9\-_/.]*\d[A-Z0-9\-_/.]*)"#, options: .caseInsensitive),
        try! NSRegularExpression(pattern: #"(?:facture|invoice|re[çc]u|receipt|avoir|commande)\s*(?:n[°o]\.?|num[ée]ro|number|no\.?|#)?\s*[:.]?\s*([A-Z0-9][A-Z0-9\-_/.]*\d[A-Z0-9\-_/.]*)"#, options: .caseInsensitive)
    ]

    static func findInvoiceNumber(_ lines: [String]) -> String? {
        for r in invoiceRegexes {
            for line in lines {
                let ns = line as NSString
                for m in r.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    var v = ns.substring(with: m.range(at: 1))
                    while let l = v.last, ".-/_".contains(l) { v.removeLast() }
                    if v.count >= 2, dates(in: v).isEmpty { return v }
                }
            }
        }
        return nil
    }

    // Tiers

    private static let legalForms = try! NSRegularExpression(pattern: #"\b(sas|sasu|sarl|eurl|sa|sci|snc|inc|ltd|llc|gmbh|limited|corp)\b"#)

    static func findSupplier(_ raw: [String], normalized: [String]) -> String? {
        let banned = ["facture", "invoice", "date", "page", "client", "devis", "recu", "ticket", "tel", "siret",
                      "siren", "capital", "rcs", "@", "http", "adresse", "commande", "total", "tva", "bon de"]
        func acceptable(_ i: Int) -> Bool {
            let n = normalized[i]
            let letters = n.filter(\.isLetter).count
            return letters >= 3 && n.count <= 60 && !banned.contains(where: { n.contains($0) }) && amounts(in: n).isEmpty
        }
        let top = Array(0..<min(raw.count, 15))
        for i in top where legalForms.firstMatch(in: normalized[i], range: NSRange(location: 0, length: (normalized[i] as NSString).length)) != nil {
            let n = normalized[i]
            if n.count <= 60 && !n.contains("capital") && !n.contains("rcs") { return clean(raw[i]) }
        }
        // Nom de domaine (www.exemple.fr)
        if let r = try? NSRegularExpression(pattern: #"www\.([a-z0-9\-]+)\."#),
           let joined = Optional(normalized.joined(separator: " ")),
           let m = r.firstMatch(in: joined, range: NSRange(location: 0, length: (joined as NSString).length)) {
            let domain = (joined as NSString).substring(with: m.range(at: 1))
            for i in top where acceptable(i) && normalized[i].contains(domain) { return clean(raw[i]) }
        }
        for i in top where acceptable(i) { return clean(raw[i]) }
        return nil
    }

    static func findClient(_ raw: [String], normalized: [String]) -> String? {
        let keys = ["facture a", "factue a", "facturer a", "adresse de facturation", "destinataire", "bill to", "billed to", "client"]
        let refs = ["n° client", "no client", "numero client", "code client", "ref client", "reference client", "client n"]
        for key in keys {
            for (i, n) in normalized.enumerated() where n.contains(key) && !refs.contains(where: { n.contains($0) }) {
                if let colon = raw[i].firstIndex(of: ":") {
                    let after = clean(String(raw[i][raw[i].index(after: colon)...]))
                    if after.filter(\.isLetter).count >= 2 { return after }
                }
                if i + 1 < raw.count, raw[i + 1].filter(\.isLetter).count >= 2 { return clean(raw[i + 1]) }
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-–|")))
    }

    // Catégorie d'achat

    private static let categoryKeywords: [(PurchaseCategory, [String])] = [
        (.telecom, ["orange", "sfr", "bouygues", "free mobile", "freebox", "sosh", "red by sfr", "forfait mobile", "box internet"]),
        (.deplacement, ["sncf", "ouigo", "uber", "bolt", "totalenergies", "carburant", "gazole", "sans plomb", "peage", "parking", "vinci autoroutes", "air france", "blablacar", "billet de train", "taxi"]),
        (.logiciel, ["abonnement", "subscription", "adobe", "microsoft", "google workspace", "icloud", "notion", "github", "licence", "ovh", "o2switch", "hebergement", "nom de domaine", "figma", "canva", "openai", "anthropic", "dropbox", "spotify"]),
        (.formation, ["formation", "udemy", "coursera", "openclassrooms"]),
        (.publicite, ["publicite", "facebook ads", "google ads", "vistaprint", "cartes de visite", "impression"]),
        (.banqueAssurance, ["frais bancaires", "qonto", "shine", "assurance", "cotisation bancaire", "rc pro"]),
        (.materiel, ["ordinateur", "macbook", "ecran", "clavier", "souris", "imprimante", "ldlc", "darty", "boulanger", "materiel"]),
        (.fournitures, ["fournitures", "papeterie", "bureau vallee", "cartouche", "ramette"])
    ]

    static func guessCategory(_ normalizedText: String) -> PurchaseCategory? {
        for (cat, words) in categoryKeywords {
            for w in words {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: w) + "\\b"
                if normalizedText.range(of: pattern, options: .regularExpression) != nil { return cat }
            }
        }
        return nil
    }

    // MARK: Fusion avec le résultat IA

    struct AIResult {
        var party: String
        var label: String
        var invoiceNumber: String
        var date: String
        var total: Double
        var vat: Double
    }

    static func merge(_ h: ExtractedInfo, ai: AIResult, text: String) -> ExtractedInfo {
        var r = h
        r.usedAI = true
        let trimmedParty = ai.party.trimmingCharacters(in: .whitespaces)
        if !trimmedParty.isEmpty { r.party = trimmedParty }
        let label = ai.label.trimmingCharacters(in: .whitespaces)
        if !label.isEmpty { r.label = label }
        if !ai.invoiceNumber.isEmpty, text.contains(ai.invoiceNumber) { r.invoiceNumber = ai.invoiceNumber }

        // Les valeurs chiffrées de l'IA ne sont retenues que si elles figurent réellement dans le document.
        let allAmounts = text.components(separatedBy: .newlines).flatMap { amounts(in: normalize($0)) }
        if ai.total > 0, allAmounts.contains(where: { abs($0 - ai.total) < 0.01 }) { r.amount = round2(ai.total) }
        if ai.vat > 0, allAmounts.contains(where: { abs($0 - ai.vat) < 0.01 }) { r.vat = round2(ai.vat) }
        if let d = Fmt.isoDay.date(from: ai.date) {
            let allDates = text.components(separatedBy: .newlines).flatMap { dates(in: normalize($0)) }
            if allDates.contains(where: { Fmt.calendar.isDate($0, inSameDayAs: d) }) {
                r.date = Fmt.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
            }
        }
        return r
    }
}

// MARK: - Apple Intelligence (modèle local, iOS 26+)

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct AIInvoice {
    @Guide(description: "Nom de l'entreprise ou de la personne qui a émis la facture (le vendeur). Vide si inconnu.")
    var emetteur: String
    @Guide(description: "Nom de l'entreprise ou de la personne à qui la facture est adressée (l'acheteur). Vide si inconnu.")
    var destinataire: String
    @Guide(description: "Numéro de la facture tel qu'écrit dans le document. Vide si inconnu.")
    var numeroFacture: String
    @Guide(description: "Date d'émission de la facture au format AAAA-MM-JJ. Vide si inconnue.")
    var dateFacture: String
    @Guide(description: "Montant total TTC à payer, en euros. 0 si inconnu.")
    var montantTTC: Double
    @Guide(description: "Montant total de la TVA en euros. 0 si absent.")
    var montantTVA: Double
    @Guide(description: "Résumé très court (2 à 6 mots) de ce qui est acheté ou vendu, en français.")
    var objet: String
}

@available(iOS 26.0, *)
enum AIExtractor {
    static func extract(text: String, kind: DocumentKind) async -> DocumentExtractor.AIResult? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let trimmed = String(text.prefix(6000))
        guard trimmed.count > 20 else { return nil }
        let session = LanguageModelSession(instructions: "Tu extrais les informations d'une facture française. Réponds uniquement à partir du texte fourni, sans rien inventer.")
        do {
            let response = try await session.respond(to: "Voici le texte d'une facture :\n\n\(trimmed)", generating: AIInvoice.self)
            let inv = response.content
            return DocumentExtractor.AIResult(
                party: kind == .purchase ? inv.emetteur : inv.destinataire,
                label: inv.objet,
                invoiceNumber: inv.numeroFacture,
                date: inv.dateFacture,
                total: inv.montantTTC,
                vat: inv.montantTVA)
        } catch {
            return nil
        }
    }
}
#endif
