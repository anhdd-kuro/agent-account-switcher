import AppKit
import Foundation
import UserNotifications

extension AppDelegate {
    func configureNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let switchNow = UNNotificationAction(
            identifier: switchNowActionIdentifier,
            title: "Switch Now",
            options: [.foreground]
        )
        let later = UNNotificationAction(identifier: "LATER", title: "Later", options: [])
        let switchCategory = UNNotificationCategory(
            identifier: autoSwitchNotificationCategory,
            actions: [switchNow, later],
            intentIdentifiers: [],
            options: []
        )
        let resumeNow = UNNotificationAction(
            identifier: resumeNowActionIdentifier,
            title: "Resume Now",
            options: [.foreground]
        )
        let cancelResume = UNNotificationAction(identifier: cancelResumeActionIdentifier, title: "Cancel", options: [])
        let resumeCategory = UNNotificationCategory(
            identifier: resumeNotificationCategory,
            actions: [resumeNow, cancelResume],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([switchCategory, resumeCategory])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.refreshNotificationHealth(rebuildVisiblePanel: true)
        }
        refreshNotificationHealth()
    }

    func refreshNotificationHealth(rebuildVisiblePanel: Bool = false) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized:
                    self.notificationHealthTitle = "Allowed"
                    self.notificationHealthColor = .systemGreen
                case .provisional:
                    self.notificationHealthTitle = "Quiet"
                    self.notificationHealthColor = .systemGreen
                case .notDetermined:
                    self.notificationHealthTitle = "Ask"
                    self.notificationHealthColor = .systemOrange
                case .denied:
                    self.notificationHealthTitle = "Off"
                    self.notificationHealthColor = .systemRed
                @unknown default:
                    self.notificationHealthTitle = "Unknown"
                    self.notificationHealthColor = .systemOrange
                }

                if rebuildVisiblePanel, self.accountPanel?.isVisible == true {
                    self.refreshAccountPanelContentIfVisible()
                }
            }
        }
    }

    func sendNotification(
        title: String,
        subtitle: String,
        body: String,
        categoryIdentifier: String? = nil,
        userInfo: [AnyHashable: Any] = [:],
        reportResult: Bool = false
    ) {
        ensureNotificationAuthorization { [weak self] isAuthorized, message in
            guard let self else { return }
            guard isAuthorized else {
                if reportResult {
                    DispatchQueue.main.async {
                        self.showNotificationSettingsAlert(message: message ?? self.notificationSettingsMessage())
                    }
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.userInfo = userInfo
            if let categoryIdentifier {
                content.categoryIdentifier = categoryIdentifier
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "codex-usage-\(UUID().uuidString)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("AI Account Switcher notification failed: \(error.localizedDescription)")
                    if reportResult {
                        DispatchQueue.main.async {
                            self.showNotificationSettingsAlert(message: self.notificationSettingsMessage())
                        }
                    }
                } else if reportResult {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.showAlert(title: "Test notification sent", message: "If no banner appeared, check System Settings > Notifications > AI Account Switcher and make sure alerts are enabled.")
                    }
                }
            }
        }
    }

    func ensureNotificationAuthorization(_ completion: @escaping (Bool, String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                completion(true, nil)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if error != nil {
                        completion(false, self.notificationSettingsMessage())
                    } else if granted {
                        completion(true, nil)
                    } else {
                        completion(false, self.notificationSettingsMessage())
                    }
                }
            case .denied:
                completion(false, self.notificationSettingsMessage())
            @unknown default:
                completion(false, self.notificationSettingsMessage())
            }
        }
    }

    func notificationSettingsMessage() -> String {
        "Enable notifications for AI Account Switcher in System Settings > Notifications, then run Test Notification again. If it is not listed yet, quit and reopen the switcher once after this update."
    }

    func showNotificationSettingsAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Enable notifications"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runAbovePanel() == .alertFirstButtonReturn {
            openNotificationSettings()
        }
    }

    func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.mohamedfuad.codexaccountswitcher",
            "x-apple.systempreferences:com.apple.preference.notifications?id=com.mohamedfuad.codexaccountswitcher",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        switch response.actionIdentifier {
        case switchNowActionIdentifier:
            if let profileID = response.notification.request.content.userInfo["claudeProfileID"] as? String {
                DispatchQueue.main.async { [weak self] in self?.switchClaudeAccount(profileID) }
                return
            }
            guard let targetEmail = response.notification.request.content.userInfo["targetEmail"] as? String else { return }
            DispatchQueue.main.async { [weak self] in
                self?.switchTo(query: targetEmail, allowAutoResume: true)
            }
        case resumeNowActionIdentifier:
            let token = response.notification.request.content.userInfo["resumeToken"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingResume(token: token)
                self?.resumeCodexTask(submit: true, promptForPermission: true)
            }
        case cancelResumeActionIdentifier:
            let token = response.notification.request.content.userInfo["resumeToken"] as? String
            DispatchQueue.main.async { [weak self] in
                self?.cancelPendingResume(token: token)
            }
        default:
            return
        }
    }
}
