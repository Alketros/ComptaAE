import SwiftUI
import UniformTypeIdentifiers
import UIKit
import VisionKit
import LocalAuthentication

// MARK: - Carte de tableau de bord

struct Card<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(tint)
                }
                Text(title).font(.headline)
                Spacer()
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatTile: View {
    let title: String
    let value: Double
    var color: Color = .primary
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.eur(value))
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AmountRow: View {
    let label: String
    let value: Double
    var bold = false
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(bold ? Color.primary : Color.secondary)
            Spacer()
            Text(Fmt.eur(value)).monospacedDigit().foregroundStyle(color)
        }
        .font(bold ? .body.weight(.semibold) : .subheadline)
    }
}

// MARK: - Suggestions (puces)

struct SuggestionChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        Button { onTap(item) } label: {
                            Text(item)
                                .font(.footnote)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Champ montant

struct AmountField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0,00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(maxWidth: 160)
            Text("€").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Partage

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Scanner de documents

struct DocumentScannerView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void
        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { onCancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { onCancel() }
    }
}

// MARK: - Verrouillage Face ID

enum Biometrics {
    static func authenticate(_ completion: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(true) // pas de code ni biométrie configurés : on ne bloque pas l'accès
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Déverrouiller votre comptabilité") { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

struct LockView: View {
    let unlock: () -> Void
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill").font(.system(size: 48)).foregroundStyle(.tint)
                Text("Compta AE est verrouillée").font(.headline)
                Button("Déverrouiller", action: unlock).buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - Ligne justificatif

struct AttachmentSection: View {
    @Binding var attachmentName: String?
    @Binding var previewURL: URL?
    @State private var showImporter = false
    @State private var errorMessage: String?

    var body: some View {
        Section("Justificatif") {
            if let name = attachmentName, AttachmentStore.exists(name) {
                Button {
                    previewURL = AttachmentStore.url(for: name)
                } label: {
                    Label("Voir le document", systemImage: "doc.richtext")
                }
                Button(role: .destructive) {
                    attachmentName = nil
                } label: {
                    Label("Détacher le document", systemImage: "trash")
                }
            } else {
                Button {
                    showImporter = true
                } label: {
                    Label("Joindre un PDF ou une image", systemImage: "paperclip")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image]) { result in
            switch result {
            case .success(let url):
                do { attachmentName = try AttachmentStore.importFile(at: url) }
                catch { errorMessage = error.localizedDescription }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .alert("Erreur", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
