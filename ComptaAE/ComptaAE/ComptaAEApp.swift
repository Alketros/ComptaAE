import SwiftUI
import SwiftData

@main
struct ComptaAEApp: App {
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(\.locale, Locale(identifier: "fr_FR"))
        }
        .modelContainer(for: [Sale.self, Purchase.self])
    }
}

struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var locked = true
    @State private var authenticating = false

    var body: some View {
        TabView(selection: $tab) {
            DashboardView(selectedTab: $tab)
                .tabItem { Label("Accueil", systemImage: "house.fill") }
                .tag(0)
            SalesListView()
                .tabItem { Label("Ventes", systemImage: "eurosign.circle.fill") }
                .tag(1)
            PurchasesListView()
                .tabItem { Label("Achats", systemImage: "cart.fill") }
                .tag(2)
            ExportView()
                .tabItem { Label("Export", systemImage: "square.and.arrow.up.fill") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .overlay {
            if settings.s.faceIDEnabled && locked {
                LockView(unlock: unlock)
            }
        }
        .onAppear {
            if settings.s.faceIDEnabled { unlock() } else { locked = false }
            NotificationScheduler.reschedule(settings.s)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if settings.s.faceIDEnabled { locked = true }
            case .active:
                if settings.s.faceIDEnabled && locked { unlock() }
            default:
                break
            }
        }
        .onChange(of: settings.s.faceIDEnabled) { _, on in
            if !on { locked = false }
        }
    }

    private func unlock() {
        guard !authenticating else { return }
        authenticating = true
        Biometrics.authenticate { ok in
            authenticating = false
            if ok { locked = false }
        }
    }
}
