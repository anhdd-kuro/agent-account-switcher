import Foundation

enum ClaudeAccountStore {
    static let liveService = "Claude Code-credentials"
    static let lock = NSRecursiveLock()

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeStateURL: URL { home.appendingPathComponent(".claude.json") }
    private static var storeURL: URL {
        home.appendingPathComponent("Library/Application Support/CodexAccountSwitcher/claude-profiles.json")
    }
    private static var legacyStoreURL: URL { home.appendingPathComponent(".config/claude-switcher/accounts.json") }

    // MARK: - Profiles

    static func loadProfiles() -> [ClaudeProfile] {
        lock.lock(); defer { lock.unlock() }
        if let data = try? Data(contentsOf: storeURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = object["profiles"] as? [[String: Any]] {
            return raw.compactMap(ClaudeProfile.init(dictionary:))
        }
        let migrated = legacyProfiles()
        if !migrated.isEmpty {
            try? saveProfiles(migrated)
        }
        return migrated
    }

    static func saveProfiles(_ profiles: [ClaudeProfile]) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "profiles": profiles.map { $0.dictionary() }], options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writeAtomically(data, to: storeURL)
    }

    /// One-time import of profiles saved by the earlier Python claude-switcher, whose
    /// Keychain backups use the same service names.
    private static func legacyProfiles() -> [ClaudeProfile] {
        guard let data = try? Data(contentsOf: legacyStoreURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = object["accounts"] as? [[String: Any]] else {
            return []
        }
        return accounts.compactMap { account in
            guard (account["provider"] as? String ?? "claude") == "claude",
                  let email = account["email"] as? String else { return nil }
            let oauth = account["oauth_account"] as? [String: Any] ?? [:]
            let organizationID = account["organization_id"] as? String ?? oauth["organizationUuid"] as? String ?? ""
            let id = ClaudeProfile.identity(email: email, organizationID: organizationID)
            let service = (account["keychain_service"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(ClaudeProfile.backupServicePrefix)\(email)"
            guard ClaudeKeychain.read(service) != nil else { return nil }
            return ClaudeProfile(
                id: id,
                email: email,
                organizationID: organizationID,
                organizationName: account["org_name"] as? String ?? oauth["organizationName"] as? String ?? "",
                keychainAccount: account["keychain_account"] as? String ?? NSUserName(),
                keychainService: service,
                oauthAccount: oauth
            )
        }
    }

    // MARK: - Live login

    static func readOAuthAccount() -> [String: Any]? {
        guard let data = try? Data(contentsOf: claudeStateURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["oauthAccount"] as? [String: Any]
    }

    private static func writeOAuthAccount(_ account: [String: Any]?) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: claudeStateURL.path) {
            let data = try Data(contentsOf: claudeStateURL)
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeError.message("Cannot read ~/.claude.json")
            }
            object = parsed
        }
        object["oauthAccount"] = account
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try writeAtomically(data, to: claudeStateURL)
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    static func parseCredentials(_ text: String?) -> [String: Any]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func serialize(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw ClaudeError.message("Cannot encode credentials") }
        return text
    }

    static func oauth(_ credentials: [String: Any]?) -> [String: Any]? {
        credentials?["claudeAiOauth"] as? [String: Any]
    }

    private static func metadataIdentity() -> String? {
        guard let account = readOAuthAccount(), let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return ClaudeProfile.identity(email: email, organizationID: account["organizationUuid"] as? String ?? "")
    }

    /// Captures and verifies the live login once. Usage and reset claims use this
    /// same credential value even if another Claude Code process switches afterward.
    static func synchronize() -> (profiles: [ClaudeProfile], credentials: ClaudeCredentialSnapshot, preserved: Bool) {
        lock.lock(); defer { lock.unlock() }
        var profiles = loadProfiles()
        let saved = Dictionary(profiles.compactMap { profile -> (String, [String: Any])? in
            oauth(parseCredentials(ClaudeKeychain.read(profile.keychainService))).map { (profile.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        func result(_ credentials: ClaudeCredentialSnapshot, preserved: Bool) -> (profiles: [ClaudeProfile], credentials: ClaudeCredentialSnapshot, preserved: Bool) {
            (profiles, credentials, preserved)
        }
        let unavailable = ClaudeCredentialSnapshot(liveOwnerID: nil, liveCredentials: nil, savedCredentials: saved)
        let liveText: String?
        do { liveText = try ClaudeKeychain.readStrict(liveService) } catch { return result(unavailable, preserved: false) }
        guard let liveText else { return result(unavailable, preserved: true) }
        guard let liveOAuth = oauth(parseCredentials(liveText)) else { return result(unavailable, preserved: false) }
        let oauthAccount = readOAuthAccount()
        let metadataID = oauthAccount.flatMap { account -> String? in
            guard let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
            return ClaudeProfile.identity(email: email, organizationID: account["organizationUuid"] as? String ?? "")
        }
        let credentials = ClaudeCredentialSnapshot.verified(metadataProfileID: metadataID,
            liveCredentials: liveOAuth, savedCredentials: saved, tokenOwner: ClaudeIdentityClient.tokenOwner)
        guard let ownerID = credentials.liveOwnerID else { return result(credentials, preserved: false) }
        if ownerID == metadataID, credentials.matchesSavedLogin(ownerID) {
            return result(credentials, preserved: true)
        }
        if ownerID != metadataID {
            guard let owner = profiles.first(where: { $0.id == ownerID }),
                  let text = try? serialize(["claudeAiOauth": liveOAuth]),
                  (try? ClaudeKeychain.write(owner.keychainService, account: owner.keychainAccount, secret: text)) != nil else {
                return result(credentials, preserved: false)
            }
            return result(credentials, preserved: true)
        }
        guard let oauthAccount,
              let email = oauthAccount["emailAddress"] as? String else { return result(credentials, preserved: false) }
        var profile: ClaudeProfile
        if let index = profiles.firstIndex(where: { $0.id == ownerID }) {
            profile = profiles[index].with(oauthAccount: oauthAccount)
            profiles[index] = profile
        } else {
            profile = ClaudeProfile(
                id: ownerID, email: email,
                organizationID: oauthAccount["organizationUuid"] as? String ?? "",
                organizationName: oauthAccount["organizationName"] as? String ?? "",
                keychainAccount: ClaudeKeychain.accountAttribute(liveService) ?? NSUserName(),
                keychainService: "\(ClaudeProfile.backupServicePrefix)\(ownerID)", oauthAccount: oauthAccount
            )
            profiles.append(profile)
        }
        guard let text = try? serialize(["claudeAiOauth": liveOAuth]),
              (try? ClaudeKeychain.write(profile.keychainService, account: profile.keychainAccount, secret: text)) != nil,
              (try? saveProfiles(profiles)) != nil else { return result(credentials, preserved: false) }
        return result(credentials, preserved: true)
    }

    // MARK: - Switching

    static func switchTo(profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let (profiles, credentialsSnapshot, preserved) = synchronize()
        guard preserved else {
            throw ClaudeError.message("The current Claude login could not be saved first, so nothing was changed. Try again shortly.")
        }
        guard let target = profiles.first(where: { $0.id == profileID }) else {
            throw ClaudeError.message("Claude profile not found")
        }
        guard credentialsSnapshot.liveOwnerID != profileID else { return }
        guard let targetOAuth = oauth(parseCredentials(ClaudeKeychain.read(target.keychainService))),
              !(targetOAuth["accessToken"] as? String ?? "").isEmpty,
              !(targetOAuth["refreshToken"] as? String ?? "").isEmpty else {
            throw ClaudeError.message("Saved credentials for \(target.title) are missing. Sign in to it again.")
        }
        guard !target.oauthAccount.isEmpty else {
            throw ClaudeError.message("Saved account details for \(target.title) are missing. Sign in to it again.")
        }

        let liveText = try ClaudeKeychain.readStrict(liveService)
        var credentials: [String: Any] = [:]
        if let liveText {
            guard let parsed = parseCredentials(liveText) else {
                throw ClaudeError.message("The current Claude credentials are unreadable, so nothing was changed.")
            }
            credentials = parsed
        }
        let liveAccount = ClaudeKeychain.accountAttribute(liveService) ?? target.keychainAccount
        let liveOAuthAccount = readOAuthAccount()
        credentials["claudeAiOauth"] = targetOAuth
        do {
            try ClaudeKeychain.write(liveService, account: liveAccount, secret: try serialize(credentials))
            try writeOAuthAccount(target.oauthAccount)
            guard (oauth(parseCredentials(ClaudeKeychain.read(liveService))) as NSDictionary?)?.isEqual(to: targetOAuth) == true,
                  metadataIdentity() == target.id else {
                throw ClaudeError.message("Claude login did not change.")
            }
        } catch {
            var restored = true
            if let liveText {
                restored = (try? ClaudeKeychain.write(liveService, account: liveAccount, secret: liveText)) != nil
            } else {
                ClaudeKeychain.delete(liveService)
                do { restored = try ClaudeKeychain.readStrict(liveService) == nil } catch { restored = false }
            }
            restored = (try? writeOAuthAccount(liveOAuthAccount)) != nil && restored
            throw ClaudeError.message(restored
                ? "\(error.localizedDescription) The previous login was restored."
                : "\(error.localizedDescription) The previous login could not be fully restored; run `claude auth login` to recover.")
        }
    }

    static func remove(profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let snapshot = synchronize()
        var profiles = snapshot.profiles
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard snapshot.credentials.liveOwnerID != profileID else {
            throw ClaudeError.message("Switch to another Claude account before removing this one.")
        }
        if !profiles.contains(where: { $0.id != profileID && $0.keychainService == profile.keychainService }) {
            ClaudeKeychain.delete(profile.keychainService)
        }
        profiles.removeAll { $0.id == profileID }
        try saveProfiles(profiles)
    }

    static func saveRefreshed(_ credentials: [String: Any], profile: ClaudeProfile) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? serialize(["claudeAiOauth": credentials]) else { return false }
        return (try? ClaudeKeychain.write(profile.keychainService, account: profile.keychainAccount, secret: text)) != nil
    }

}
