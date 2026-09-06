import Foundation

@main struct ReviewStoreChecks {
    @MainActor static func main() async {
        let service = SyntheticReviewService()
        let store = ReviewStore(service: service, date: service.date)
        await store.reload()
        precondition(store.loaded && store.snapshot.events.count == 1)
        store.draft = "本地修改"
        service.shouldFail = true
        await store.save()
        precondition(store.draft == "本地修改" && store.isDirty && store.failure != nil)
        precondition(!store.failure!.contains("SECRET"))
        let originalQuery = store.query
        await store.navigate(to: ReviewQuery(date: service.date.addingTimeInterval(86400)))
        precondition(store.query == originalQuery && store.draft == "本地修改")
        service.shouldFail = false
        await store.save()
        precondition(!store.isDirty && store.snapshot.report?.markdown == "本地修改")
        store.draft = "提交版本"
        service.deferSave = true
        let saveTask = Task { await store.save() }
        while service.pendingSave == nil { await Task.yield() }
        store.draft = "保存期间继续编辑"
        service.pendingSave!.resume(returning: ReviewReport(id: "synthetic-report", markdown: "提交版本", updatedAt: service.date, sources: []))
        await saveTask.value
        precondition(store.draft == "保存期间继续编辑" && store.isDirty && store.savedDraft == "提交版本")
        store.discardDraft()
        service.deferLoads = true
        let load1 = Task { await store.reload() }
        while service.pendingLoads.count < 1 { await Task.yield() }
        let load2 = Task { await store.navigate(to: ReviewQuery(date: service.date.addingTimeInterval(86400))) }
        while service.pendingLoads.count < 2 { await Task.yield() }
        service.pendingLoads[1].resume(returning: ReviewSnapshot())
        await load2.value
        service.pendingLoads[0].resume(returning: service.sample)
        await load1.value
        precondition(store.snapshot.events.isEmpty && store.snapshot.report == nil && !store.isLoading)
        let unconnected = ReviewStore(service: UnconnectedReviewService())
        await unconnected.reload()
        precondition(!unconnected.loaded && unconnected.snapshot.events.isEmpty)
        let settings = SettingsStore(service: service)
        await settings.load()
        precondition(settings.draft.sources.allSatisfy { !$0.enabled } && !settings.draft.agentEnabled && !settings.draft.agentAllowsChanges && !settings.draft.agentIncludesRawContent)
        settings.draft.sources[0].enabled = true
        service.shouldFail = true
        await settings.save()
        precondition(settings.isDirty && settings.failed && settings.saved.sources.allSatisfy { !$0.enabled })
        service.deferLoads = false
        service.shouldFail = false
        await store.reload()
        store.draft = "保留删除期间的手工草稿"
        await store.refreshAfterDeletion()
        precondition(store.snapshot.events.isEmpty && store.snapshot.report == nil && store.isDirty && store.draft == "保留删除期间的手工草稿")
        print("PASS: failed save preserves draft; errors redact backend details; dirty navigation blocks; successful save; in-flight edit preserved; stale load ignored; unconnected empty; collection and Agent default off; failed settings remain unapplied")
    }
}
