part of 'folio_controller.dart';

/// Draft, message, branch, agent-workspace, MCP, and tool actions of [FolioController].
extension FolioThreadActions on FolioController {
  // --- Drafts, Messages, Branch Edit & Delete ---

  void scheduleDraftSave(String text) {
    final tid = _activeThread?.id;
    if (tid == null) return;
    draftSavedState.value = false;
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 220), () async {
      await _persistDraftNow(tid, text);
    });
  }

  Future<void> flushDraftNow(String text) async {
    final tid = _activeThread?.id;
    if (tid == null) return;
    _draftDebounce?.cancel();
    await _persistDraftNow(tid, text);
  }

  Future<void> _persistDraftNow(String threadId, String text) async {
    try {
      await _gateway.saveDraft(threadId, text);
      if (_disposed) return;
      draftSavedState.value = text.isNotEmpty;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<bool> submitPassage(String rawText) async {
    final body = rawText.trim();
    final active = _activeThread;
    if (body.isEmpty || active == null) return false;
    if (isStreaming) {
      return enqueueSteeringMessage(body);
    }

    final attachmentPrefix = _attachments.isEmpty
        ? ''
        : '${_attachments.map((a) => a.inlineReference.isNotEmpty ? a.inlineReference : '[Attachment: ${a.name} (${a.mimeType})]').join('\n')}\n\n';
    final fullPrompt = _quotedExcerpt != null
        ? '$attachmentPrefix> $_quotedExcerpt\n\n$body'
        : '$attachmentPrefix$body';

    try {
      _draftDebounce?.cancel();
      _lastDiagnosticKey = null;
      final visible = visibleBranchNodes;
      final parentId = visible.isEmpty ? null : visible.last.id;
      final committed = await _gateway.sendAndStreamReply(
        threadId: active.id,
        parentId: parentId,
        userContent: fullPrompt,
      );

      if (visible.isEmpty && active.title == _defaultThreadTitle) {
        final derived = body.replaceAll(RegExp(r'\s+'), ' ');
        final shortTitle = derived.length > 44
            ? '${derived.substring(0, 44)}...'
            : derived;
        final renamed = await _gateway.updateThread(
          threadId: active.id,
          title: shortTitle,
        );
        _activeThread = renamed;
      }

      if (!_nodes.any((n) => n.id == committed.id)) {
        _nodes = <EngineNode>[..._nodes, committed];
      }
      _quotedExcerpt = null;
      _attachments = const <ComposerAttachment>[];
      draftSavedState.value = false;
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      _health = await _gateway.getHealth();
      _notify();
      return true;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<bool> editUserMessageAndResend(String nodeId, String newText) async {
    final active = _activeThread;
    final clean = newText.trim();
    if (active == null || clean.isEmpty) return false;
    try {
      _lastDiagnosticKey = null;
      final committed = await _gateway.editUserNodeAndStream(
        threadId: active.id,
        nodeId: nodeId,
        newContent: clean,
      );
      _nodes = await _gateway.listNodes(active.id);
      final parentKey = committed.parentId ?? '__root__';
      final siblings = FolioController._groupChildrenByParent(
        _nodes,
      )[parentKey];
      if (siblings != null && siblings.isNotEmpty) {
        _selectedChildIndex[parentKey] = siblings.length - 1;
      }
      _notify();
      return true;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return false;
    }
  }

  Future<void> deleteMessageNode(String nodeId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.deleteNode(threadId: active.id, nodeId: nodeId);
      _nodes = await _gateway.listNodes(active.id);
      _selectedChildIndex.clear();
      _storageStats = await _gateway.getStorageStats();
      showToast(L10nKey.toastNodeDeleted);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> regenerateFromAssistantNode(EngineNode assistantNode) async {
    final tid = _activeThread?.id;
    final parentUserId = assistantNode.parentId;
    if (tid == null || parentUserId == null) return;
    final previousNodeId = assistantNode.id;
    try {
      _lastDiagnosticKey = null;
      await _gateway.regenerateReply(threadId: tid, userNodeId: parentUserId);
      if (_disposed) return;
      showToast(
        L10nKey.toastRegenerated,
        actionKey: L10nKey.toastRegeneratedPrevious,
        duration: const Duration(seconds: 8),
        onAction: () {
          dismissToast();
          if (_streamingThreadId == tid) {
            unawaited(cancelStreaming());
          }
          selectSiblingNodeById(parentUserId, previousNodeId);
        },
      );
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> cancelStreaming() async {
    final tid = _streamingThreadId ?? _activeThread?.id;
    if (tid == null) return;
    try {
      await _gateway.cancelActiveRun(tid);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> updateSearch(String query) async {
    final seq = ++_searchSeq;
    final trimmed = query.trim();
    final tid = _activeThread?.id;
    if (trimmed.isEmpty) {
      search.clear();
      return;
    }
    search.update(query: trimmed);
    // Debounce keystrokes; only the newest query may publish results.
    await Future<void>.delayed(FolioController.searchDebounce);
    if (seq != _searchSeq || _disposed) return;
    try {
      final hits = await _gateway.searchNodes(
        trimmed,
        threadId: search.allThreads ? null : tid,
      );
      if (seq != _searchSeq || _disposed) return;
      search.update(hits: hits);
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  // --- Wave B Agent Workspace, MCP, Compaction, Pin, and Tool Controls ---

  String get workspaceRootPath => _workspaceRootPath;

  String get webSearchEndpoint => _webSearchEndpoint;

  List<EngineMcpServerConfig> get mcpServers => _mcpServers;

  String? get pinnedContextNodeId => _pinnedContextNodeId;

  List<ToolActivityEntry> get toolActivities => _toolActivities;

  List<EngineCheckpoint> get checkpoints => _checkpoints;

  List<EngineLocalServer> get discoveredLocalServers => _discoveredLocalServers;

  String get activeThreadMode => _activeThread?.mode ?? 'chat';

  Future<void> _loadAgentWorkspaceConfig() async {
    try {
      _workspaceRootPath =
          (await _gateway.getKvMeta('agent.workspace_root')) ?? '';
      _webSearchEndpoint = (await _gateway.getKvMeta('agent.web_search')) ?? '';
      final rawMcp = await _gateway.getKvMeta('agent.mcp_servers');
      if (rawMcp != null && rawMcp.trim().isNotEmpty) {
        final decoded = jsonDecode(rawMcp);
        if (decoded is List<Object?>) {
          _mcpServers = decoded
              .whereType<Map<String, Object?>>()
              .map(EngineMcpServerConfig.fromJson)
              .toList(growable: false);
        }
      }
    } catch (e) {
      _noteNonFatal('agent_workspace_config_load', e);
    }
  }

  Future<void> setWorkspaceRootPath(String path) async {
    final clean = path.trim();
    _workspaceRootPath = clean;
    try {
      await _gateway.setKvMeta('agent.workspace_root', clean);
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> setWebSearchEndpoint(String url) async {
    final clean = url.trim();
    _webSearchEndpoint = clean;
    try {
      await _gateway.setKvMeta('agent.web_search', clean);
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> addMcpServer(EngineMcpServerConfig server) async {
    _mcpServers = <EngineMcpServerConfig>[..._mcpServers, server];
    try {
      await _gateway.setKvMeta(
        'agent.mcp_servers',
        jsonEncode(_mcpServers.map((s) => s.toJson()).toList(growable: false)),
      );
      showToast(L10nKey.toastSettingsSaved);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> removeMcpServer(String serverId) async {
    _mcpServers = _mcpServers
        .where((s) => s.id != serverId)
        .toList(growable: false);
    try {
      await _gateway.setKvMeta(
        'agent.mcp_servers',
        jsonEncode(_mcpServers.map((s) => s.toJson()).toList(growable: false)),
      );
      showToast(L10nKey.toastDeleted);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<EngineMcpDiscoveryReport?> discoverMcpServer(
    EngineMcpServerConfig server,
  ) async {
    try {
      final report = await _gateway.discoverMcpServer(server);
      _lastDiagnosticKey = null;
      _notify();
      return report;
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
      return null;
    }
  }

  Future<void> setReasoningEffort(String effort) async {
    await updateSettings(_settings.copyWith(reasoningEffort: effort));
  }

  Future<void> setTermuxBridgeEnabled(bool enabled) async {
    await updateSettings(_settings.copyWith(termuxBridgeEnabled: enabled));
  }

  Future<void> setActiveThreadMode(String mode) async {
    final active = _activeThread;
    if (active == null || active.mode == mode) return;
    try {
      final updated = await _gateway.updateThread(
        threadId: active.id,
        mode: mode,
      );
      _activeThread = updated;
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (mode == 'write') {
        await refreshStoryStudio();
      } else {
        _manuscriptViewActive = false;
      }
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  /// The context breakdown with [draft] counted as the next message (the ring's popover).
  /// Falls back to the last known usage without a draft when there is no visible branch.
  Future<EngineContextUsage> contextUsageWithDraft(String draft) async {
    final thread = _activeThread?.id;
    final leaf = visibleBranchNodes.lastOrNull?.id;
    if (thread == null || leaf == null) return contextUsage.value;
    return _gateway.contextUsage(thread, leaf, draft: draft);
  }

  Future<void> compactActiveThread({int keepRecentTurns = 4}) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.compactThread(
        threadId: active.id,
        keepRecentTurns: keepRecentTurns,
      );
      _nodes = await _gateway.listNodes(active.id);
      _lastDiagnosticKey = null;
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> undoCompaction(String compactionNodeId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.undoCompaction(
        threadId: active.id,
        compactionNodeId: compactionNodeId,
      );
      _nodes = await _gateway.listNodes(active.id);
      showToast(L10nKey.toastNodeDeleted);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> toggleContextStartPin(String nodeId) async {
    final active = _activeThread;
    if (active == null) return;
    final nextPin = _pinnedContextNodeId == nodeId ? null : nodeId;
    try {
      _pinnedContextNodeId = await _gateway.setContextStartPin(
        threadId: active.id,
        nodeId: nextPin,
      );
      showToast(nextPin != null ? L10nKey.toastPinned : L10nKey.toastUnpinned);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> rewindCheckpoint(String checkpointId) async {
    final active = _activeThread;
    if (active == null || _workspaceRootPath.isEmpty) return;
    try {
      await _gateway.rewindCheckpoint(
        workspaceRoot: _workspaceRootPath,
        checkpointId: checkpointId,
      );
      _checkpoints = await _gateway.listCheckpoints(active.id);
      showToast(L10nKey.toolRewoundToast);
      _notify();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
      _notify();
    }
  }

  Future<void> discoverLocalServers() async {
    _detectingLocalServers = true;
    _notify();
    try {
      _discoveredLocalServers = await _gateway.discoverLocalServers();
    } catch (e) {
      _lastDiagnosticKey = FolioController.extractDiagnosticKey(e);
    } finally {
      _detectingLocalServers = false;
      _notify();
    }
  }
}
