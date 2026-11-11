import Foundation

enum DesktopApplication {
    static let path = "/Applications/ChatGPT.app"
    static let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    static let resourcesPath = "\(path)/Contents/Resources"
    static let bundleIDs: Set<String> = ["com.openai.codex", "com.openai.chat"]

    static func matches(bundleID: String?, name: String?) -> Bool {
        bundleIDs.contains(bundleID?.lowercased() ?? "") || ["codex", "chatgpt"].contains(name?.lowercased() ?? "")
    }
}
