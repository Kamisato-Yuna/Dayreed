import DayreedCapture
import DayreedCore
import SwiftUI

struct CaptureControlView: View {
    let service: LiveReviewService
    @State private var deletionDate = Date.now
    @State private var deletion: RecordDeletion?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Section("采集状态与控制") {
            if let coordinator = service.coordinator {
                LabeledContent("状态", value: mode(coordinator.state.mode))
                Text("运行表示采样调度已启用；权限和下方各来源质量决定实际获得的内容。").font(.caption).foregroundStyle(.secondary)
                if coordinator.state.storageFailed { Text("本地写入或清理失败，请检查磁盘空间后重试。").foregroundStyle(.red) }
                HStack {
                    Button("开始") { control(.start) }.disabled(coordinator.state.mode != .stopped)
                    Button("暂停") { control(.pause) }.disabled([.stopped, .paused].contains(coordinator.state.mode))
                    Button("继续") { control(.resume) }.disabled(coordinator.state.mode != .paused)
                    Button("停止") { control(.stop) }.disabled(coordinator.state.mode == .stopped)
                }.disabled(working || service.deletionInProgress || service.isTransitioning)
                LabeledContent("屏幕录制权限", value: permission(coordinator.state.permissions.screenRecording))
                Button("申请屏幕录制权限") { control(.screenPermission) }
                LabeledContent("辅助功能权限", value: permission(coordinator.state.permissions.accessibility))
                Button("申请辅助功能权限") { control(.accessibilityPermission) }
                Button("刷新权限状态") { control(.refreshPermissions) }
                Text("权限申请只由对应按钮触发。授予屏幕录制权限后，系统可能要求重新打开应用。").font(.caption).foregroundStyle(.secondary)
                LabeledContent("最近截图", value: quality(coordinator.state.qualities.screenshot))
                LabeledContent("最近应用历史", value: quality(coordinator.state.qualities.application))
                LabeledContent("最近窗口标题", value: quality(coordinator.state.qualities.windowTitle))
                LabeledContent("最近辅助功能文本", value: quality(coordinator.state.qualities.accessibilityText))
            } else {
                Text(service.initializationFailed ? "本地存储未能打开，请重新载入设置。" : "正在打开本地存储…")
            }
        }
        Section("删除本地记录") {
            DatePicker("删除日期", selection: $deletionDate, displayedComponents: .date)
            Button("查看此日删除范围…", role: .destructive) {
                working = true
                Task {
                    defer { working = false }
                    do { deletion = try await service.prepareDeletion(date: deletionDate) }
                    catch { message = "无法读取删除范围；采集保持暂停。" }
                }
            }.disabled(working || service.coordinator == nil || service.isReviewWriting)
            Text("先暂停，再确认日期和数量。删除后保持暂停；可自行继续。系统快照与备份不在此删除范围内。").font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout) }
        }
        .confirmationDialog("删除此日的本地记录？", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button("删除所列内容", role: .destructive) {
                    working = true
                    Task {
                        defer { working = false }
                        do { try await service.delete(deletion); message = "已删除 \(deletion.summary)，采集保持暂停。" }
                        catch { message = "删除未完成或范围已变化，请重新查看范围。" }
                    }
                }.disabled(deletion.isEmpty)
            }
            Button("取消", role: .cancel) { deletion = nil }
        } message: {
            if let deletion {
                Text("\(deletion.interval.start.formatted(date: .complete, time: .omitted))，共 \(deletion.summary)，包括关联证据。此操作不可撤销。")
            }
        }
    }

    private func control(_ action: CaptureAction) {
        working = true
        Task {
            defer { working = false }
            do { try await service.control(action) }
            catch { message = "采集控制未完全完成，请查看状态后重试。" }
        }
    }

    private func permission(_ value: CapturePermission) -> String { value == .granted ? "已授予" : "尚未授予" }
    private func mode(_ value: CaptureMode) -> String {
        switch value {
        case .stopped: "已停止"
        case .paused: "已暂停"
        case .suspended: "系统锁定、睡眠或会话非活跃；暂停采样"
        case .disabled: "所有来源已关闭"
        case .excluded: "当前应用已排除；不采样"
        case .running: "采样调度运行中"
        }
    }
    private func quality(_ value: CaptureQuality) -> String {
        switch value {
        case .disabled: "未启用 / 尚无采样"
        case .available: "已取得内容"
        case .empty: "无可用内容"
        case .truncated: "已取得部分内容（达到长度限制）"
        case .permissionRequired: "需要系统权限"
        case .unavailable: "当前不可用"
        case .failed: "采样失败"
        }
    }
}
