import AppKit
import ApplicationServices
import Foundation

extension AppDelegate {
    func handleAutoResumeAfterSwitch(to target: CodexAccount?) {
        let mode = preferences.autoResumeMode
        guard mode != .off else { return }
        let label = target.map(preferences.displayLabel(for:)) ?? "new account"
        let token = UUID().uuidString
        switch mode {
        case .off:
            return
        case .ask:
            sendResumePromptNotification(label: label, token: token, body: "Switch complete. Paste the resume prompt into Codex?")
        case .idle5:
            sendResumePromptNotification(label: label, token: token, body: "Switch complete. Resume will run after 5 seconds if the Mac is idle.")
            scheduleAutoResume(token: token, delay: 5, requireIdle: true)
        case .idle10:
            sendResumePromptNotification(label: label, token: token, body: "Switch complete. Resume will run after 10 seconds if the Mac is idle.")
            scheduleAutoResume(token: token, delay: 10, requireIdle: true)
        case .always:
            sendResumePromptNotification(label: label, token: token, body: "Switch complete. Resume prompt is being sent to Codex.")
            scheduleAutoResume(token: token, delay: 1, requireIdle: false)
        }
    }

    func sendResumePromptNotification(label: String, token: String, body: String) {
        sendNotification(
            title: "Resume Codex task?",
            subtitle: "Active: \(label)",
            body: body,
            categoryIdentifier: resumeNotificationCategory,
            userInfo: ["resumeToken": token]
        )
    }

    func scheduleAutoResume(token: String, delay: TimeInterval, requireIdle: Bool) {
        cancelPendingResume(token: token)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResumeWorkItems[token] = nil
            if requireIdle, self.systemIdleSeconds() < delay {
                self.copyResumePromptToClipboard()
                self.sendNotification(
                    title: "Resume prompt copied",
                    subtitle: "AI Account Switcher",
                    body: "The Mac was active, so the prompt was copied instead of pasted."
                )
                return
            }
            self.resumeCodexTask(submit: true, promptForPermission: true)
        }
        pendingResumeWorkItems[token] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelPendingResume(token: String?) {
        if let token {
            pendingResumeWorkItems[token]?.cancel()
            pendingResumeWorkItems[token] = nil
        } else {
            pendingResumeWorkItems.values.forEach { $0.cancel() }
            pendingResumeWorkItems.removeAll()
        }
    }

    func resumeCodexTask(submit: Bool, promptForPermission: Bool) {
        savedClipboardString = NSPasteboard.general.string(forType: .string)
        copyResumePromptToClipboard()
        guard accessibilityTrusted(prompt: promptForPermission) else {
            sendNotification(
                title: "Resume prompt copied",
                subtitle: "Accessibility needed",
                body: "Allow Accessibility for AI Account Switcher, then paste the prompt into Codex."
            )
            return
        }
        activateCodex()
        DispatchQueue.main.asyncAfter(deadline: .now() + autoResumeCodexReadyDelay) { [weak self] in
            guard let self else { return }
            guard self.codexIsFrontmost() else {
                self.sendNotification(
                    title: "Resume prompt copied",
                    subtitle: "Codex is not frontmost",
                    body: "The app copied the prompt instead of pasting into another window."
                )
                return
            }
            self.sendPasteKeystroke()
            if submit {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.sendReturnKeystroke()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.restoreClipboardAfterResume()
            }
        }
    }

    func copyResumePromptToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(preferences.autoResumePrompt, forType: .string)
    }

    func restoreClipboardAfterResume() {
        guard let savedClipboardString else { return }
        if NSPasteboard.general.string(forType: .string) == preferences.autoResumePrompt {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedClipboardString, forType: .string)
        }
        self.savedClipboardString = nil
    }

    func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func activateCodex() {
        if let app = NSWorkspace.shared.runningApplications.first(where: isCodexDesktopApplication) {
            app.activate(options: [.activateAllWindows])
        } else {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: DesktopApplication.path),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    func sendPasteKeystroke() {
        sendKey(code: 9, flags: .maskCommand)
    }

    func sendReturnKeystroke() {
        sendKey(code: 36, flags: .maskControl)
    }

    func sendKey(code: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
}
