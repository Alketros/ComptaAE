import Foundation
import UIKit

/// Stocke les justificatifs (PDF) dans Documents/Justificatifs.
/// Le dossier est visible dans l'app Fichiers (« Sur mon iPhone > Compta AE »).
enum AttachmentStore {
    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Justificatifs", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    static func exists(_ name: String?) -> Bool {
        guard let name else { return false }
        return FileManager.default.fileExists(atPath: url(for: name).path)
    }

    @discardableResult
    static func save(data: Data, ext: String = "pdf") throws -> String {
        let name = "\(UUID().uuidString).\(ext)"
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    /// Copie un fichier choisi via le sélecteur de fichiers (accès « security scoped »).
    /// Les images sont converties en PDF.
    static func importFile(at source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        if source.pathExtension.lowercased() == "pdf" {
            return try save(data: data, ext: "pdf")
        }
        if let image = UIImage(data: data) {
            return try save(data: pdf(from: [image]), ext: "pdf")
        }
        return try save(data: data, ext: source.pathExtension.isEmpty ? "dat" : source.pathExtension)
    }

    static func delete(_ name: String?) {
        guard let name else { return }
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Assemble des images (scan, photo) en un PDF, une page par image, au format A4.
    static func pdf(from images: [UIImage]) -> Data {
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: a4)
        return renderer.pdfData { ctx in
            for image in images {
                ctx.beginPage()
                let size = image.size
                guard size.width > 0, size.height > 0 else { continue }
                let scale = min(a4.width / size.width, a4.height / size.height)
                let w = size.width * scale, h = size.height * scale
                image.draw(in: CGRect(x: (a4.width - w) / 2, y: (a4.height - h) / 2, width: w, height: h))
            }
        }
    }
}
