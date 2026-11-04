import Foundation
import UserNotifications

enum NotificationScheduler {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Programme des rappels 7 jours et 1 jour avant chaque échéance URSSAF (sur ~1 an).
    static func reschedule(_ settings: AppSettings) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard settings.remindersEnabled else { return }

        let cal = Fmt.calendar
        let now = Date()
        var p = Fiscal.previous(Fiscal.period(containing: now, frequency: settings.frequency), frequency: settings.frequency)
        let count = settings.frequency == .monthly ? 13 : 5

        for _ in 0..<count {
            if !settings.declaredPeriods.contains(p.key) {
                for daysBefore in [7, 1] {
                    guard let day = cal.date(byAdding: .day, value: -daysBefore, to: p.deadline),
                          let fire = cal.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                          fire > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "Déclaration URSSAF"
                    content.body = daysBefore == 1
                        ? "Dernier jour demain pour déclarer votre CA de \(p.label)."
                        : "Pensez à déclarer votre CA de \(p.label) avant le \(Fmt.day.string(from: p.deadline))."
                    content.sound = .default
                    let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                    center.add(UNNotificationRequest(identifier: "urssaf-\(p.key)-\(daysBefore)", content: content, trigger: trigger))
                }
            }
            p = Fiscal.next(p, frequency: settings.frequency)
        }
    }
}
