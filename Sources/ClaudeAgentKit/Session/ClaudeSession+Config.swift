// @author ixxxxoooo
// 会话配置:初始化后的模型/模式/强度/Fast/Agent 装配,以及运行中的切换与配置选项同步。

import ACPKit
import Foundation
import OMLog

extension ClaudeSession {
    // MARK: 初始装配

    /// 用 `initialize` 的响应装配会话配置状态。
    /// - Parameters:
    ///   - initResult: CLI 初始化响应
    ///   - initialMode: 解析出的初始权限模式
    ///   - resumedModel: 恢复会话时转录里的模型
    ///   - isResume: 是否恢复历史会话
    func configure(initResult: JSONValue, initialMode: String, resumedModel: String?, isResume: Bool) async throws {
        let sdkModels = (initResult["models"]?.arrayValue ?? []).compactMap(ModelInfo.init)
        var allowed = sdkModels
        if let allowlist = claudeSettings.availableModels {
            allowed = ModelCatalog.applyAllowlist(sdkModels, allowlist: allowlist, overrides: claudeSettings.modelOverrides, denied: claudeSettings.managedDeniedModels, customOption: nil)
        }
        models = await chooseInitialModel(allowed: allowed, sdkModels: sdkModels, resumedModel: resumedModel, isResume: isResume)
        let currentInfo = allowed.first { $0.value == models.currentModelId } ?? ModelCatalog.resolvePreference(sdkModels, models.currentModelId)
        modelInfos = allowed
        if !allowed.contains(where: { $0.value == models.currentModelId }), let info = currentInfo {
            var extra = info
            extra.value = models.currentModelId
            extra.displayName = models.currentModelId
            extra.description = ""
            extra.resolvedModel = nil
            modelInfos.append(extra)
        }

        availableModes = PermissionModes.available(allowBypass: allowBypass)
        var mode = initialMode
        if mode == "auto", let currentInfo, !currentInfo.supportsAutoMode {
            log.warning("auto 模式对当前模型不可用,回退", ["model": models.currentModelId])
            mode = PermissionModes.autoFallback
            autoFallbackWarnPending = true
            await syncPermissionMode(mode)
        } else if !availableModes.contains(where: { $0.id == mode }) {
            mode = "default"
            await syncPermissionMode(mode)
        }
        currentMode = mode

        agents = AgentOptions.custom(from: initResult["agents"])
        let requestedAgent = spec.meta?.at("claudeCode", "options", "agent")?.stringValue
        currentAgent = requestedAgent.flatMap { name in agents.contains(where: { $0.name == name }) ? name : nil } ?? AgentOptions.defaultId

        let fastState = initResult["fast_mode_state"]?.stringValue
        fastEnabled = fastState != nil && FastModeOptions.enabled(state: fastState)
        fastDisabledReason = fastEnabled ? nil : FastModeOptions.normalizeReason(initResult["fast_mode_disabled_reason"]?.stringValue)

        rawCommands = initResult["commands"]?.arrayValue ?? []
        account = initResult["account"]
        if let inferred = ModelCatalog.inferContextWindow(models.currentModelId, currentInfo?.displayName, currentInfo?.description, currentInfo?.value) {
            usage.contextWindowSize = inferred
        }
        configOptions = buildConfigOptions()
        schedulePostSetup()
    }

    /// 选出初始模型(优先级:环境变量 > 设置 > 恢复会话 > CLI 默认),必要时通知 CLI 切换。
    private func chooseInitialModel(allowed: [ModelInfo], sdkModels: [ModelInfo], resumedModel: String?, isResume: Bool) async -> ModelState {
        guard !allowed.isEmpty else {
            let fallback = (isResume ? resumedModel : nil) ?? sdkModels.first?.value ?? "default"
            return ModelState(available: [], currentModelId: fallback)
        }
        var current = allowed[0]
        var resolvedFromInput: String?
        let envModel = config.environment["ANTHROPIC_MODEL"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_MODEL"]
        if let envModel, !envModel.isEmpty {
            if let match = ModelCatalog.resolvePreference(allowed, envModel) { current = match; resolvedFromInput = envModel }
        } else if let model = claudeSettings.model, let match = ModelCatalog.resolvePreference(allowed, model) {
            current = match
            resolvedFromInput = model
        }
        if resolvedFromInput == nil, isResume, let resumedModel { current = ModelCatalog.matchResumed(allowed, liveModel: resumedModel) }
        let sdkDefault = sdkModels.first { $0.value == "default" }
        let sdkDefaultDropped = sdkDefault != nil && !allowed.contains { $0.value == "default" }
        let switchToListed = resolvedFromInput == nil && (!isResume || resumedModel == nil) && sdkDefaultDropped
        let sdkSawSame = sdkModels.contains { $0.value == current.value }
        let skipSet = (resolvedFromInput == nil && !switchToListed) || (!isResume && current.value == resolvedFromInput && sdkSawSame)
        if !skipSet, let query {
            do {
                try await query.control("set_model", ["model": .string(current.value)])
            } catch {
                log.error("初始模型切换失败", error: error, ["model": current.value])
                if isResume, let resumedModel {
                    current = ModelCatalog.matchResumed(allowed, liveModel: resumedModel)
                } else {
                    current = switchToListed ? (sdkDefault ?? allowed[0]) : allowed[0]
                }
            }
        }
        return ModelCatalog.state(models: allowed, currentModelId: current.value)
    }

    func syncPermissionMode(_ mode: String) async {
        do {
            try await query?.control("set_permission_mode", ["mode": .string(mode)])
        } catch {
            log.error("同步权限模式失败", error: error, ["mode": mode])
        }
    }

    /// 装配完成后异步推送可用命令。
    private func schedulePostSetup() {
        Task { [weak self] in
            await self?.sendAvailableCommands()
        }
    }

    // MARK: 配置选项

    var currentModelInfo: ModelInfo? { modelInfos.first { $0.value == models.currentModelId } }

    /// 构造完整的配置选项列表。
    func buildConfigOptions() -> [JSONValue] {
        var options: [JSONValue] = [PermissionModes.configOption(current: currentMode, available: availableModes)]
        if !models.available.isEmpty { options.append(ModelCatalog.configOption(state: models, infos: modelInfos)) }
        let effortCurrent = effortPinned ?? EffortOptions.settingsEffort(claudeSettings, model: currentModelInfo, modelId: models.currentModelId)
        if let effort = EffortOptions.configOption(infos: modelInfos, currentModelId: models.currentModelId, current: effortCurrent) { options.append(effort) }
        if currentModelInfo?.supportsFastMode == true {
            options.append(FastModeOptions.configOption(enabled: fastEnabled, boolean: caps.booleanConfig, disabledReason: fastDisabledReason))
        }
        if let agent = AgentOptions.configOption(current: currentAgent, agents: agents) { options.append(agent) }
        return options
    }

    /// 把某个配置选项的当前值改写到缓存的选项列表里。
    private func setOptionValue(_ configId: String, _ value: String) {
        configOptions = configOptions.map { option in
            guard option["id"]?.stringValue == configId, option["currentValue"]?.stringValue != nil, var object = option.objectValue else { return option }
            object["currentValue"] = .string(value)
            return .object(object)
        }
    }

    private func refreshFastOption() {
        let refreshed = FastModeOptions.configOption(enabled: fastEnabled, boolean: caps.booleanConfig, disabledReason: fastDisabledReason)
        configOptions = configOptions.map { $0["id"]?.stringValue == FastModeOptions.configId ? refreshed : $0 }
    }

    // MARK: ACP 入口

    /// `session/set_mode`。
    /// - Returns: 实际生效的模式
    func setMode(_ requested: String) async throws -> String {
        try requireOpen()
        guard let mode = PermissionModes.parse(requested) else { throw JSONRPCError(code: JSONRPCError.internalError, message: "Invalid Mode") }
        guard availableModes.contains(where: { $0.id == mode }) else {
            throw JSONRPCError(code: JSONRPCError.internalError, message: "Mode \(requested) is not available in this session")
        }
        let effective = effectiveMode(mode)
        do {
            try await query?.control("set_permission_mode", ["mode": .string(effective)])
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription.isEmpty ? "Invalid Mode" : error.localizedDescription)
        }
        if effective != mode { await publishAutoFallbackWarning() }
        if effective != requested { await send(["sessionUpdate": "current_mode_update", "currentModeId": .string(effective)]) }
        await updateConfigOption(PermissionModes.configId, .string(effective))
        return effective
    }

    /// `session/set_config_option`。
    /// - Returns: 更新后的配置选项
    func setConfigOption(configId: String, value: JSONValue) async throws -> [JSONValue] {
        try requireOpen()
        guard let option = configOptions.first(where: { $0["id"]?.stringValue == configId }) else {
            throw JSONRPCError(code: JSONRPCError.internalError, message: "Unknown config option: \(configId)")
        }
        if configId == FastModeOptions.configId {
            guard let enabled = FastModeOptions.parse(value) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Invalid value for config option fast: \(value.jsonText)")
            }
            try await applyFastMode(enabled)
            return configOptions
        }
        guard let text = value.stringValue else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Invalid value for config option \(configId): \(value.jsonText)")
        }
        let values = (option["options"]?.arrayValue ?? []).flatMap { $0["options"]?.arrayValue ?? [$0] }
        var valid = values.first { $0["value"]?.stringValue == text }?["value"]?.stringValue
        if valid == nil, option["currentValue"]?.stringValue == text { valid = text }
        if valid == nil, configId == ModelCatalog.configId { valid = ModelCatalog.resolvePreference(modelInfos, text)?.value }
        guard let resolved = valid else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Invalid value for config option \(configId): \(text)")
        }
        var effective = resolved
        if configId == PermissionModes.configId {
            effective = try await selectMode(resolved)
            await send(["sessionUpdate": "current_mode_update", "currentModeId": .string(effective)])
        } else if configId == ModelCatalog.configId {
            do { try await query?.control("set_model", ["model": .string(resolved)]) } catch {
                throw JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription)
            }
        }
        try await applyConfigOptionValue(configId, effective)
        return configOptions
    }

    private func selectMode(_ requested: String) async throws -> String {
        guard let mode = PermissionModes.parse(requested), availableModes.contains(where: { $0.id == mode }) else {
            throw JSONRPCError(code: JSONRPCError.internalError, message: "Mode \(requested) is not available in this session")
        }
        let effective = effectiveMode(mode)
        do {
            try await query?.control("set_permission_mode", ["mode": .string(effective)])
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription.isEmpty ? "Invalid Mode" : error.localizedDescription)
        }
        if effective != mode { await publishAutoFallbackWarning() }
        return effective
    }

    func requireOpen() throws {
        if closed || query == nil { throw JSONRPCError(code: JSONRPCError.internalError, message: "会话已结束") }
    }

    /// `auto` 对当前模型不可用时回退为 `acceptEdits`。
    func effectiveMode(_ requested: String, modelId: String? = nil) -> String {
        guard requested == "auto" else { return requested }
        let info = modelInfos.first { $0.value == (modelId ?? models.currentModelId) }
        if let info, !info.supportsAutoMode { return PermissionModes.autoFallback }
        return requested
    }

    // MARK: 取值应用

    /// 应用一个配置项的新值(CLI 侧切换已完成或不需要)。
    func applyConfigOptionValue(_ configId: String, _ value: String) async throws {
        switch configId {
        case PermissionModes.configId:
            if value != "plan" { prePlanMode = nil } else if currentMode != "plan" { prePlanMode = currentMode }
            currentMode = value
            setOptionValue(configId, value)
        case ModelCatalog.configId:
            await applyModelSwitch(value)
        case AgentOptions.configId:
            try await applyFlagSettings(["agent": value == AgentOptions.defaultId ? .null : .string(value)])
            currentAgent = value
            setOptionValue(configId, value)
        case EffortOptions.configId:
            try await applyFlagSettings(EffortOptions.flagSettings(value, ultracode: claudeSettings.ultracode).objectValue ?? [:])
            setOptionValue(configId, value)
            effortPinned = value == "default" ? nil : value
        default:
            setOptionValue(configId, value)
        }
    }

    func applyFlagSettings(_ settings: [String: JSONValue]) async throws {
        do {
            try await query?.control("apply_flag_settings", ["settings": .object(settings)])
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError, message: error.localizedDescription)
        }
    }

    /// 模型切换后的联动:上下文窗口、模式降级、强度与 Fast 选项重算。
    private func applyModelSwitch(_ value: String) async {
        let info = modelInfos.first { $0.value == value }
        let changed = models.currentModelId != value
        if changed {
            usage.contextWindowSize = ModelCatalog.inferContextWindow(value, info?.displayName, info?.description) ?? UsageTracker.defaultContextWindow
            usage.contextWindowAuthoritative = false
        }
        models.currentModelId = value
        var downgraded = false
        if currentMode == "auto", let info, !info.supportsAutoMode {
            currentMode = PermissionModes.autoFallback
            downgraded = true
            await syncPermissionMode(currentMode)
        }
        if fastDisabledReason == "model_not_allowed" { fastDisabledReason = nil }
        if let pinned = effortPinned, !(info?.supportsEffort == true && info?.supportedEffortLevels.contains(pinned) == true) {
            effortPinned = nil
            do { try await applyFlagSettings(EffortOptions.flagSettings(nil, ultracode: claudeSettings.ultracode).objectValue ?? [:]) } catch {
                log.error("模型切换后同步强度失败", error: error, ["model": value])
            }
        }
        configOptions = buildConfigOptions()
        if downgraded {
            await send(["sessionUpdate": "current_mode_update", "currentModeId": .string(PermissionModes.autoFallback)])
            await publishAutoFallbackWarning()
        }
    }

    /// 应用后推送 `config_option_update`。
    func updateConfigOption(_ configId: String, _ value: JSONValue) async {
        guard !closed, let text = value.stringValue else { return }
        do { try await applyConfigOptionValue(configId, text) } catch {
            log.error("同步配置项失败", error: error, ["config": configId])
        }
        await send(["sessionUpdate": "config_option_update", "configOptions": .array(configOptions)])
    }

    // MARK: Fast 模式

    func applyFastMode(_ enabled: Bool) async throws {
        try await applyFlagSettings(["fastMode": .bool(enabled)])
        fastEnabled = enabled
        refreshFastOption()
    }

    /// 结果/初始化消息携带的 Fast 状态同步。
    func syncFastModeState(_ state: String?, reason: String?) async {
        guard let state, state != "cooldown" else { return }
        guard configOptions.contains(where: { $0["id"]?.stringValue == FastModeOptions.configId }) else { return }
        let enabled = state == "on"
        let nextReason = enabled ? nil : FastModeOptions.normalizeReason(reason)
        if enabled == fastEnabled, nextReason == fastDisabledReason { return }
        let wasEnabled = fastEnabled
        fastEnabled = enabled
        fastDisabledReason = nextReason
        refreshFastOption()
        if wasEnabled, !enabled, let nextReason, let explanation = FastModeOptions.explanation(nextReason) {
            await send(Notices.updateOrTranscript(severity: "warning", title: "Fast mode turned off", description: "\(Notices.sentenceCase(explanation)).", supports: caps.notices, transcript: "**Fast mode turned off:** \(explanation)."))
        }
        await send(["sessionUpdate": "config_option_update", "configOptions": .array(configOptions)])
    }

    /// CLI 内部(如 `/model`)切换了模型后同步 ACP 状态。
    func syncModelAfterExternalSwitch(_ switched: String) async {
        let value = ModelCatalog.resolvePreference(modelInfos, switched)?.value ?? switched
        guard models.currentModelId != value else { return }
        await updateConfigOption(ModelCatalog.configId, .string(value))
    }

    // MARK: 提示

    /// 首次回退到 `acceptEdits` 时给用户一条提示。
    func publishAutoFallbackWarning() async {
        autoFallbackWarnPending = false
        guard !autoFallbackWarned else { return }
        autoFallbackWarned = true
        await send(Notices.updateOrTranscript(
            severity: "warning", title: "Auto mode unavailable",
            description: Notices.sentenceCase(PermissionModes.autoFallbackReason), supports: caps.notices,
            transcript: Notices.transcriptText(title: "Auto mode unavailable", description: PermissionModes.autoFallbackReason)
        ))
    }

    // MARK: 命令清单

    /// 推送 `available_commands_update`。
    func sendAvailableCommands() async {
        guard !closed else { return }
        await send(["sessionUpdate": "available_commands_update", "availableCommands": .array(SlashCommands.advertised(rawCommands, terminal: terminalCommands))])
    }
}

extension ClaudeSession {
    /// 载入历史回放产生的消息 ID → UUID 映射(分叉点定位用)。
    func adoptReplay(messageIdToUuid map: [String: String]) {
        for (key, value) in map { messageIdToUuid[key] = value }
    }

    /// 会话创建响应里的模式块。
    var modesJSON: JSONValue {
        [
            "currentModeId": .string(currentMode),
            "availableModes": .array(availableModes.map { ["id": .string($0.id), "name": .string($0.name), "description": .string($0.description)] }),
        ]
    }
}
