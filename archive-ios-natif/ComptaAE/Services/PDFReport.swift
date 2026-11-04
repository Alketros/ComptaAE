import UIKit

/// Petit moteur de mise en page PDF : titres, paragraphes et tableaux paginés (A4 paysage).
final class PDFLayout {
    struct Column {
        let title: String
        let weight: CGFloat
        var align: NSTextAlignment = .left
    }

    let page = CGRect(x: 0, y: 0, width: 842, height: 595)
    let margin: CGFloat = 32
    private let context: UIGraphicsPDFRendererContext
    private var y: CGFloat = 0
    private var pageNumber = 0
    private let footer: String

    var contentWidth: CGFloat { page.width - 2 * margin }

    init(context: UIGraphicsPDFRendererContext, footer: String) {
        self.context = context
        self.footer = footer
        newPage()
    }

    func newPage() {
        context.beginPage()
        pageNumber += 1
        y = margin
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray]
        let text = "\(footer) — page \(pageNumber)" as NSString
        text.draw(at: CGPoint(x: margin, y: page.height - margin + 10), withAttributes: attrs)
    }

    func ensure(_ height: CGFloat) {
        if y + height > page.height - margin { newPage() }
    }

    func space(_ h: CGFloat) { y += h }

    func title(_ s: String, size: CGFloat = 18) {
        ensure(size + 30)
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: UIColor.black]
        (s as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        y += size + 8
    }

    func text(_ s: String, size: CGFloat = 10, bold: Bool = false, color: UIColor = .darkGray) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = (s as NSString).boundingRect(with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                                                options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        ensure(rect.height + 4)
        (s as NSString).draw(with: CGRect(x: margin, y: y, width: contentWidth, height: rect.height + 2),
                             options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        y += rect.height + 4
    }

    /// Paires libellé / valeur sur deux colonnes
    func keyValues(_ pairs: [(String, String)]) {
        let rowH: CGFloat = 15
        for (k, v) in pairs {
            ensure(rowH)
            cell(k, x: margin, width: 260, height: rowH, font: .systemFont(ofSize: 10), align: .left)
            cell(v, x: margin + 260, width: 140, height: rowH, font: .boldSystemFont(ofSize: 10), align: .right)
            y += rowH
        }
    }

    func table(_ columns: [Column], rows: [[String]], total: [String]? = nil, emptyMessage: String = "Aucune écriture sur la période.") {
        let rowH: CGFloat = 16
        let totalWeight = columns.map(\.weight).reduce(0, +)
        let widths = columns.map { $0.weight / totalWeight * contentWidth }

        func drawHeader() {
            ensure(rowH * 2)
            UIColor(red: 0.86, green: 0.90, blue: 0.95, alpha: 1).setFill()
            UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: rowH))
            var x = margin
            for (i, c) in columns.enumerated() {
                cell(c.title, x: x, width: widths[i], height: rowH, font: .boldSystemFont(ofSize: 8.5), align: c.align)
                x += widths[i]
            }
            y += rowH
        }

        drawHeader()
        if rows.isEmpty {
            text(emptyMessage, size: 9, color: .gray)
        }
        for (r, row) in rows.enumerated() {
            if y + rowH > page.height - margin {
                newPage()
                drawHeader()
            }
            if r % 2 == 1 {
                UIColor(white: 0.96, alpha: 1).setFill()
                UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: rowH))
            }
            var x = margin
            for (i, c) in columns.enumerated() {
                cell(i < row.count ? row[i] : "", x: x, width: widths[i], height: rowH, font: .systemFont(ofSize: 8.5), align: c.align)
                x += widths[i]
            }
            y += rowH
        }
        if let total {
            ensure(rowH)
            UIColor.black.setFill()
            UIRectFill(CGRect(x: margin, y: y, width: contentWidth, height: 0.7))
            var x = margin
            for (i, c) in columns.enumerated() {
                cell(i < total.count ? total[i] : "", x: x, width: widths[i], height: rowH, font: .boldSystemFont(ofSize: 9), align: c.align)
                x += widths[i]
            }
            y += rowH
        }
        y += 10
    }

    private func cell(_ s: String, x: CGFloat, width: CGFloat, height: CGFloat, font: UIFont, align: NSTextAlignment) {
        let p = NSMutableParagraphStyle()
        p.alignment = align
        p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: p]
        let rect = CGRect(x: x + 3, y: y + (height - font.lineHeight) / 2, width: width - 6, height: font.lineHeight + 1)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs, context: nil)
    }
}
