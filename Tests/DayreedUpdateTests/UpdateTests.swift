import Foundation
import Sparkle
import Testing
@testable import DayreedUpdate

@Test func archiveSourcesAreRestrictedToOwnGitHubReleases() {
    let good = "https://github.com/Kamisato-Yuna/Dayreed/releases/download/v1.0.1/Dayreed-1.0.1.zip"
    #expect(UpdatePolicy.allowsArchive(URL(string: good)!))
    for bad in [good.replacingOccurrences(of: "https:", with: "http:"),
                good.replacingOccurrences(of: "Dayreed/releases", with: "Dayflow-Yuna/releases"),
                good.replacingOccurrences(of: "github.com", with: "github.com.evil.example"),
                good.replacingOccurrences(of: "github.com", with: "user@github.com"),
                good.replacingOccurrences(of: "github.com", with: "github.com:443"),
                good.replacingOccurrences(of: "/v1.0.1/", with: "/../"),
                good.replacingOccurrences(of: "Dayreed-1.0.1.zip", with: "%44ayreed-1.0.1.zip"),
                good + "?redirect=evil", good + "#fragment", good + "/extra"] {
        #expect(!UpdatePolicy.allowsArchive(URL(string: bad)!))
    }
}

@Test func missingOrWeakenedSigningConfigurationIsUnavailable() {
    var info: [String: Any] = [
        "CFBundleIdentifier": "YunaBuild.Dayreed", "SUFeedURL": UpdatePolicy.feedURL.absoluteString,
        "SUDefaultsDomain": UpdatePolicy.keychainAccount,
        "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
        "SURequireSignedFeed": true, "SUVerifyUpdateBeforeExtraction": true,
        "SUSignedFeedFailureExpirationInterval": 0, "SUEnableSystemProfiling": false,
    ]
    #expect(UpdatePolicy.configurationProblem(info) == nil)
    for key in ["SUPublicEDKey", "SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction", "SUDefaultsDomain"] {
        var missing = info
        missing.removeValue(forKey: key)
        #expect(UpdatePolicy.configurationProblem(missing) != nil)
    }
    info["SUFeedURL"] = "https://github.com/Kamisato-Yuna/Dayflow-Yuna/releases/latest/download/appcast.xml"
    #expect(UpdatePolicy.configurationProblem(info) != nil)
}

@Test @MainActor func errorsDoNotClaimSuccessOrExposeServerContent() {
    #expect(UpdateController.state(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))) == .noUpdate)
    #expect(UpdateController.state(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))) == .cancelled)
    #expect(UpdateController.state(for: NSError(domain: "server", code: 500, userInfo: [NSLocalizedDescriptionKey: "synthetic sensitive response"])) == .failed(code: 500))
    let controller = UpdateController()
    controller.start()
    #expect(!controller.canCheckForUpdates)
    #expect(!controller.automaticallyChecksForUpdates)
    guard case .unavailable = controller.state else { Issue.record("Tests outside the App must not start an updater"); return }
}

@Test @MainActor func sparkleIgnoresStaleFeedAndDisablesProfiling() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let contents = directory.appendingPathComponent("Fixture.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let domain = "YunaBuild.Dayreed.Tests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: domain))
    defer { preferences.removePersistentDomain(forName: domain) }
    preferences.set("https://github.com/Kamisato-Yuna/Dayflow-Yuna/releases/latest/download/appcast.xml", forKey: "SUFeedURL")
    preferences.set(true, forKey: "SUSendProfileInfo")
    let info: [String: Any] = ["CFBundleIdentifier": domain, "CFBundleVersion": "1", "CFBundleName": "Fixture",
                             "SUDefaultsDomain": domain, "SUFeedURL": UpdatePolicy.feedURL.absoluteString,
                             "SUEnableAutomaticChecks": false]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    let bundle = try #require(Bundle(url: contents.deletingLastPathComponent()))
    let controller = UpdateController()
    let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
    let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: controller)
    // No start/check call: tests do not schedule network traffic or show Sparkle UI.
    #expect(updater.feedURL == UpdatePolicy.feedURL)
    try controller.updater(updater, mayPerform: .updates)
    #expect(!updater.sendsSystemProfile)
}
