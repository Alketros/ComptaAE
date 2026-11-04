import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

enum ImportAction: Equatable {
    case manual, pdf, scan, photo
}

/// Menu « + » commun aux ventes et aux achats.
struct AddEntryMenu: View {
    @Binding var action: ImportAction?

    var body: some View {
        Menu {
            Button { action = .manual } label: { Label("Saisie manuelle", systemImage: "square.and.pencil") }
            Button { action = .pdf } label: { Label("Importer un PDF", systemImage: "doc.badge.plus") }
            if VNDocumentCameraViewController.isSupported {
                Button { action = .scan } label: { Label("Scanner un document", systemImage: "doc.viewfinder") }
            }
            Button { action = .photo } label: { Label("Depuis Photos", systemImage: "photo") }
        } label: {
            Image(systemName: "plus.circle.fill").font(.title3)
        }
    }
}

/// Gère l'import d'un document (fichier, scan, photo), l'extraction des infos,
/// puis ouvre le formulaire pré-rempli via `draft`.
struct EntryImportModifier: ViewModifier {
    let kind: DocumentKind
    @Binding var action: ImportAction?
    @Binding var draft: EntryDraft?
    @Environment(SettingsStore.self) private var settings

    @State private var showImporter = false
    @State private var showScanner = false
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var processing = false
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: action) { _, newValue in
                guard let newValue else { return }
                action = nil
                switch newValue {
                case .manual: draft = EntryDraft()
                case .pdf: showImporter = true
                case .scan: showScanner = true
                case .photo: showPhotos = true
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image]) { result in
                switch result {
                case .success(let url):
                    do { process(try AttachmentStore.importFile(at: url)) }
                    catch { errorMessage = error.localizedDescription }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        saveImages([image])
                    } else {
                        errorMessage = "Impossible de charger la photo."
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                DocumentScannerView(onFinish: { images in
                    showScanner = false
                    saveImages(images)
                }, onCancel: { showScanner = false })
                .ignoresSafeArea()
            }
            .overlay {
                if processing {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Lecture du document…").font(.subheadline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Import impossible", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    private func saveImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        do {
            let name = try AttachmentStore.save(data: AttachmentStore.pdf(from: images), ext: "pdf")
            process(name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func process(_ attachmentName: String) {
        processing = true
        let useAI = settings.s.useAI
        Task {
            let info = await DocumentExtractor.extract(pdfURL: AttachmentStore.url(for: attachmentName), kind: kind, useAI: useAI)
            processing = false
            draft = info.draft(attachmentName: attachmentName)
        }
    }
}

extension View {
    func entryImport(kind: DocumentKind, action: Binding<ImportAction?>, draft: Binding<EntryDraft?>) -> some View {
        modifier(EntryImportModifier(kind: kind, action: action, draft: draft))
    }
}
