import Foundation
import Observation

@MainActor @Observable
final class SettingsStore {
    let service: any ReviewService
    var draft = ReviewPreferences()
    private(set) var saved = ReviewPreferences()
    private(set) var isWorking = false
    var message: String?
    var failed = false
    var isDirty: Bool { draft != saved }
    init(service: any ReviewService) { self.service = service }
    func load() async {
        guard !isDirty, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { saved = try await service.preferences(); draft = saved }
        catch { showFailure() }
    }
    func save() async {
        guard service.capabilities.configure, !isWorking, isDirty else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            saved = try await service.save(preferences: draft)
            draft = saved
            failed = false
            message = "设置已保存"
        } catch { showFailure() }
    }
    func checkUpdates() async {
        guard service.capabilities.checkUpdates, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { message = try await service.checkUpdates(); failed = false }
        catch { showFailure() }
    }
    func discard() { draft = saved; message = nil }
    private func showFailure() { message = ReviewServiceError.failed.errorDescription; failed = true }
}
