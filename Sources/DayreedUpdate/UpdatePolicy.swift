import Foundation

/// The only public update channel. Preferences never select a feed or a signing key.
public enum UpdatePolicy {
    public static let feedURL = URL(string: "https://github.com/Kamisato-Yuna/Dayreed/releases/latest/download/appcast.xml")!
    public static let keychainAccount = "YunaBuild.Dayreed.Sparkle"

    public static func allowsArchive(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "github.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%") else { return false }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 7, path[0].isEmpty, path[1] == "Kamisato-Yuna", path[2] == "Dayreed",
              path[3] == "releases", path[4] == "download",
              path[5].hasPrefix("v"), path[6].hasPrefix("Dayreed-"), path[6].hasSuffix(".zip") else { return false }
        return [path[5], path[6]].allSatisfy { value in
            value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
                && !value.contains("..")
        }
    }

    static func configurationProblem(_ info: [String: Any]) -> String? {
        guard info["CFBundleIdentifier"] as? String == "YunaBuild.Dayreed",
              info["SUFeedURL"] as? String == feedURL.absoluteString,
              info["SUDefaultsDomain"] as? String == keychainAccount else {
            return "更新配置尚未就绪。请使用完整 Dayreed App。"
        }
        guard let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SURequireSignedFeed"] as? Bool == true,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SUSignedFeedFailureExpirationInterval"] as? Int == 0,
              info["SUEnableSystemProfiling"] as? Bool == false else {
            return "签名更新配置尚未就绪。"
        }
        return nil
    }
}
