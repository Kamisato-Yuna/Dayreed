import Foundation

/// Integration boundary: adapters own persistence, permissions, provider credentials and raw evidence access.
/// Views never read a user's database or request a permission themselves.
@MainActor
protocol ReviewService {
    var capabilities: ReviewCapabilities { get }
    var unavailableReason: String? { get }
    func load(_ query: ReviewQuery) async throws -> ReviewSnapshot
    func save(markdown: String, report: ReviewReport?, query: ReviewQuery) async throws -> ReviewReport
    func regenerate(_ query: ReviewQuery) async throws -> ReviewSnapshot
    func accept(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot
    func discard(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot
    func correct(event: ReviewEvent, title: String, summary: String) async throws -> ReviewEvent
    func open(evidence: ReviewEvidence) async throws
    func preferences() async throws -> ReviewPreferences
    func save(preferences: ReviewPreferences) async throws -> ReviewPreferences
    func checkUpdates() async throws -> String
}

/// Safe startup until the production adapter is installed. No fixtures and no implicit collection.
struct UnconnectedReviewService: ReviewService {
    let capabilities = ReviewCapabilities()
    let unavailableReason: String? = "本版本尚未连接本地记录服务。连接后即可浏览与整理记录；当前未启动采集。"
    func load(_ query: ReviewQuery) async throws -> ReviewSnapshot { throw ReviewServiceError.unavailable }
    func save(markdown: String, report: ReviewReport?, query: ReviewQuery) async throws -> ReviewReport { throw ReviewServiceError.unavailable }
    func regenerate(_ query: ReviewQuery) async throws -> ReviewSnapshot { throw ReviewServiceError.unavailable }
    func correct(event: ReviewEvent, title: String, summary: String) async throws -> ReviewEvent { throw ReviewServiceError.unavailable }
    func open(evidence: ReviewEvidence) async throws { throw ReviewServiceError.unavailable }
    func preferences() async throws -> ReviewPreferences { ReviewPreferences() }
    func save(preferences: ReviewPreferences) async throws -> ReviewPreferences { throw ReviewServiceError.unavailable }
    func checkUpdates() async throws -> String { throw ReviewServiceError.unavailable }
}

extension ReviewService {
    func accept(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot { throw ReviewServiceError.unavailable }
    func discard(candidate: ReviewReportCandidate, query: ReviewQuery) async throws -> ReviewSnapshot { throw ReviewServiceError.unavailable }
}
