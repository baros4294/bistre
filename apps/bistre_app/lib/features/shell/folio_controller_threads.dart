part of 'folio_controller.dart';

/// Draft, message, branch, agent-workspace, MCP, and tool actions of [FolioController].
extension FolioThreadActions on FolioController {
  // --- Drafts, Messages, Branch Edit & Delete ---

  /// Saves [text] as the open chat's draft after a short pause in typing. The composer calls
  /// this for every change to its text, including its own clears after a send or a command
  /// , so a stored draft never outlives the text it came from.
  void scheduleDraftSave(String text) {
    final tid = _activeThread?.id;
    if (tid == null) return;
    draftSavedState.value = false;
    _pendingDraft = (threadId: tid, text: text);
    _draftDebounce?.cancel();
    _draftDebounce = Timer(
      const Duration(milliseconds: 220),
      () => unawaited(flushPendingDraft()),
    );
  }

  /// Saves the draft still waiting in the debounce now (the app is paused, closing, or
  /// the composer goes away), so the last keystrokes are never lost.
  Future<void> flushPendingDraft() async {
    _draftDebounce?.cancel();
    final pending = _pendingDraft;
    _pendingDraft = null;
    if (pending == null) return;
    await _persistDraftNow(pending.threadId, pending.text);
  }

  Future<void> _persistDraftNow(String threadId, String text) async {
    try {
      await _gateway.saveDraft(threadId, text);
      if (_disposed) return;
      draftSavedState.value = text.isNotEmpty;
    } catch (e) {
      _fail(e);
    }
  }

  Future<bool> submitPassage(String rawText) async {
    final body = rawText.trim();
    final active = _activeThread;
    if ((body.isEmpty && _attachments.isEmpty) || active == null) return false;
    // Never send while another chat is loading; the text stays in the composer.
    if (isSwitchingThread) return false;
    final generation = _threadGeneration;
    if (isStreaming) {
      if (body.isEmpty) return false;
      return enqueueSteeringMessage(body);
    }

    final inlineRefs = _attachments
        .where((a) => a.inlineReference.isNotEmpty)
        .map((a) => a.inlineReference)
        .toList(growable: false);
    final fileAttachments = _attachments
        .where((a) => a.inlineReference.isEmpty && a.path.isNotEmpty)
        .map(
          (a) => EngineAttachmentInput(
            name: a.name,
            mimeType: a.mimeType,
            localPath: a.path,
          ),
        )
        .toList(growable: false);
    final refPrefix = inlineRefs.isEmpty ? '' : '${inlineRefs.join('\n')}\n\n';
    final fullPrompt = _quotedExcerpt != null
        ? '$refPrefix> $_quotedExcerpt\n\n$body'
        : '$refPrefix$body';

    try {
      _lastDiagnosticKey = null;
      final visible = visibleBranchNodes;
      final parentId = visible.isEmpty ? null : visible.last.id;
      final committed = fileAttachments.isNotEmpty
          ? await _gateway.sendAndStreamReplyWithAttachments(
              threadId: active.id,
              parentId: parentId,
              userContent: fullPrompt,
              attachments: fileAttachments,
            )
          : await _gateway.sendAndStreamReply(
              threadId: active.id,
              parentId: parentId,
              userContent: fullPrompt,
            );

      if (visible.isEmpty && isDefaultThreadTitle(active.title)) {
        _autoTitledThreads.add(active.id);
        final derived = body.replaceAll(RegExp(r'\s+'), ' ');
        final shortTitle = clipText(derived, 44);
        final renamed = await _gateway.updateThread(
          threadId: active.id,
          title: shortTitle,
        );
        if (_isStillOn(active.id, generation)) _activeThread = renamed;
      }

      // The user may have switched chats while this send was in flight.
      if (_isStillOn(active.id, generation)) {
        if (!_nodes.any((n) => n.id == committed.id)) {
          _nodes = <EngineNode>[..._nodes, committed];
        }
        _quotedExcerpt = null;
        _attachments = const <ComposerAttachment>[];
        draftSavedState.value = false;
      }
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      _health = await _gateway.getHealth();
      _notify();
      return true;
    } catch (e) {
      _fail(e);
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
      await _reloadActiveNodes(active.id);
      final parentKey = _parentKeyOf(committed);
      final siblings = _childrenByParent[parentKey];
      if (siblings != null && siblings.isNotEmpty) {
        _selectedChildIndex[parentKey] = siblings.length - 1;
      }
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  /// Asks core's Title model (Settings > Default models) for a short title for [threadId].
  Future<void> regenerateThreadTitle(
    String threadId, {
    bool quiet = false,
  }) async {
    try {
      final updated = await _gateway.generateThreadTitle(threadId);
      if (_disposed) return;
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      if (_activeThread?.id == updated.id) _activeThread = updated;
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _walletDailySpendMicros = await _gateway.getWalletDailySpendMicros();
      _notify();
    } catch (e) {
      if (!quiet) {
        _fail(e);
      } else {
        _noteNonFatal('auto_title', e);
      }
    }
  }

  /// Translates [node] using Settings > Default models > Translation and selects the new sibling.
  Future<void> translateMessage(
    EngineNode node, {
    String? targetLanguage,
  }) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      _lastDiagnosticKey = null;
      final created = await _gateway.translateNode(
        threadId: active.id,
        nodeId: node.id,
        targetLanguage: targetLanguage,
      );
      if (_disposed) return;
      await _reloadActiveNodes(active.id);
      if (_activeThread?.id == active.id) {
        final parentKey = _parentKeyOf(created);
        final siblings = _childrenByParent[parentKey];
        if (siblings != null) {
          final idx = siblings.indexWhere((s) => s.id == created.id);
          if (idx >= 0) _selectedChildIndex[parentKey] = idx;
        }
      }
      _walletSpendMicros = await _gateway.getWalletSpendMicros();
      _walletDailySpendMicros = await _gateway.getWalletDailySpendMicros();
      showToast(L10nKey.toastTranslated);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Copies the conversation up to [nodeId] into a new chat and opens it.
  Future<void> branchIntoNewChat(String nodeId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      final fork = await _gateway.forkThread(
        threadId: active.id,
        nodeId: nodeId,
      );
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      await _activateThread(fork);
      showToast(L10nKey.toastBranched);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// `/rewind`: removes the last message the user sent with everything after it.
  Future<void> rewindLastTurn() async {
    final active = _activeThread;
    final lastUser = visibleBranchNodes.reversed
        .where((n) => n.role == 'user')
        .firstOrNull;
    if (active == null || lastUser == null) return;
    try {
      await _gateway.deleteFromNode(threadId: active.id, nodeId: lastUser.id);
      await _reloadActiveNodes(active.id);
      _selectedChildIndex.clear();
      showToast(L10nKey.toastNodeDeleted);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Deletes every message of the open chat and keeps the chat.
  Future<void> clearActiveMessages() async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.clearThreadMessages(active.id);
      await _reloadActiveNodes(active.id);
      _selectedChildIndex.clear();
      _storageStats = await _gateway.getStorageStats();
      showToast(L10nKey.toastMessagesCleared);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> deleteMessageNode(String nodeId) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.deleteNode(threadId: active.id, nodeId: nodeId);
      await _reloadActiveNodes(active.id);
      _selectedChildIndex.clear();
      _storageStats = await _gateway.getStorageStats();
      showToast(L10nKey.toastNodeDeleted);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Regenerates [assistantNode]; a non-empty [guidance] is the direction the new reply
  /// follows (`/guide`).
  Future<void> regenerateFromAssistantNode(
    EngineNode assistantNode, {
    String guidance = '',
  }) async {
    final tid = _activeThread?.id;
    final parentUserId = assistantNode.parentId;
    if (tid == null || parentUserId == null) return;
    final previousNodeId = assistantNode.id;
    try {
      _lastDiagnosticKey = null;
      if (guidance.isEmpty) {
        await _gateway.regenerateReply(threadId: tid, userNodeId: parentUserId);
      } else {
        await _gateway.regenerateReplyGuided(
          threadId: tid,
          userNodeId: parentUserId,
          guidance: guidance,
        );
      }
      if (_disposed) return;
      showToast(
        L10nKey.toastRegenerated,
        actionKey: L10nKey.toastRegeneratedPrevious,
        duration: const Duration(seconds: 8),
        onAction: () {
          dismissToast();
          if (_liveRuns.containsKey(tid)) {
            unawaited(cancelStreaming());
          }
          selectSiblingNodeById(parentUserId, previousNodeId);
        },
      );
    } catch (e) {
      _fail(e);
    }
  }

  /// "Allow once" for `diag.wallet.price_unknown`: lets this chat's next run send requests
  /// whose price is unknown under a spending cap, then retries the last message.
  Future<void> allowUnpricedOnceAndRetry() async {
    final tid = _activeThread?.id;
    final lastUser = visibleBranchNodes.reversed
        .where((n) => n.role == 'user')
        .firstOrNull;
    if (tid == null || lastUser == null) return;
    try {
      _lastDiagnosticKey = null;
      _notify();
      await _gateway.allowUnpricedOnce(tid);
      await _gateway.regenerateReply(threadId: tid, userNodeId: lastUser.id);
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> cancelStreaming() async {
    final tid = _activeThread?.id;
    if (tid == null) return;
    try {
      await _gateway.cancelActiveRun(tid);
    } catch (e) {
      _fail(e);
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
      _fail(e);
    }
  }

  // --- Agent Workspace, MCP, Compaction, Pin, and Tool Controls ---

  /// The app's open folder (Settings); a chat works in [workspaceRootPath].
  String get appWorkspaceRootPath => _workspaceRootPath;

  String get webSearchEndpoint => _webSearchEndpoint;

  List<EngineMcpServerConfig> get mcpServers => _mcpServers;

  String? get pinnedContextNodeId => _pinnedContextNodeId;

  /// The open chat's tool rows: never another chat's.
  List<ToolActivityEntry> get toolActivities =>
      _toolActivitiesByThread[_activeThread?.id] ?? const <ToolActivityEntry>[];

  List<EngineCheckpoint> get checkpoints => _checkpoints;

  String get activeThreadMode => _activeThread?.mode ?? 'chat';

  Future<void> _loadAgentWorkspaceConfig() async {
    try {
      _workspaceRootPath =
          (await _gateway.getKvMeta('agent.workspace_root')) ?? '';
      _webSearchEndpoint = (await _gateway.getKvMeta('agent.web_search')) ?? '';
      _profileAvatarPath = (await _gateway.getKvMeta('user.avatar_path')) ?? '';
      final rawPerms = await _gateway.getKvMeta('agent.tool_permissions');
      if (rawPerms != null && rawPerms.trim().isNotEmpty) {
        final decoded = jsonDecode(rawPerms);
        if (decoded is Map<String, Object?>) {
          _toolPermissions = <String, String>{
            for (final entry in decoded.entries)
              if (entry.value is String) entry.key: entry.value! as String,
          };
        }
      }
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

  Future<void> _loadThreadKvExtras(String threadId, int generation) async {
    final startVersion = ++_threadExtrasVersion;
    try {
      final rawPins = await _gateway.getKvMeta('thread_pinned_nodes:$threadId');
      final rawLimit = await _gateway.getKvMeta('thread_spend_limit:$threadId');
      final rawPrefill = await _gateway.getKvMeta(
        'thread_reply_prefill:$threadId',
      );
      if (generation != _threadGeneration ||
          startVersion != _threadExtrasVersion ||
          _disposed) {
        return;
      }
      final pins = <String>{};
      if (rawPins != null && rawPins.trim().isNotEmpty) {
        final decoded = jsonDecode(rawPins);
        if (decoded is List<Object?>) {
          for (final item in decoded) {
            if (item is String && item.isNotEmpty) pins.add(item);
          }
        }
      }
      _pinnedNodeIds = pins;
      // A pin older than the loaded page still shows in the pinned list.
      unawaited(
        _loadEarlierUntil(
          () => pins.every((id) => _nodes.any((n) => n.id == id)),
        ),
      );
      _replyPrefill = rawPrefill ?? '';
      _activeChatSpendLimitMicros =
          rawLimit != null && rawLimit.trim().isNotEmpty
          ? int.tryParse(rawLimit.trim())
          : null;
      _notify();
    } catch (e) {
      _noteNonFatal('thread_kv_extras_load', e);
    }
  }

  void setReplyPrefill(String text) {
    if (_replyPrefill == text) return;
    _replyPrefill = text;
    final tid = _activeThread?.id;
    if (tid != null) {
      unawaited(
        _gateway
            .setKvMeta('thread_reply_prefill:$tid', text)
            .catchError((Object e) => _noteNonFatal('save_reply_prefill', e)),
      );
    }
    _notify();
  }

  Future<void> togglePinNode(String nodeId) async {
    final tid = _activeThread?.id;
    if (tid == null) return;
    final next = Set<String>.from(_pinnedNodeIds);
    final pinned = next.add(nodeId);
    if (!pinned) next.remove(nodeId);
    _threadExtrasVersion++;
    _pinnedNodeIds = next;
    _notify();
    try {
      await _gateway.setKvMeta(
        'thread_pinned_nodes:$tid',
        jsonEncode(next.toList(growable: false)),
      );
      showToast(pinned ? L10nKey.toastPinned : L10nKey.toastUnpinned);
    } catch (e) {
      _noteNonFatal('toggle_pin_node', e);
    }
  }

  void togglePinnedPanel() {
    _pinnedPanelOpen = !_pinnedPanelOpen;
    _notify();
  }

  void closePinnedPanel() {
    if (!_pinnedPanelOpen) return;
    _pinnedPanelOpen = false;
    _notify();
  }

  Future<void> setProfileAvatarPath(String path) async {
    final clean = path.trim();
    _profileAvatarPath = clean;
    _notify();
    try {
      await _gateway.setKvMeta('user.avatar_path', clean);
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _noteNonFatal('save_profile_avatar', e);
    }
  }

  Future<void> setActiveChatSpendLimitMicros(int? micros) async {
    final tid = _activeThread?.id;
    _threadExtrasVersion++;
    _activeChatSpendLimitMicros = micros;
    _notify();
    if (tid == null) return;
    try {
      await _gateway.setKvMeta(
        'thread_spend_limit:$tid',
        micros == null ? '' : micros.toString(),
      );
      showToast(L10nKey.toastSettingsSaved);
    } catch (e) {
      _noteNonFatal('save_chat_spend_limit', e);
    }
  }

  String toolPermissionFor(String toolId) =>
      _toolPermissions[toolId] ??
      switch (toolId) {
        'read_file' || 'grep' || 'glob' => 'allow',
        // These tools stay hidden from the model until the user turns them on.
        'agent_delegate' || 'todo_write' || 'calc_eval' || 'dice_roll' => 'off',
        _ => 'ask',
      };

  Future<void> setToolPermission(String toolId, String mode) async {
    final next = Map<String, String>.from(_toolPermissions);
    next[toolId] = mode;
    _toolPermissions = next;
    _notify();
    try {
      await _gateway.setKvMeta('agent.tool_permissions', jsonEncode(next));
    } catch (e) {
      _noteNonFatal('save_tool_permissions', e);
    }
  }

  /// Where a file sent with a message lives on disk, in the data directory.
  String sentAttachmentPath(EngineNodeAttachment attachment) {
    final dir = _storageStats?.dataDir ?? _bootDataDir ?? '';
    final sep = Platform.pathSeparator;
    final rel = attachment.blobRelPath.replaceAll('/', sep);
    return dir.isEmpty ? rel : '$dir$sep$rel';
  }

  /// Opens a file that was sent with a message, from the data directory.
  void openSentAttachment(EngineNodeAttachment attachment) {
    openAttachmentPreview(
      ComposerAttachment(
        id: attachment.blobRelPath,
        name: attachment.name,
        mimeType: attachment.mimeType,
        path: sentAttachmentPath(attachment),
        sizeBytes: attachment.sizeBytes,
        isImage: attachment.mimeType.startsWith('image/'),
      ),
    );
  }

  void openAttachmentPreview(ComposerAttachment attachment) {
    _previewingAttachment = attachment;
    _notify();
  }

  void closeAttachmentPreview() {
    if (_previewingAttachment == null) return;
    _previewingAttachment = null;
    _notify();
  }

  void openTurnDetails(EngineNode node) {
    _inspectingTurnNode = node;
    _notify();
  }

  void closeTurnDetails() {
    if (_inspectingTurnNode == null) return;
    _inspectingTurnNode = null;
    _notify();
  }

  void openSettingsAt(SettingsTab tab, [String? settingKey]) {
    _highlightedSettingKey = (settingKey != null && settingKey.isNotEmpty)
        ? settingKey
        : null;
    openSettings(tab);
  }

  void clearHighlightedSetting() {
    if (_highlightedSettingKey == null) return;
    _highlightedSettingKey = null;
    _notify();
  }

  /// The workspace's top-level entries for the `@` menu, as last read.
  List<(String, bool)> get workspaceEntries =>
      _workspaceEntriesRoot == workspaceRootPath.trim()
      ? _workspaceEntries
      : const <(String, bool)>[];

  /// How many times the workspace was read for the `@` menu (tests check it stays at one).
  int get workspaceEntryLoads => _workspaceEntryLoads;

  /// Reads the workspace's top-level entries once per root, asynchronously (the old
  /// `listSync` per keystroke froze the window on Windows, where the UI and platform
  /// threads are one).
  Future<void> loadWorkspaceEntries() {
    final root = workspaceRootPath.trim();
    if (root.isEmpty || !BistreDesktopHost.isSafeLocalFolder(root)) {
      return Future<void>.value();
    }
    if (_workspaceEntriesRoot == root) return Future<void>.value();
    return _workspaceEntriesLoading ??= () async {
      _workspaceEntryLoads++;
      final found = <(String, bool)>[];
      try {
        await for (final ent in Directory(root).list(followLinks: false)) {
          final name = ent.path
              .replaceAll(r'\', '/')
              .split('/')
              .where((p) => p.isNotEmpty)
              .lastOrNull;
          if (name == null || name.startsWith('.')) continue;
          found.add((name, ent is Directory));
          if (found.length >= kMaxWorkspaceEntries) break;
        }
      } on FileSystemException catch (e) {
        _noteNonFatal('workspace_entries', e);
      }
      _workspaceEntries = found;
      _workspaceEntriesRoot = root;
      _workspaceEntriesLoading = null;
      _notify();
    }();
  }

  Future<void> setWorkspaceRootPath(String path) async {
    final clean = path.trim();
    _workspaceRootPath = clean;
    _workspaceEntriesRoot = null;
    _workspaceEntries = const <(String, bool)>[];
    try {
      // The folder's name on the Tools chip and in Settings is the confirmation.
      await _gateway.setKvMeta('agent.workspace_root', clean);
      unawaited(refreshWorkspaceHooks());
      _notify();
    } catch (e) {
      _fail(e);
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
      _fail(e);
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
      _fail(e);
    }
  }

  Future<void> setMcpServerEnabled(String serverId, bool enabled) async {
    _mcpServers = _mcpServers
        .map(
          (s) => s.id == serverId
              ? EngineMcpServerConfig(
                  id: s.id,
                  name: s.name,
                  transport: s.transport,
                  command: s.command,
                  args: s.args,
                  url: s.url,
                  enabled: enabled,
                )
              : s,
        )
        .toList(growable: false);
    try {
      await _gateway.setKvMeta(
        'agent.mcp_servers',
        jsonEncode(_mcpServers.map((s) => s.toJson()).toList(growable: false)),
      );
      _notify();
    } catch (e) {
      _fail(e);
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
      _fail(e);
    }
  }

  /// One page of MCP Registry results; `null` when the registry could not be reached
  /// (logged with its diagnostic key).
  Future<EngineMcpRegistryPage?> searchMcpRegistry(
    String query, {
    String? cursor,
  }) async {
    try {
      return await _gateway.searchMcpRegistry(query, cursor: cursor);
    } catch (e) {
      _noteNonFatal('mcp_registry', e);
      return null;
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
      _fail(e);
      return null;
    }
  }

  /// The Thinking chip shows the level, so saving it needs no toast.
  Future<void> setReasoningEffort(String effort) async {
    await updateSettings(
      _settings.copyWith(reasoningEffort: effort),
      quiet: true,
    );
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
      _threads = _withoutPendingDeletes(await _gateway.listThreads());
      // The mode belongs to the chat it was set on; another chat may be open by now.
      if (_activeThread?.id == updated.id) {
        _activeThread = updated;
        if (mode == 'write') {
          await refreshStoryStudio();
        } else {
          _manuscriptViewActive = false;
        }
      }
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// The context breakdown with [draft] counted as the next message (the ring's popover).
  /// Falls back to the last known usage without a draft when there is no visible branch.
  Future<EngineContextBreakdown> contextBreakdownWithDraft(String draft) async {
    final thread = _activeThread?.id;
    final leaf = visibleBranchNodes.lastOrNull?.id;
    if (thread == null || leaf == null) return contextBreakdown.value;
    return _gateway.contextBreakdown(thread, leaf, draft: draft);
  }

  /// Condenses the open chat into a summary; [instructions] say what it should keep.
  Future<void> compactActiveThread({
    int keepRecentTurns = 4,
    String? instructions,
  }) async {
    final active = _activeThread;
    if (active == null) return;
    try {
      await _gateway.compactThread(
        threadId: active.id,
        keepRecentTurns: keepRecentTurns,
        instructions: instructions,
      );
      await _reloadActiveNodes(active.id);
      _lastDiagnosticKey = null;
      _notify();
    } catch (e) {
      _fail(e);
    }
  }

  /// Saves the user's own text for a summary of the open chat. Returns whether it saved.
  Future<bool> rewriteCompactionSummary(String nodeId, String text) async {
    final active = _activeThread;
    if (active == null) return false;
    try {
      await _gateway.rewriteCompactionSummary(
        threadId: active.id,
        nodeId: nodeId,
        content: text,
      );
      await _reloadActiveNodes(active.id);
      _lastDiagnosticKey = null;
      _notify();
      return true;
    } catch (e) {
      _fail(e);
      return false;
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
      await _reloadActiveNodes(active.id);
      showToast(L10nKey.toastNodeDeleted);
      _notify();
    } catch (e) {
      _fail(e);
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
      _fail(e);
    }
  }

  Future<void> rewindCheckpoint(String checkpointId) async {
    final active = _activeThread;
    final root = workspaceRootPath;
    if (active == null || root.isEmpty) return;
    try {
      await _gateway.rewindCheckpoint(
        workspaceRoot: root,
        checkpointId: checkpointId,
      );
      _checkpoints = await _gateway.listCheckpoints(active.id);
      showToast(L10nKey.toolRewoundToast);
      _notify();
    } catch (e) {
      _fail(e);
    }
  }
}
