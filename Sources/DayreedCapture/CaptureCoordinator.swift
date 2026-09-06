import DayreedCore
import Foundation
import Observation

public enum CaptureMode: String, Sendable {
    case stopped, paused, suspended, disabled, excluded, running
}

public struct CaptureState: Equatable, Sendable {
    public internal(set) var mode: CaptureMode = .stopped
    public internal(set) var permissions = CapturePermissions()
    public internal(set) var qualities = SourceQualities()
    public internal(set) var lastRecordID: UUID?
    public internal(set) var storageFailed = false
    public internal(set) var isCapturing = false
    public init() {}
}

/// Main-actor state changes and the final synchronous store append are ordered together.
/// OS work suspends; its result is accepted only while its original settings/session still apply.
@MainActor @Observable
public final class CaptureCoordinator {
    public private(set) var settings: CaptureSettings
    public private(set) var state = CaptureState()
    @ObservationIgnored private let store: DayreedStore
    @ObservationIgnored private let environment: any CaptureEnvironment
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let automaticallySchedules: Bool
    @ObservationIgnored private var started = false
    @ObservationIgnored private var userPaused = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var displaySleeping = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var pendingTrigger: CaptureTrigger?
    @ObservationIgnored private var retentionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRetention: (days: Int, date: Date)?
    // Internal injection point for bounded tests; the synchronous operation always runs off MainActor.
    @ObservationIgnored var retentionOperation: @Sendable (Int, Date) throws -> Void

    public init(store: DayreedStore, settings: CaptureSettings = CaptureSettings(),
                environment: (any CaptureEnvironment)? = nil, automaticallySchedules: Bool = true,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.store = store
        self.retentionOperation = { days, date in
            try store.applyRetention(days: days, now: date)
        }
        self.settings = settings.normalized
        self.environment = environment ?? MacCaptureEnvironment()
        self.automaticallySchedules = automaticallySchedules
        self.now = now
    }

    deinit { timer?.cancel() }

    /// Call after user intent. Settings remain off unless explicitly changed by the user.
    public func start() {
        guard !started else { return }
        started = true
        sessionInactive = !environment.isSessionActive()
        environment.startMonitoring { [weak self] event in self?.receive(event) }
        refreshPermissions()
        updateMode()
        applyRetention()
        scheduleTimer()
        enqueue(.started)
    }

    public func stop() {
        started = false
        pendingRetention = nil
        invalidate()
        timer?.cancel()
        timer = nil
        environment.stopMonitoring()
        sleeping = false
        displaySleeping = false
        locked = false
        sessionInactive = false
        updateMode()
    }

    public func pause() {
        userPaused = true
        invalidate()
        updateMode()
    }

    public func resume() {
        userPaused = false
        invalidate()
        refreshPermissions()
        updateMode()
        enqueue(.resumed)
    }

    public func updateSettings(_ settings: CaptureSettings) {
        let settings = settings.normalized
        guard settings != self.settings else { return }
        self.settings = settings
        invalidate()
        state.qualities = SourceQualities()
        refreshPermissions()
        updateMode()
        if started {
            applyRetention()
            scheduleTimer()
            enqueue(.manual)
        }
    }

    /// Queries only; the OS does not reliably distinguish denied from not yet requested.
    public func refreshPermissions() {
        let permissions = environment.permissions()
        if permissions != state.permissions { invalidate() }
        state.permissions = permissions
    }

    /// Invoke these methods only in response to the corresponding user permission button.
    public func requestScreenRecordingPermission() {
        environment.requestScreenRecordingPermission()
        refreshPermissions()
    }

    public func requestAccessibilityPermission() {
        environment.requestAccessibilityPermission()
        refreshPermissions()
    }

    /// Deterministic entry point for a timer or explicit local sampling action.
    /// A concurrent request is coalesced; there is never a queue of raw in-flight samples.
    public func captureNow(trigger: CaptureTrigger = .manual) async {
        refreshPermissions()
        updateMode()
        guard !state.isCapturing else {
            pendingTrigger = trigger
            return
        }
        state.isCapturing = true
        defer {
            state.isCapturing = false
            if let pendingTrigger {
                self.pendingTrigger = nil
                enqueue(pendingTrigger)
            }
        }
        let contextGeneration = generation
        await waitForRetention()
        refreshPermissions()
        updateMode()
        guard !Task.isCancelled, generation == contextGeneration, state.mode == .running else { return }
        let contextSettings = settings
        let permissions = state.permissions
        let application = environment.currentApplication()
        let capturedAt = now()
        let began = ContinuousClock.now
        var qualities = SourceQualities()
        var evidence: [EvidenceInput] = []
        if contextSettings.historyEnabled {
            qualities.application = application == nil ? .unavailable : .available
            qualities.windowTitle = contextSettings.windowTitlesEnabled ? .unavailable : .disabled
            qualities.accessibilityText = contextSettings.accessibilityTextEnabled ? .unavailable : .disabled
            if permissions.accessibility == .notGranted {
                if contextSettings.windowTitlesEnabled { qualities.windowTitle = .permissionRequired }
                if contextSettings.accessibilityTextEnabled { qualities.accessibilityText = .permissionRequired }
            } else if let application, contextSettings.windowTitlesEnabled || contextSettings.accessibilityTextEnabled {
                let history = await environment.history(for: application, windowTitle: contextSettings.windowTitlesEnabled,
                                                        accessibilityText: contextSettings.accessibilityTextEnabled)
                await waitForRetention()
                guard isCurrent(contextGeneration, application: application, began: began) else { return }
                if contextSettings.windowTitlesEnabled {
                    qualities.windowTitle = history.windowTitleQuality
                    if let title = history.windowTitle, !title.isEmpty {
                        evidence.append(.text(title, kind: .windowTitle))
                    }
                }
                if contextSettings.accessibilityTextEnabled {
                    qualities.accessibilityText = history.accessibilityTextQuality
                    if let text = history.accessibilityText, !text.isEmpty {
                        evidence.append(.text(text, kind: .accessibilityText))
                    }
                }
            }
        }
        if contextSettings.screenshotsEnabled {
            if permissions.screenRecording == .notGranted {
                qualities.screenshot = .permissionRequired
            } else {
                let screenshot = await environment.screenshot(excluding: contextSettings.excludedBundleIdentifiers)
                await waitForRetention()
                guard isCurrent(contextGeneration, application: application, began: began) else { return }
                qualities.screenshot = screenshot.quality
                if let png = screenshot.pngData, !png.isEmpty {
                    evidence.append(EvidenceInput(kind: .screenshot, mediaType: "image/png", data: png))
                }
            }
        }
        await waitForRetention()
        guard isCurrent(contextGeneration, application: application, began: began) else { return }
        // No suspension between final validation and append: pause/stop cannot race the commit.
        do {
            let summary = try store.append(CaptureRecordInput(
                capturedAt: capturedAt, trigger: trigger,
                applicationBundleIdentifier: contextSettings.historyEnabled ? application?.bundleIdentifier : nil,
                qualities: qualities, evidence: evidence
            ))
            state.lastRecordID = summary.id
            state.qualities = qualities
            state.storageFailed = false
            applyRetention()
            await waitForRetention()
        } catch {
            state.storageFailed = true
        }
    }

    private func isCurrent(_ expectedGeneration: UInt64, application: ActiveApplication?, began: ContinuousClock.Instant) -> Bool {
        refreshPermissions()
        updateMode()
        return !Task.isCancelled && generation == expectedGeneration && state.mode == .running
            && environment.isSessionActive() && environment.currentApplication() == application
            && began.duration(to: .now) <= .seconds(15)
    }

    private func invalidate() {
        generation &+= 1
        pendingTrigger = nil
    }

    private func updateMode() {
        if !started { state.mode = .stopped }
        else if userPaused { state.mode = .paused }
        else if sleeping || displaySleeping || locked || sessionInactive || !environment.isSessionActive() { state.mode = .suspended }
        else if !settings.hasEnabledSources { state.mode = .disabled }
        else if let application = environment.currentApplication(),
                let bundle = application.bundleIdentifier, settings.excludedBundleIdentifiers.contains(bundle) {
            state.mode = .excluded
        } else if !settings.excludedBundleIdentifiers.isEmpty && environment.currentApplication()?.bundleIdentifier == nil {
            // An unidentified front app cannot be safely compared with the user's exclusion list.
            state.mode = .excluded
        } else { state.mode = .running }
    }

    private func receive(_ event: CaptureEnvironmentEvent) {
        invalidate()
        switch event {
        case .sleeping: sleeping = true
        case .woke: sleeping = false
        case .displaySleeping: displaySleeping = true
        case .displayWoke: displaySleeping = false
        case .locked: locked = true
        case .unlocked: locked = false
        case .sessionInactive: sessionInactive = true
        case .sessionActive: sessionInactive = false
        case .applicationChanged: break
        }
        refreshPermissions()
        updateMode()
        enqueue(event == .applicationChanged ? .applicationChanged : .resumed)
    }

    private func enqueue(_ trigger: CaptureTrigger) {
        guard automaticallySchedules, started, state.mode == .running else { return }
        Task { [weak self] in await self?.captureNow(trigger: trigger) }
    }

    private func scheduleTimer() {
        timer?.cancel()
        guard automaticallySchedules, started, settings.hasEnabledSources else { return }
        let interval = settings.intervalSeconds
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.captureNow(trigger: .timer)
            }
        }
    }

    private func applyRetention() {
        pendingRetention = (settings.retentionDays, now())
        guard retentionTask == nil else { return }
        retentionTask = Task { [weak self] in
            guard let self else { return }
            while let request = self.pendingRetention {
                self.pendingRetention = nil
                let operation = self.retentionOperation
                let succeeded = await Task.detached(priority: .utility) {
                    do {
                        try operation(request.days, request.date)
                        return true
                    } catch { return false }
                }.value
                if !succeeded { self.state.storageFailed = true }
            }
            self.retentionTask = nil
        }
    }

    // Also drains a newer task scheduled while this caller was resuming from an older one.
    // stop discards queued requests; an active SQLite transaction is allowed to finish.
    func waitForRetention() async {
        while let task = retentionTask { await task.value }
    }
}
