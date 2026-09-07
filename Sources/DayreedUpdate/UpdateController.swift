import Combine
import Foundation
import Sparkle

/// Keep one instance for the lifetime of the App. Call start() after App launch.
/// Sparkle owns download/install/relaunch UI; this model supplies Settings and menu state.
@MainActor
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    public enum State: Equatable, Sendable {
        case unavailable(String)
        case idle
        case checking
        case available(version: String)
        case noUpdate
        case downloading
        case installing
        case cancelled
        case failed(code: Int)
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var automaticallyChecksForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var started = false

    public override init() {
        super.init()
        if let problem = UpdatePolicy.configurationProblem(Bundle.main.infoDictionary ?? [:]) {
            state = .unavailable(problem)
        }
    }

    public func start() {
        guard !started, case .idle = state else { return }
        // This preference belongs only to Dayreed. Never migrate other applications' defaults.
        // Enforce the product's no-profiling policy even if a stale preference enabled it.
        UserDefaults(suiteName: UpdatePolicy.keychainAccount)?.set(false, forKey: "SUSendProfileInfo")
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.sendsSystemProfile = false
        do {
            try controller.updater.start()
            started = true
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        } catch {
            state = .failed(code: (error as NSError).code)
        }
    }

    public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard started else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    public func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        UpdatePolicy.feedURL.absoluteString
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        updater.sendsSystemProfile = false
        state = .checking
    }

    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        // Also inspect delta enclosures: Sparkle may select a delta after selecting the full update.
        let archives = [item] + Array(item.deltaUpdates?.values ?? Dictionary<String, SUAppcastItem>().values)
        guard !item.isInformationOnlyUpdate,
              archives.allSatisfy({ $0.fileURL.map(UpdatePolicy.allowsArchive) == true }) else {
            throw NSError(domain: "YunaBuild.Dayreed.Update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "更新来源不是 Dayreed 的 GitHub Release。"])
        }
    }

    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        state = .available(version: item.displayVersionString)
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        // Means no installable update (may include OS/hardware incompatibility), not "latest version".
        state = .noUpdate
    }

    public func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        state = .downloading
    }

    public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { state = .installing }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Do not publish arbitrary server error text, URLs, or response bodies into App logs/state.
        state = Self.state(for: error)
    }

    static func state(for error: Error) -> State {
        let error = error as NSError
        if error.domain == SUSparkleErrorDomain {
            if error.code == SUError.noUpdateError.rawValue { return .noUpdate }
            if error.code == SUError.installationCanceledError.rawValue { return .cancelled }
        }
        return .failed(code: error.code)
    }

    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { state = Self.state(for: error) }
        else if state == .checking || state == .downloading { state = .idle }
    }
}
