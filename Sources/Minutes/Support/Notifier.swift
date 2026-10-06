import Foundation
import UserNotifications

/// Actionable notifications: recording started (Stop & Save / Discard), "take notes?" for apps that
/// ask first (Record / Always / Not now), and notes ready (Open).
@MainActor
final class Notifier: NSObject {
    enum Action {
        case stopAndSave
        case discard
        case record(appID: String)
        case alwaysRecord(appID: String)
        case notNow(appID: String)
        case open(meetingID: UUID)
    }

    static let shared = Notifier()
    var onAction: ((Action) -> Void)?

    private let center = UNUserNotificationCenter.current()
    static let recordingID = "minutes.recording"
    static let askID = "minutes.ask"

    func setUp() {
        let stop = UNNotificationAction(identifier: "stop", title: "Stop & Save")
        let discard = UNNotificationAction(identifier: "discard", title: "Discard", options: [.destructive])
        let record = UNNotificationAction(identifier: "record", title: "Record")
        let always = UNNotificationAction(identifier: "always", title: "Always for this app")
        let notNow = UNNotificationAction(identifier: "notnow", title: "Not now")
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "recording", actions: [stop, discard], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ask", actions: [record, always, notNow], intentIdentifiers: []),
            UNNotificationCategory(identifier: "ready", actions: [open], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    func recordingStarted(appName: String?) {
        post(id: Self.recordingID, category: "recording",
             title: "Taking notes" + (appName.map { " · \($0)" } ?? ""),
             body: "Minutes is recording this call. It stops when the call ends.")
    }

    func ask(appID: String, appName: String) {
        post(id: Self.askID, category: "ask", title: "Take notes for this \(appName) call?",
             body: "Nothing is recorded until you choose Record.", userInfo: ["appID": appID])
    }

    func notesReady(meetingID: UUID, title: String) {
        post(id: "minutes.ready.\(meetingID.uuidString)", category: "ready", title: "Notes ready", body: title,
             userInfo: ["meetingID": meetingID.uuidString])
    }

    func problem(_ text: String) {
        post(id: "minutes.problem", category: nil, title: "Minutes", body: text)
    }

    func remove(_ id: String) {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    private func post(id: String, category: String?, title: String, body: String, userInfo: [String: String] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error { Log.warn("Notification failed: \(error.localizedDescription)") }
        }
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let appID = info["appID"] as? String
        let meetingID = (info["meetingID"] as? String).flatMap(UUID.init)
        let identifier = response.actionIdentifier
        await MainActor.run {
            let action: Action? = switch identifier {
            case "stop": .stopAndSave
            case "discard": .discard
            case "record": appID.map { .record(appID: $0) }
            case "always": appID.map { .alwaysRecord(appID: $0) }
            case "notnow": appID.map { .notNow(appID: $0) }
            case "open", UNNotificationDefaultActionIdentifier:
                meetingID.map { .open(meetingID: $0) } ?? appID.map { .record(appID: $0) }
            default: nil
            }
            if let action { Notifier.shared.onAction?(action) }
        }
    }
}
