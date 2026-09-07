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
    var selectedEventID: String?
    var draft = ""
    private(set) var savedDraft = ""
    var message: String?
    private(set) var failure: String?
    private var loadSequence = 0
    var isDirty: Bool { draft != savedDraft }
    var canGenerate: Bool { query.kind == nil ? service.capabilities.regenerate : service.capabilities.generateReport }

    init(service: any ReviewService, date: Date = .now) {
        self.service = service
        query = ReviewQuery(date: date)
    }

    func navigate(to query: ReviewQuery) async {
        guard !isDirty, !isWorking else { return }
        if self.query.interval != query.interval || self.query.kind != query.kind { selectedEventID = nil }
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

    func refreshAfterCapture() async {
        // New observations update the timeline, not saved reports. Rebuilding a report
        // here also destroys its editor mode and any open candidate-review sheet.
        guard query.kind == nil else { return }
        await reload()
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
        guard canGenerate, !isWorking, !isLoading, !isDirty else { return }
        isWorking = true
        message = nil
        failure = nil
        defer { isWorking = false }
        do {
            accept(try await service.regenerate(query))
            loaded = true
            message = query.kind == nil ? "分析已完成" : "候选稿已生成，原报告保持不变。"
        } catch { fail(error) }
    }

    func reviewCandidate(_ candidate: ReviewReportCandidate, accept: Bool) async {
        guard !isWorking, !isLoading, !isDirty else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let result = try await (accept ? service.accept(candidate: candidate, query: query) : service.discard(candidate: candidate, query: query))
            self.accept(result)
            message = accept ? "已采用候选稿" : "已丢弃候选稿，原报告保持不变。"
        } catch { fail(error) }
    }

    func correct(_ event: ReviewEvent, title: String, summary: String) async -> Bool {
        guard service.capabilities.correctEvent, event.isCorrectable, !isWorking else { return false }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            let result = try await service.correct(event: event, title: title, summary: summary)
            if let index = snapshot.events.firstIndex(where: { $0.id == event.id }) { snapshot.events[index] = result }
            message = "已保存纠正"
            do {
                snapshot = try await service.load(query)
                reconcileSelection()
            }
            catch { message = "纠正已保存，但未能刷新完整时间线，请使用刷新按钮重试。" }
            return true
        } catch { fail(error); return false }
    }

    func open(_ evidence: ReviewEvidence) async {
        guard service.capabilities.openEvidence else { return }
        do { try await service.open(evidence: evidence) } catch { fail(error) }
    }

    func refreshAfterDeletion() async {
        // A deleted event/evidence must disappear even if a report has a local unsaved draft.
        if isDirty {
            loadSequence += 1
            snapshot = ReviewSnapshot()
            selectedEventID = nil
            savedDraft = ""
            isLoading = false
            loaded = true
            message = "本地记录已删除。未保存的手工草稿仍留在编辑器，可自行保存或放弃。"
        } else { await reload() }
    }

    func discardDraft() { draft = savedDraft }

    private func accept(_ snapshot: ReviewSnapshot) {
        self.snapshot = snapshot
        reconcileSelection()
        savedDraft = snapshot.report?.markdown ?? ""
        draft = savedDraft
    }

    private func reconcileSelection() {
        if let selectedEventID, !snapshot.events.contains(where: { $0.id == selectedEventID }) {
            self.selectedEventID = nil
        }
    }

    private func fail(_ error: Error) {
        failure = (error as? ReviewServiceError)?.errorDescription ?? ReviewServiceError.failed.errorDescription
    }
}
