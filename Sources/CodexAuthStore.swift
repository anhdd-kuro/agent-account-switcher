import Foundation

final class CodexAuthStore {
    private let home: String

    init(home: String = NSHomeDirectory()) { self.home = home }

    func syncActiveAuthSnapshot() -> String? {
        let home = self.home
        let registryURL = URL(fileURLWithPath: "\(home)/.codex/accounts/registry.json")
        let activeAuthURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")

        do {
            let data = try Data(contentsOf: registryURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let activeKey = json["active_account_key"] as? String else {
                return "Could not read active_account_key from registry.json."
            }
            let activeEntry = (json["accounts"] as? [[String: Any]])?.first { $0["account_key"] as? String == activeKey }

            let accountAuthURL = snapshotURL(accountKey: activeKey, root: registryURL.deletingLastPathComponent())
            guard FileManager.default.fileExists(atPath: activeAuthURL.path) else {
                return "Active auth file does not exist at \(activeAuthURL.path)."
            }
            if activeAuthUsesApiKey(activeAuthURL) {
                return nil
            }

            // Another Codex client may have signed auth.json in to a different account, or left the
            // tokens untouched: only a changed login of the active account is saved over its snapshot.
            let liveData = try Data(contentsOf: activeAuthURL)
            func object(_ data: Data?) -> [String: Any]? {
                data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
            guard AuthSnapshotSync.decision(
                live: object(liveData),
                snapshot: object(try? Data(contentsOf: accountAuthURL)),
                expectedAccountID: activeEntry?["chatgpt_account_id"] as? String,
                expectedUserID: activeEntry?["chatgpt_user_id"] as? String
            ) == .copy else {
                return nil
            }

            let backupURL = accountAuthURL.deletingLastPathComponent().appendingPathComponent(
                accountAuthURL.lastPathComponent + ".bak.\(Int(Date().timeIntervalSince1970))"
            )
            let temporaryURL = accountAuthURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).auth.tmp")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try liveData.write(to: temporaryURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if FileManager.default.fileExists(atPath: accountAuthURL.path) {
                try? FileManager.default.copyItem(at: accountAuthURL, to: backupURL)
                _ = try FileManager.default.replaceItemAt(accountAuthURL, withItemAt: temporaryURL, options: .usingNewMetadataOnly)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: accountAuthURL)
            }
            _ = AuthBackupPruner.prune(in: accountAuthURL.deletingLastPathComponent(), keepingPerAccount: 10)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func activeAuthUsesApiKey(_ authURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: authURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let authMode = json["auth_mode"] as? String else {
            return false
        }
        return authMode.localizedCaseInsensitiveCompare("apikey") == .orderedSame
    }

    func savedAuth(forEmail email: String) -> SavedAccountAuthResult {
        let root = URL(fileURLWithPath: "\(home)/.codex/accounts")
        let registryURL = root.appendingPathComponent("registry.json")
        guard
            let registryData = try? Data(contentsOf: registryURL),
            let registry = try? JSONSerialization.jsonObject(with: registryData) as? [String: Any],
            let registryAccounts = registry["accounts"] as? [[String: Any]],
            let registryAccount = registryAccounts.first(where: { ($0["email"] as? String) == email }),
            let expectedAccountID = registryAccount["chatgpt_account_id"] as? String,
            !expectedAccountID.isEmpty
        else {
            return .failure("saved account registry was not readable")
        }

        // Codex rotates the tokens in auth.json; the snapshot under accounts/ can lag behind it.
        let liveURL = URL(fileURLWithPath: "\(home)/.codex/auth.json")
        let live = (try? Data(contentsOf: liveURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Use the document checked here; auth.json can change between reads.
        if let liveAuth = credentials(from: live, account: registryAccount, email: email) {
            return .success(liveAuth)
        }
        guard let authURL = authFileURL(for: registryAccount, root: root) else {
            return .failure("saved account auth file was not found")
        }
        let saved = (try? Data(contentsOf: authURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard let auth = credentials(from: saved, account: registryAccount, email: email) else {
            return .failure("saved account auth token was not readable")
        }
        return .success(auth)
    }

    private func credentials(from document: [String: Any]?, account: [String: Any], email: String) -> SavedAccountAuth? {
        guard let tokens = document?["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty,
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              accountID == account["chatgpt_account_id"] as? String else { return nil }
        if let userID = account["chatgpt_user_id"] as? String, !userID.isEmpty,
           AccessTokenClaims.userID(of: accessToken) != userID { return nil }
        return SavedAccountAuth(email: email, accessToken: accessToken, accountID: accountID)
    }

    private func snapshotURL(accountKey: String, root: URL) -> URL {
        let encoded = Data(accountKey.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return root.appendingPathComponent("\(encoded).auth.json")
    }

    private func authFileURL(for account: [String: Any], root: URL) -> URL? {
        if let key = account["account_key"] as? String, !key.isEmpty {
            return snapshotURL(accountKey: key, root: root)
        }
        // Older registries can lack account_key. Match both workspace and member:
        // multiple saved logins may belong to the same ChatGPT workspace.
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return urls.sorted { $0.path < $1.path }.first { url in
            guard url.lastPathComponent.hasSuffix(".auth.json"),
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return credentials(from: object, account: account, email: account["email"] as? String ?? "") != nil
        }
    }
}
