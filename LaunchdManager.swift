import AppKit
import Foundation
import SwiftUI

let appTitle = "launchd 定时任务管理"

struct LaunchAgent: Identifiable, Hashable {
    let id: String
    let label: String
    let plistPath: String
    let command: String
    let timeText: String
    let isEnabled: Bool
    let note: String
}

enum LaunchdError: LocalizedError {
    case invalidTime
    case missingSelection
    case commandFailed(String)
    case unsupportedSchedule

    var errorDescription: String? {
        switch self {
        case .invalidTime:
            return "请输入有效的 24 小时制时间。"
        case .missingSelection:
            return "请先选择一个任务。"
        case .commandFailed(let message):
            return message
        case .unsupportedSchedule:
            return "当前只支持编辑每天固定时刻执行的任务。"
        }
    }
}

final class LaunchdStore: ObservableObject {
    static let noteKey = "CodexNote"

    @Published var agents: [LaunchAgent] = []
    @Published var selectedID: String?
    @Published var hour: String = ""
    @Published var minute: String = ""
    @Published var noteText: String = ""
    @Published var statusText: String = "准备就绪"
    @Published var alertMessage: String?
    @Published var isRefreshing: Bool = false

    let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents", isDirectory: true)

    var selectedAgent: LaunchAgent? {
        agents.first(where: { $0.id == selectedID })
    }

    func refreshAgents(statusTextOverride: String? = nil) {
        guard !isRefreshing else { return }

        let previousSelection = selectedID
        isRefreshing = true
        statusText = "正在刷新任务..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let activeLabels = try self.loadActiveLabels()
                let agents = try self.readAgents(activeLabels: activeLabels)
                DispatchQueue.main.async {
                    self.agents = agents
                    if let previousSelection, agents.contains(where: { $0.id == previousSelection }) {
                        self.selectedID = previousSelection
                    } else {
                        self.selectedID = agents.first?.id
                    }
                    self.syncTimeFields()
                    self.isRefreshing = false
                    self.statusText = statusTextOverride ?? "已刷新 \(agents.count) 个 LaunchAgent"
                }
            } catch {
                DispatchQueue.main.async {
                    self.alertMessage = error.localizedDescription
                    self.statusText = "刷新失败"
                    self.isRefreshing = false
                }
            }
        }
    }

    func loadAgents() {
        do {
            let activeLabels = try loadActiveLabels()
            agents = try readAgents(activeLabels: activeLabels)

            if selectedAgent == nil {
                selectedID = agents.first?.id
            }
            syncTimeFields()
            statusText = "已加载 \(agents.count) 个 LaunchAgent"
        } catch {
            alertMessage = error.localizedDescription
            statusText = "加载失败"
        }
    }

    func syncTimeFields() {
        guard let selectedAgent else {
            hour = ""
            minute = ""
            noteText = ""
            return
        }

        let parts = selectedAgent.timeText.split(separator: ":")
        if parts.count == 2 {
            hour = String(parts[0])
            minute = String(parts[1])
        } else {
            hour = ""
            minute = ""
        }
        noteText = selectedAgent.note
    }

    func saveNote() {
        guard let agent = selectedAgent else {
            alertMessage = LaunchdError.missingSelection.localizedDescription
            return
        }

        do {
            let url = URL(fileURLWithPath: agent.plistPath)
            var plist = try readPlist(at: url)
            let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                plist.removeValue(forKey: Self.noteKey)
            } else {
                plist[Self.noteKey] = trimmed
            }
            try writePlist(plist, to: url)
            loadAgents()
            selectedID = agent.id
            syncTimeFields()
            statusText = trimmed.isEmpty ? "已清空 \(agent.label) 的备注" : "已保存 \(agent.label) 的备注"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func saveTime() {
        guard let agent = selectedAgent else {
            alertMessage = LaunchdError.missingSelection.localizedDescription
            return
        }

        do {
            let hourValue = try parseTimeComponent(hour, range: 0...23)
            let minuteValue = try parseTimeComponent(minute, range: 0...59)

            let url = URL(fileURLWithPath: agent.plistPath)
            var plist = try readPlist(at: url)
            plist["StartCalendarInterval"] = ["Hour": hourValue, "Minute": minuteValue]
            try writePlist(plist, to: url)
            try reloadAgent(plistPath: agent.plistPath)
            loadAgents()
            selectedID = agent.id
            syncTimeFields()
            statusText = "已更新 \(agent.label) 到 \(String(format: "%02d:%02d", hourValue, minuteValue))"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func enableSelected() {
        guard let agent = selectedAgent else {
            alertMessage = LaunchdError.missingSelection.localizedDescription
            return
        }

        do {
            try reloadAgent(plistPath: agent.plistPath)
            loadAgents()
            selectedID = agent.id
            statusText = "已启用 \(agent.label)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func disableSelected() {
        guard let agent = selectedAgent else {
            alertMessage = LaunchdError.missingSelection.localizedDescription
            return
        }

        do {
            _ = try runCommand(["launchctl", "bootout", "gui/\(getuid())", agent.plistPath], allowFailure: true)
            loadAgents()
            selectedID = agent.id
            statusText = "已停用 \(agent.label)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func runNow() {
        guard let agent = selectedAgent else {
            alertMessage = LaunchdError.missingSelection.localizedDescription
            return
        }

        do {
            let plist = try readPlist(at: URL(fileURLWithPath: agent.plistPath))
            let arguments = (plist["ProgramArguments"] as? [String]) ?? []
            if !arguments.isEmpty {
                _ = try runCommand(arguments)
            } else if let program = plist["Program"] as? String {
                _ = try runCommand([program])
            } else {
                throw LaunchdError.commandFailed("这个 LaunchAgent 没有可执行命令。")
            }
            statusText = "已执行 \(agent.label)"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openLaunchAgentsDir() {
        NSWorkspace.shared.open(launchAgentsDir)
    }

    private func loadActiveLabels() throws -> Set<String> {
        let output = try runCommand(["launchctl", "list"])
        let labels = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.last.map(String.init)
            }
        return Set(labels)
    }

    private func readAgents(activeLabels: Set<String>) throws -> [LaunchAgent] {
        let plistURLs = try FileManager.default.contentsOfDirectory(
            at: launchAgentsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "plist" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try plistURLs.map { url in
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw LaunchdError.commandFailed("无法读取 plist: \(url.path)")
            }

            let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let command = commandText(from: plist)
            let timeText = scheduleText(from: plist["StartCalendarInterval"])
            let isEnabled = activeLabels.contains(label)
            let note = (plist[Self.noteKey] as? String) ?? ""

            return LaunchAgent(
                id: label,
                label: label,
                plistPath: url.path,
                command: command,
                timeText: timeText,
                isEnabled: isEnabled,
                note: note
            )
        }
    }

    private func scheduleText(from value: Any?) -> String {
        guard let dict = value as? [String: Any],
              let hour = dict["Hour"] as? Int,
              let minute = dict["Minute"] as? Int else {
            return "-"
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func commandText(from plist: [String: Any]) -> String {
        if let args = plist["ProgramArguments"] as? [String], !args.isEmpty {
            return args.joined(separator: " ")
        }
        if let program = plist["Program"] as? String {
            return program
        }
        return "-"
    }

    private func parseTimeComponent(_ value: String, range: ClosedRange<Int>) throws -> Int {
        guard let number = Int(value), range.contains(number) else {
            throw LaunchdError.invalidTime
        }
        return number
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw LaunchdError.commandFailed("读取 plist 失败: \(url.path)")
        }
        return plist
    }

    private func writePlist(_ plist: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func reloadAgent(plistPath: String) throws {
        _ = try runCommand(["launchctl", "bootout", "gui/\(getuid())", plistPath], allowFailure: true)
        _ = try runCommand(["launchctl", "bootstrap", "gui/\(getuid())", plistPath])
    }

    private func runCommand(_ args: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if process.terminationStatus != 0 && !allowFailure {
            throw LaunchdError.commandFailed(err.isEmpty ? out : err)
        }
        return out
    }
}

struct ContentView: View {
    @StateObject private var store = LaunchdStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(appTitle)
                            .font(.system(size: 22, weight: .bold))
                        Spacer()
                        Button {
                            store.refreshAgents()
                        } label: {
                            if store.isRefreshing {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("刷新中...")
                                }
                            } else {
                                Text("刷新")
                            }
                        }
                        .disabled(store.isRefreshing)
                    }

                    List(selection: $store.selectedID) {
                        ForEach(store.agents) { agent in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.label)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(agent.timeText == "-" ? "无固定日程" : agent.timeText)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                    if !agent.note.isEmpty {
                                        Text(agent.note)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text(agent.isEnabled ? "已启用" : "未启用")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(agent.isEnabled ? .green : .secondary)
                            }
                            .padding(.vertical, 4)
                            .tag(agent.id)
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(minWidth: 420)
                .padding(20)

                Divider()

                VStack(alignment: .leading, spacing: 14) {
                    Text("任务详情")
                        .font(.system(size: 22, weight: .bold))

                    detailRow(title: "名称", value: store.selectedAgent?.label ?? "")
                    detailRow(title: "plist 路径", value: store.selectedAgent?.plistPath ?? "")
                    detailRow(title: "命令", value: store.selectedAgent?.command ?? "")
                    detailRow(title: "时间", value: store.selectedAgent?.timeText ?? "")
                    detailRow(title: "状态", value: (store.selectedAgent?.isEnabled ?? false) ? "已启用" : "未启用")
                    detailRow(title: "备注", value: store.selectedAgent?.note ?? "")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("修改每日时间")
                            .font(.system(size: 14, weight: .semibold))
                        HStack {
                            TextField("14", text: $store.hour)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 56)
                            Text(":")
                            TextField("26", text: $store.minute)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 56)
                            Button("保存时间") {
                                store.saveTime()
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("编辑备注")
                            .font(.system(size: 14, weight: .semibold))
                        TextEditor(text: $store.noteText)
                            .font(.system(size: 13))
                            .frame(minHeight: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                        HStack {
                            Button("保存备注") {
                                store.saveNote()
                            }
                            if !store.noteText.isEmpty {
                                Button("清空备注") {
                                    store.noteText = ""
                                    store.saveNote()
                                }
                            }
                        }
                    }

                    HStack {
                        Button("立即执行") {
                            store.runNow()
                        }
                        Button("启用") {
                            store.enableSelected()
                        }
                        Button("停用") {
                            store.disableSelected()
                        }
                        Button("打开 plist 目录") {
                            store.openLaunchAgentsDir()
                        }
                    }

                    Spacer()
                }
                .frame(minWidth: 420)
                .padding(20)
            }

            Divider()

            HStack {
                Text(store.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(WindowAccessor(title: appTitle))
        .onAppear {
            store.refreshAgents(statusTextOverride: "已加载任务列表")
        }
        .onChange(of: store.selectedID) { _ in
            store.syncTimeFields()
        }
        .alert("操作提示", isPresented: Binding(
            get: { store.alertMessage != nil },
            set: { newValue in
                if !newValue {
                    store.alertMessage = nil
                }
            })
        ) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}

@main
struct LaunchdManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
