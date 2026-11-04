import Foundation

/// ZIP minimaliste (fichiers « stockés », sans compression) — suffisant pour
/// fabriquer un .xlsx, un dossier d'export et les sauvegardes de l'app.
struct ZipWriter {
    private struct Entry { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private var data = Data()
    private var entries: [Entry] = []
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        dosTime = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        dosDate = UInt16((((c.year ?? 2026) - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        data.appendLE(UInt32(0x04034b50))
        data.appendLE(UInt16(20))          // version
        data.appendLE(UInt16(0x0800))      // UTF-8
        data.appendLE(UInt16(0))           // stockage
        data.appendLE(dosTime)
        data.appendLE(dosDate)
        data.appendLE(crc)
        data.appendLE(UInt32(content.count))
        data.appendLE(UInt32(content.count))
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(0))
        data.append(name)
        data.append(content)
        entries.append(Entry(name: name, crc: crc, size: UInt32(content.count), offset: offset))
    }

    mutating func add(_ path: String, _ text: String) { add(path, Data(text.utf8)) }

    func finalize() -> Data {
        var out = data
        let cdStart = UInt32(out.count)
        for e in entries {
            out.appendLE(UInt32(0x02014b50))
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(20))
            out.appendLE(UInt16(0x0800))
            out.appendLE(UInt16(0))
            out.appendLE(dosTime)
            out.appendLE(dosDate)
            out.appendLE(e.crc)
            out.appendLE(e.size)
            out.appendLE(e.size)
            out.appendLE(UInt16(e.name.count))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt16(0))
            out.appendLE(UInt32(0))
            out.appendLE(e.offset)
            out.append(e.name)
        }
        let cdSize = UInt32(out.count) - cdStart
        out.appendLE(UInt32(0x06054b50))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(0))
        out.appendLE(UInt16(entries.count))
        out.appendLE(UInt16(entries.count))
        out.appendLE(cdSize)
        out.appendLE(cdStart)
        out.appendLE(UInt16(0))
        return out
    }
}

/// Lecture des ZIP « stockés » produits par ZipWriter (restauration de sauvegarde).
enum ZipReader {
    static func entries(_ data: Data) -> [String: Data] {
        let bytes = [UInt8](data)
        var result: [String: Data] = [:]
        var i = 0
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        while i + 30 <= bytes.count, u32(i) == 0x04034b50 {
            let method = u16(i + 8)
            let size = u32(i + 18)
            let nameLen = u16(i + 26)
            let extraLen = u16(i + 28)
            let nameStart = i + 30
            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + size <= bytes.count else { break }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLen], as: UTF8.self)
            if method == 0 {
                result[name] = Data(bytes[dataStart..<dataStart + size])
            }
            i = dataStart + size
        }
        return result
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
