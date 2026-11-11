import Foundation

enum ClaudeIdentityClient {
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// The account and organization an access token belongs to, from Anthropic.
    static func tokenOwner(_ token: String) -> String? {
        var request = URLRequest(url: profileURL)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let email = (object["account"] as? [String: Any])?["email"] as? String else { return }
            let organization = (object["organization"] as? [String: Any])?["uuid"] as? String ?? ""
            box.value = ClaudeProfile.identity(email: email, organizationID: organization)
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }
}
