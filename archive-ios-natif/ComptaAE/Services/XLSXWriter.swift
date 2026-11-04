import Foundation

/// Générateur de classeur Excel (.xlsx) minimal mais conforme (ouvrable dans Excel, Numbers, LibreOffice).
enum XLSXCell {
    case text(String)
    case bold(String)
    case header(String)
    case money(Double)
    case boldMoney(Double)
    case number(Double)
    case date(Date)
    case sum(column: Int, fromRow: Int, toRow: Int, cached: Double)   // lignes 1-based
    case empty
}

struct XLSXSheet {
    var name: String
    var widths: [Double]
    var rows: [[XLSXCell]]
    var freezeHeader = true
}

enum XLSXWriter {
    // Index des styles dans styles.xml
    private enum Style: Int { case normal = 0, header = 1, date = 2, money = 3, bold = 4, boldMoney = 5 }

    static func data(sheets: [XLSXSheet]) -> Data {
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes(count: sheets.count))
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        zip.add("xl/workbook.xml", workbook(sheets))
        zip.add("xl/_rels/workbook.xml.rels", workbookRels(count: sheets.count))
        zip.add("xl/styles.xml", styles)
        for (i, sheet) in sheets.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", worksheet(sheet))
        }
        return zip.finalize()
    }

    static func columnName(_ index: Int) -> String {   // 0 → A
        var n = index + 1, s = ""
        while n > 0 {
            let r = (n - 1) % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = (n - 1) / 26
        }
        return s
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\t": out += String(ch)
            default:
                if ch.value < 0x20 { continue } // caractères de contrôle interdits en XML
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    private static func excelSerial(_ date: Date) -> Double {
        // Jours depuis le 30/12/1899, à partir des composantes locales de la date
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let d = utc.date(from: c) ?? date
        let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return (d.timeIntervalSince(base) / 86400).rounded()
    }

    private static func num(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        return String(format: "%.2f", r)
    }

    private static func worksheet(_ sheet: XLSXSheet) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        if sheet.freezeHeader {
            xml += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        }
        if !sheet.widths.isEmpty {
            xml += "<cols>"
            for (i, w) in sheet.widths.enumerated() {
                xml += #"<col min="\#(i + 1)" max="\#(i + 1)" width="\#(w)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            xml += #"<row r="\#(r + 1)">"#
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                switch cell {
                case .empty:
                    continue
                case .text(let s):
                    xml += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                case .bold(let s):
                    xml += #"<c r="\#(ref)" s="\#(Style.bold.rawValue)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                case .header(let s):
                    xml += #"<c r="\#(ref)" s="\#(Style.header.rawValue)" t="inlineStr"><is><t xml:space="preserve">\#(escape(s))</t></is></c>"#
                case .money(let v):
                    xml += #"<c r="\#(ref)" s="\#(Style.money.rawValue)"><v>\#(num(v))</v></c>"#
                case .boldMoney(let v):
                    xml += #"<c r="\#(ref)" s="\#(Style.boldMoney.rawValue)"><v>\#(num(v))</v></c>"#
                case .number(let v):
                    xml += #"<c r="\#(ref)"><v>\#(v)</v></c>"#
                case .date(let d):
                    xml += #"<c r="\#(ref)" s="\#(Style.date.rawValue)"><v>\#(Int(excelSerial(d)))</v></c>"#
                case .sum(let col, let from, let to, let cached):
                    let letter = columnName(col)
                    let formula = to >= from ? "SUM(\(letter)\(from):\(letter)\(to))" : "0"
                    xml += #"<c r="\#(ref)" s="\#(Style.boldMoney.rawValue)"><f>\#(formula)</f><v>\#(num(cached))</v></c>"#
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func sheetName(_ s: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        let cleaned = String(s.unicodeScalars.filter { !forbidden.contains($0) })
        return String(cleaned.prefix(31))
    }

    private static func workbook(_ sheets: [XLSXSheet]) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
        for (i, s) in sheets.enumerated() {
            xml += #"<sheet name="\#(escape(sheetName(s.name)))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private static func workbookRels(count: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for i in 1...max(count, 1) {
            xml += #"<Relationship Id="rId\#(i)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(i).xml"/>"#
        }
        xml += #"<Relationship Id="rId\#(count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        xml += "</Relationships>"
        return xml
    }

    private static func contentTypes(count: Int) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
        for i in 1...max(count, 1) {
            xml += #"<Override PartName="/xl/worksheets/sheet\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }
        xml += "</Types>"
        return xml
    }

    private static let styles = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0.00\ &quot;€&quot;"/><numFmt numFmtId="165" formatCode="dd/mm/yyyy"/></numFmts>
    <fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
    <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
    <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="6">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
    <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="164" fontId="1" fillId="0" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1"/>
    </cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """#
}
