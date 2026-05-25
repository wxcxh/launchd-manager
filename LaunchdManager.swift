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

struct AIMessage: Codable {
    let role: String
    let content: String
}

struct AIRequest: Codable {
    let model: String
    let messages: [AIMessage]
    let temperature: Double
    let stream: Bool
}

struct AIResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

struct AIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta?
    }

    let choices: [Choice]
}

enum LaunchdError: LocalizedError {
    case invalidTime
    case missingSelection
    case commandFailed(String)
    case disabledAgent(String)
    case invalidAIConfig(String)
    case unsupportedSchedule

    var errorDescription: String? {
        switch self {
        case .invalidTime:
            return "请输入有效的 24 小时制时间。"
        case .missingSelection:
            return "请先选择一个任务。"
        case .commandFailed(let message):
            return message
        case .disabledAgent(let label):
            return "\(label) 还没有启用。请先点击“启用”，再立即执行。"
        case .invalidAIConfig(let message):
            return message
        case .unsupportedSchedule:
            return "当前只支持编辑每天固定时刻执行的任务。"
        }
    }
}

final class LaunchdStore: ObservableObject {
    static let noteKey = "CodexNote"
    static let hourOptions = (0...23).map { String(format: "%02d", $0) }
    static let minuteOptions = (0...59).map { String(format: "%02d", $0) }
    static let toastDuration: TimeInterval = 2
    static let defaultAIBaseURL = "http://124.222.11.178:3000/v1"
    static let defaultAIModelID = "gpt-5.5"
    static let aiBaseURLKey = "AIBaseURL"
    static let aiModelIDKey = "AIModelID"
    static let aiAPIKeyKey = "AIAPIKey"

    @Published var agents: [LaunchAgent] = []
    @Published var selectedID: String?
    @Published var hour: String = ""
    @Published var minute: String = ""
    @Published var noteText: String = ""
    @Published var statusText: String = "准备就绪"
    @Published var toastMessage: String?
    @Published var isToastError: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var isGeneratingNotes: Bool = false
    @Published var aiProgressText: String = ""
    @Published var isTestingAIConnection: Bool = false
    @Published var aiBaseURL: String = UserDefaults.standard.string(forKey: aiBaseURLKey) ?? defaultAIBaseURL
    @Published var aiModelID: String = UserDefaults.standard.string(forKey: aiModelIDKey) ?? defaultAIModelID
    @Published var aiAPIKey: String = UserDefaults.standard.string(forKey: aiAPIKeyKey) ?? ""

    private var toastToken = UUID()

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
            showError(LaunchdError.missingSelection.localizedDescription)
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
            showSuccess(statusText)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func saveTime() {
        guard let agent = selectedAgent else {
            showError(LaunchdError.missingSelection.localizedDescription)
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
            showSuccess(statusText)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func enableSelected() {
        guard let agent = selectedAgent else {
            showError(LaunchdError.missingSelection.localizedDescription)
            return
        }

        do {
            try reloadAgent(plistPath: agent.plistPath)
            loadAgents()
            selectedID = agent.id
            statusText = "已启用 \(agent.label)"
            showSuccess(statusText)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func disableSelected() {
        guard let agent = selectedAgent else {
            showError(LaunchdError.missingSelection.localizedDescription)
            return
        }

        do {
            _ = try runCommand(["launchctl", "bootout", "gui/\(getuid())", agent.plistPath], allowFailure: true)
            loadAgents()
            selectedID = agent.id
            statusText = "已停用 \(agent.label)"
            showSuccess(statusText)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func runNow() {
        guard let agent = selectedAgent else {
            showError(LaunchdError.missingSelection.localizedDescription)
            return
        }

        do {
            if !agent.isEnabled {
                throw LaunchdError.disabledAgent(agent.label)
            }
            _ = try runCommand(["launchctl", "kickstart", "-k", "gui/\(getuid())/\(agent.label)"])
            loadAgents()
            selectedID = agent.id
            statusText = "已执行 \(agent.label)"
            showSuccess(statusText)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func openLaunchAgentsDir() {
        NSWorkspace.shared.open(launchAgentsDir)
        statusText = "已打开 plist 目录"
        showSuccess(statusText)
    }

    @discardableResult
    func saveAIConfig() -> Bool {
        let baseURLText = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURLText.isEmpty, URL(string: baseURLText) != nil else {
            showError(LaunchdError.invalidAIConfig("AI 配置保存失败：Base URL 无效。").localizedDescription)
            return false
        }
        guard !modelID.isEmpty else {
            showError(LaunchdError.invalidAIConfig("AI 配置保存失败：模型 ID 不能为空。").localizedDescription)
            return false
        }
        guard !apiKey.isEmpty else {
            showError(LaunchdError.invalidAIConfig("AI 配置保存失败：API 密钥不能为空。").localizedDescription)
            return false
        }

        aiBaseURL = baseURLText
        aiModelID = modelID
        aiAPIKey = apiKey
        UserDefaults.standard.set(baseURLText, forKey: Self.aiBaseURLKey)
        UserDefaults.standard.set(modelID, forKey: Self.aiModelIDKey)
        UserDefaults.standard.set(apiKey, forKey: Self.aiAPIKeyKey)
        statusText = "已保存 AI 配置"
        showSuccess(statusText)
        return true
    }

    func generateNotesWithAI() {
        guard !isGeneratingNotes else { return }

        let baseURLText = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = aiModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURLText.isEmpty, let baseURL = URL(string: baseURLText) else {
            showError(LaunchdError.invalidAIConfig("请输入有效的 Base URL。").localizedDescription)
            return
        }
        guard !modelID.isEmpty else {
            showError(LaunchdError.invalidAIConfig("请输入模型 ID。").localizedDescription)
            return
        }
        guard !apiKey.isEmpty else {
            showError(LaunchdError.invalidAIConfig("请输入 API 密钥。").localizedDescription)
            return
        }

        let plistURLs: [URL]
        do {
            plistURLs = try FileManager.default.contentsOfDirectory(
                at: launchAgentsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "plist" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            showError(error.localizedDescription)
            return
        }

        guard !plistURLs.isEmpty else {
            showError("没有找到 LaunchAgent plist。")
            return
        }

        let missingNotePlistURLs: [URL]
        do {
            missingNotePlistURLs = try plistURLs.filter { plistURL in
                let plist = try readPlist(at: plistURL)
                let note = (plist[Self.noteKey] as? String) ?? ""
                return note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        } catch {
            showError(error.localizedDescription)
            return
        }

        guard !missingNotePlistURLs.isEmpty else {
            statusText = "所有任务都已有备注"
            showSuccess(statusText)
            return
        }

        UserDefaults.standard.set(baseURLText, forKey: Self.aiBaseURLKey)
        UserDefaults.standard.set(modelID, forKey: Self.aiModelIDKey)
        UserDefaults.standard.set(apiKey, forKey: Self.aiAPIKeyKey)
        isGeneratingNotes = true
        aiProgressText = "准备分析 \(missingNotePlistURLs.count) 个"
        statusText = "AI 正在为 \(missingNotePlistURLs.count) 个无备注任务生成备注..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var updatedCount = 0
                for (index, plistURL) in missingNotePlistURLs.enumerated() {
                    DispatchQueue.main.async {
                        self.statusText = "AI 正在分析无备注任务 \(index + 1)/\(missingNotePlistURLs.count): \(plistURL.lastPathComponent)"
                        self.aiProgressText = "分析 \(index + 1)/\(missingNotePlistURLs.count)"
                    }

                    var plist = try self.readPlist(at: plistURL)
                    let existingNote = (plist[Self.noteKey] as? String) ?? ""
                    guard existingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }

                    let context = try self.aiContext(for: plistURL, plist: plist)
                    let note = try self.requestAINote(
                        baseURL: baseURL,
                        modelID: modelID,
                        apiKey: apiKey,
                        context: context
                    )
                    plist[Self.noteKey] = note
                    try self.writePlist(plist, to: plistURL)
                    updatedCount += 1
                }

                DispatchQueue.main.async {
                    self.isGeneratingNotes = false
                    self.aiProgressText = ""
                    self.loadAgents()
                    self.statusText = "AI 已为 \(updatedCount) 个无备注任务填写备注"
                    self.showSuccess(self.statusText)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isGeneratingNotes = false
                    self.aiProgressText = ""
                    self.statusText = "AI 生成备注失败"
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func testAIConnection() {
        guard !isTestingAIConnection else { return }

        let baseURLText = aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !baseURLText.isEmpty, let baseURL = URL(string: baseURLText) else {
            showError("测试失败：Base URL 无效。")
            return
        }
        guard !apiKey.isEmpty else {
            showError("测试失败：API 密钥不能为空。")
            return
        }

        isTestingAIConnection = true
        statusText = "正在测试 AI 连接..."

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.requestAIModels(baseURL: baseURL, apiKey: apiKey, timeout: 15)

                DispatchQueue.main.async {
                    self.isTestingAIConnection = false
                    self.statusText = "AI 连接正常"
                    self.showSuccess(self.statusText)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isTestingAIConnection = false
                    self.statusText = "AI 连接测试失败"
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func showSuccess(_ message: String) {
        showToast(message, isError: false)
    }

    func showError(_ message: String) {
        showToast(message, isError: true)
    }

    private func showToast(_ message: String, isError: Bool) {
        let token = UUID()
        toastToken = token
        toastMessage = message
        isToastError = isError

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.toastDuration) {
            guard self.toastToken == token else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                self.toastMessage = nil
            }
        }
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

    private func aiContext(for plistURL: URL, plist: [String: Any]) throws -> String {
        let label = (plist["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent
        let command = commandText(from: plist)
        let schedule = scheduleText(from: plist["StartCalendarInterval"])
        let runAtLoad = String(describing: plist["RunAtLoad"] ?? false)
        let keepAlive = String(describing: plist["KeepAlive"] ?? false)
        let watchPaths = plist["WatchPaths"] as? [String] ?? []
        let executablePaths = executablePaths(from: plist)
        let scriptSummaries = executablePaths.map { path in
            scriptContext(forPath: path)
        }.joined(separator: "\n\n")

        return """
        plist 文件: \(plistURL.path)
        Label: \(label)
        命令: \(command)
        固定时间: \(schedule)
        RunAtLoad: \(runAtLoad)
        KeepAlive: \(keepAlive)
        WatchPaths: \(watchPaths.isEmpty ? "-" : watchPaths.joined(separator: ", "))

        脚本或命令信息:
        \(scriptSummaries.isEmpty ? "未读取到脚本内容，可能是 app 二进制或系统命令。" : scriptSummaries)
        """
    }

    private func executablePaths(from plist: [String: Any]) -> [String] {
        var paths: [String] = []
        if let args = plist["ProgramArguments"] as? [String] {
            paths.append(contentsOf: args.filter { $0.hasPrefix("/") })
        }
        if let program = plist["Program"] as? String, program.hasPrefix("/") {
            paths.append(program)
        }
        return Array(Set(paths)).sorted()
    }

    private func scriptContext(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return "路径不存在或不是文件: \(path)"
        }

        let extensions = ["sh", "zsh", "bash", "py", "js", "mjs", "ts", "rb", "pl", "command", "tool"]
        let shouldRead = extensions.contains(url.pathExtension.lowercased()) || path.hasSuffix(".plist")
        guard shouldRead else {
            return "命令路径: \(path)"
        }

        guard let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8) else {
            return "无法读取文本内容: \(path)"
        }

        let maxLength = 2000
        if text.count > maxLength {
            text = String(text.prefix(maxLength)) + "\n...（内容过长，已截断）"
        }
        return "文件: \(path)\n内容:\n\(text)"
    }

    private func requestAINote(baseURL: URL, modelID: String, apiKey: String, context: String) throws -> String {
        let systemPrompt = "根据 macOS LaunchAgent 的 label、命令和触发条件，输出一句中文用途备注。只输出备注本身，不要解释，不超过 30 个汉字。"
        let note = try requestAICompletion(
            baseURL: baseURL,
            modelID: modelID,
            apiKey: apiKey,
            messages: [
                AIMessage(role: "system", content: systemPrompt),
                AIMessage(role: "user", content: context)
            ],
            timeout: 180
        )
        return String(note.prefix(80))
    }

    private func requestAICompletion(
        baseURL: URL,
        modelID: String,
        apiKey: String,
        messages: [AIMessage],
        timeout: TimeInterval
    ) throws -> String {
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let requestBody = AIRequest(model: modelID, messages: messages, temperature: 0.2, stream: true)
        request.httpBody = try JSONEncoder().encode(requestBody)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, Error>!

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(LaunchdError.commandFailed("AI 接口没有返回有效响应。"))
                return
            }
            guard (200...299).contains(httpResponse.statusCode), let data else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(LaunchdError.commandFailed("AI 接口请求失败：HTTP \(httpResponse.statusCode) \(body)"))
                return
            }

            do {
                let content = try self.parseAIContent(from: data)
                guard !content.isEmpty else {
                    throw LaunchdError.commandFailed("AI 没有返回内容。")
                }
                result = .success(content)
            } catch {
                result = .failure(error)
            }
        }.resume()

        semaphore.wait()
        return try result.get()
    }

    private func requestAIModels(baseURL: URL, apiKey: String, timeout: TimeInterval) throws {
        let endpoint = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                result = .failure(error)
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                result = .failure(LaunchdError.commandFailed("AI 接口没有返回有效响应。"))
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                result = .failure(LaunchdError.commandFailed("AI 连接测试失败：HTTP \(httpResponse.statusCode) \(body)"))
                return
            }

            result = .success(())
        }.resume()

        semaphore.wait()
        try result.get()
    }

    private func parseAIContent(from data: Data) throws -> String {
        if let response = try? JSONDecoder().decode(AIResponse.self, from: data),
           let content = response.choices.first?.message.content {
            return cleanAIContent(content)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw LaunchdError.commandFailed("AI 返回内容无法解析。")
        }

        var streamedContent = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }

            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(AIStreamChunk.self, from: chunkData) else {
                continue
            }
            streamedContent += chunk.choices.compactMap { $0.delta?.content }.joined()
        }

        let cleaned = cleanAIContent(streamedContent)
        if !cleaned.isEmpty {
            return cleaned
        }

        throw LaunchdError.commandFailed("AI 返回内容无法解析：\(String(text.prefix(300)))")
    }

    private func cleanAIContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
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
    @State private var isAISettingsPresented = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(appTitle)
                            .font(.system(size: 22, weight: .bold))
                        Spacer()
                        Button {
                            store.generateNotesWithAI()
                        } label: {
                            if store.isGeneratingNotes {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(store.aiProgressText.isEmpty ? "生成中..." : store.aiProgressText)
                                }
                            } else {
                                Text("AI 生成备注")
                            }
                        }
                        .disabled(store.isGeneratingNotes || store.isRefreshing)

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

                    ZStack(alignment: .bottomLeading) {
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
                        .padding(.bottom, 56)

                        Button {
                            isAISettingsPresented = true
                        } label: {
                            Text("⚙ AI 配置")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 96)
                        }
                        .buttonStyle(.bordered)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
                        )
                        .help("AI 配置")
                        .padding(.leading, 0)
                        .padding(.bottom, 0)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(minWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                .padding(20)

                Divider()

                if store.selectedAgent == nil {
                    newScriptPlaceholder
                        .frame(minWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
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
                                    Picker("小时", selection: $store.hour) {
                                        ForEach(LaunchdStore.hourOptions, id: \.self) { value in
                                            Text(value).tag(value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 92)

                                    Text(":")

                                    Picker("分钟", selection: $store.minute) {
                                        ForEach(LaunchdStore.minuteOptions, id: \.self) { value in
                                            Text(value).tag(value)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 92)

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
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                    }
                    .frame(minWidth: 420)
                }
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
        .overlay(alignment: .bottom) {
            if let toastMessage = store.toastMessage {
                toastView(message: toastMessage, isError: store.isToastError)
                    .padding(.bottom, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toastMessage)
        .frame(minWidth: 980, minHeight: 620)
        .background(WindowAccessor(title: appTitle))
        .onAppear {
            store.refreshAgents(statusTextOverride: "已加载任务列表")
        }
        .onChange(of: store.selectedID) { _ in
            store.syncTimeFields()
        }
        .sheet(isPresented: $isAISettingsPresented) {
            aiSettingsView
        }
    }

    private var aiSettingsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("AI 配置")
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(.system(size: 12, weight: .semibold))
                TextField("http://124.222.11.178:3000/v1", text: $store.aiBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型 ID")
                    .font(.system(size: 12, weight: .semibold))
                TextField("gpt-5.5", text: $store.aiModelID)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API 密钥")
                    .font(.system(size: 12, weight: .semibold))
                SecureField("请输入 API 密钥", text: $store.aiAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button {
                    store.testAIConnection()
                } label: {
                    if store.isTestingAIConnection {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("测试中...")
                        }
                    } else {
                        Text("测试连通性")
                    }
                }
                .disabled(store.isTestingAIConnection)

                Spacer()
                Button("取消") {
                    isAISettingsPresented = false
                }
                Button("保存") {
                    if store.saveAIConfig() {
                        isAISettingsPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var newScriptPlaceholder: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新增脚本")
                .font(.system(size: 22, weight: .bold))

            Text("选择左侧任务可查看和编辑详情。未选择任务时，可以从这里新增一个 LaunchAgent 脚本任务。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                detailRow(title: "任务名称", value: "")
                detailRow(title: "脚本路径", value: "")
                detailRow(title: "每日时间", value: "")
                detailRow(title: "备注", value: "")
            }

            HStack {
                Button("选择脚本...") {
                    store.showError("新增脚本功能还没有接入。")
                }
                Button("创建任务") {
                    store.showError("新增脚本功能还没有接入。")
                }
            }
        }
        .padding(20)
    }

    private func toastView(message: String, isError: Bool) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isError ? Color.white : Color.primary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isError ? Color.red.opacity(0.92) : Color(NSColor.windowBackgroundColor).opacity(0.96))
                    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isError ? Color.red.opacity(0.25) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
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
