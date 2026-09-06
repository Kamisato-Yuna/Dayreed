import Foundation
import Observation

@MainActor @Observable
final class ReviewStore {
    let service: any ReviewService
    private(set) var query: ReviewQuery
    private(set) var snapshot = ReviewSnapshot()
    private(set) var isLoading = false
    private(set) var isWorking = false
    private(set) var loaded = false
    var draft = ""
    private(set) var savedDraft = ""
    var message: String?
    private(set) var failure: String?
    private var loadSequence = 0
    var isDirty: Bool { draft != savedDraft }

    init(service: any ReviewService, date: Date = .now) {
        self.service = service
        query = ReviewQuery(date: date)
    }

    func navigate(to query: ReviewQuery) async {
        guard !isDirty, !isWorking else { return }
        self.query = query
        await reload()
    }

    func reload() async {
        guard !isDirty, !isWorking else { return }
        loadSequence += 1
        let sequence = loadSequence
        snapshot = ReviewSnapshot()
        draft = ""
        savedDraft = ""
        loaded = false
        message = nil
        failure = nil
        guard service.capabilities.read else { return }
        isLoading = true
        defer { if sequence == loadSequence { isLoading = false } }
        do {
            let result = try await service.load(query)
            guard sequence == loadSequence else { return }
            accept(result)
            loaded = true
        } catch {
            guard sequence == loadSequence else { return }
            fail(error)
        }
    }

    func save() async {
        guard service.capabilities.saveReport, !isWorking, !isLoading, isDirty else { return }
        isWorking = true
        failure = nil
        message = nil
        let submitted = draft
        defer { isWorking = false }
        do {
            let report = try await service.save(markdown: submitted, report: snapshot.report, query: query)
            snapshot.report = report
            savedDraft = report.markdown
            // Keep text entered during the save; never overwrite a newer local edit.
            if draft == submitted { draft = report.markdown }
            message = isDirty ? "已保存提交的版本；还有未保存修改。" : "已保存"
        } catch { fail(error) }
    }

    func regenerate() async {
        guard service.capabilities.regenerate, !isWorking, !isLoading, !isDirty else { return }
        isWorking = true
        message = nil
        failure = nil
        defer { isWorking = false }
        do {
            accept(try await service.regenerate(query))
            loaded = true
            message = "已重新生成"
        } catch { fail(error) }
    }

    func correct(_ event: ReviewEvent, title: String, summary: String) async -> Bool {
        guard service.capabilities.correctEvent, !isWorking else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let result = try await service.correct(event: event, title: title, summary: summary)
            if let index = snapshot.events.firstIndex(where: { $0.id == event.id }) { snapshot.events[index] = result }
            message = "已保存纠正"
            return true
        } catch { fail(error); return false }
    }

    func open(_ evidence: ReviewEvidence) async {
        guard service.capabilities.openEvidence else { return }
        do { try await service.open(evidence: evidence) } catch { fail(error) }
    }

    func discardDraft() { draft = savedDraft }

    private func accept(_ snapshot: ReviewSnapshot) {
        self.snapshot = snapshot
        savedDraft = snapshot.report?.markdown ?? ""
        draft = savedDraft
    }

    private func fail(_ error: Error) {
        failure = (error as? ReviewServiceError)?.errorDescription ?? ReviewServiceError.failed.errorDescription
    }
}
