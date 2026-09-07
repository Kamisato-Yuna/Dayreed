import DayreedAnalysis
import DayreedCore
import Foundation

final class AppMemoryCredentials: ProviderCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    private(set) var readCount = 0
    var failWrites = false
    func read(for id: UUID) throws -> String? { lock.withLock { readCount += 1; return values[id] } }
    func write(_ value: String?, for id: UUID) throws {
        try lock.withLock {
            if failWrites { throw AnalysisError.credentials }
            values[id] = value
        }
    }
}

actor AppSyntheticProvider: AnalysisProvider {
    private(set) var calls = 0
    private(set) var lastSources = Set<AnalysisSource>()
    private(set) var lastEvidenceKinds = Set<EvidenceKind>()
    private var delayed = false
    private var failure: AnalysisError?
    func setFailure(_ value: AnalysisError?) { failure = value }
    private(set) var pending: CheckedContinuation<[ActivityClassification], Never>?
    private var result: [ActivityClassification] = []
    func setDelayed(_ value: Bool) { delayed = value }
    func complete() { pending?.resume(returning: result); pending = nil }
    func classify(_ observations: [ProviderObservation]) async throws -> [ActivityClassification] {
        calls += 1
        if let failure { throw failure }
        lastSources = observations.reduce(into: Set<AnalysisSource>()) { $0.formUnion($1.sources) }
        lastEvidenceKinds = Set(observations.flatMap { $0.evidence.map(\.kind) })
        result = observations.map { ActivityClassification(recordID: $0.recordID, title: "合成整理活动", summary: "仅用于验收的合成活动摘要") }
        if delayed { return await withCheckedContinuation { pending = $0 } }
        return result
    }
}
