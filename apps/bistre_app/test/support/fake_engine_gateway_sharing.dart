part of 'fake_engine_gateway.dart';

/// Provider share codes, windowed history, compaction, and MCP Registry search of
/// [FakeEngineGateway] (split by responsibility). The code mirrors core's `ai-provider:v1:` shape.
/// Core's window over write order: the newest [limit] (1..500) before [beforeNodeId].
List<EngineNode> _windowOf(
  List<EngineNode> thread,
  String? beforeNodeId,
  int limit,
) {
  var end = thread.length;
  if (beforeNodeId != null) {
    end = thread.indexWhere((n) => n.id == beforeNodeId);
    if (end < 0) throw StateError('diag.storage.not_found');
  }
  final cap = limit.clamp(1, 500);
  return thread.sublist(end > cap ? end - cap : 0, end);
}

mixin _FakeSharingAndHistory implements BistreEngineGateway {
  List<EngineProvider> get _providers;
  List<EngineNode> get _nodes;
  abstract int _clock;
  Future<void> _record(String method, Map<String, Object?> args);

  @override
  Future<EngineNode> compactThread({
    required String threadId,
    int keepRecentTurns = 4,
    String? customSummary,
    String? instructions,
  }) async {
    await _record('compactThread', <String, Object?>{
      'threadId': threadId,
      'instructions': instructions,
    });
    final summary = EngineNode(
      id: 'compact-${++_clock}',
      threadId: threadId,
      parentId: _nodes.where((n) => n.threadId == threadId).lastOrNull?.id,
      role: 'compaction_summary',
      content: customSummary ?? 'Condensed summary of earlier turns.',
      createdAtMs: _clock,
    );
    _nodes.add(summary);
    return summary;
  }

  @override
  Future<EngineNode> rewriteCompactionSummary({
    required String threadId,
    required String nodeId,
    required String content,
  }) async {
    await _record('rewriteCompactionSummary', <String, Object?>{
      'nodeId': nodeId,
      'content': content,
    });
    final at = _nodes.indexWhere(
      (n) => n.id == nodeId && n.role == 'compaction_summary',
    );
    if (at < 0) throw StateError('diag.storage.not_found');
    final old = _nodes[at];
    return _nodes[at] = EngineNode(
      id: old.id,
      threadId: old.threadId,
      parentId: old.parentId,
      role: old.role,
      content: content.trim(),
      providerMetaJson: old.providerMetaJson,
      createdAtMs: old.createdAtMs,
      attachments: old.attachments,
    );
  }

  @override
  Future<void> undoCompaction({
    required String threadId,
    required String compactionNodeId,
  }) async {
    _nodes.removeWhere((n) => n.id == compactionNodeId);
  }

  static const String _sharePrefix = 'ai-provider:v1:';

  /// The registry a test serves (query, cursor -> page); unset, the registry is unreachable.
  EngineMcpRegistryPage Function(String query, String? cursor)? registryPages;

  @override
  Future<EngineMcpRegistryPage> searchMcpRegistry(
    String query, {
    String? cursor,
  }) async {
    await _record('searchMcpRegistry', <String, Object?>{
      'query': query,
      'cursor': cursor,
    });
    final pages = registryPages;
    if (pages == null) throw StateError('diag.provider.request_failed');
    return pages(query, cursor);
  }

  @override
  Future<String> exportProviderShareCode({
    required String providerId,
    bool includeApiKey = false,
  }) async {
    await _record('exportProviderShareCode', <String, Object?>{
      'providerId': providerId,
      'includeApiKey': includeApiKey,
    });
    final p = _providers.firstWhere((p) => p.id == providerId);
    final keys = includeApiKey
        ? await getProviderApiKeys(providerId)
        : const <String>[];
    final payload = <String, Object?>{
      'name': p.name,
      'dialect': p.dialect,
      'baseUrl': p.baseUrl,
      'defaultModel': p.defaultModel,
      if (keys.isNotEmpty) 'apiKey': keys.first,
    };
    return '$_sharePrefix${base64Url.encode(utf8.encode(jsonEncode(payload)))}';
  }

  @override
  Future<EngineProvider> importProviderShareCode(String code) async {
    await _record('importProviderShareCode', <String, Object?>{'code': code});
    final clean = code.trim();
    if (!clean.startsWith(_sharePrefix)) {
      throw StateError('diag.validation.invalid_input');
    }
    final Map<String, Object?> payload;
    try {
      payload = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize(clean.substring(_sharePrefix.length)),
          ),
        ),
      ) as Map<String, Object?>;
    } on FormatException {
      throw StateError('diag.validation.invalid_input');
    }
    return createProvider(
      name: payload['name']! as String,
      dialect: payload['dialect']! as String,
      baseUrl: payload['baseUrl']! as String,
      defaultModel: payload['defaultModel'] as String? ?? '',
      iconSlug: '',
      customIconPath: '',
      apiKey: payload['apiKey'] as String?,
    );
  }

  @override
  Future<List<EngineNode>> listNodesWindow({
    required String threadId,
    String? beforeNodeId,
    required int limit,
  }) async {
    await _record('listNodesWindow', <String, Object?>{
      'threadId': threadId,
      'beforeNodeId': beforeNodeId,
      'limit': limit,
    });
    return _windowOf(
      _nodes.where((n) => n.threadId == threadId).toList(growable: false),
      beforeNodeId,
      limit,
    );
  }

  /// The ledger spend a test sets for every chat; unset, the replies' recorded costs.
  int? threadSpendMicros;

  @override
  Future<int> getThreadSpendMicros(String threadId) async =>
      threadSpendMicros ??
      _nodes
          .where((n) => n.threadId == threadId)
          .fold<int>(0, (sum, n) => sum + (n.usageMeta?.costMicros ?? 0));

  /// [threadId]'s messages in write order.
  List<EngineNode> nodesOf(String threadId) =>
      _nodes.where((n) => n.threadId == threadId).toList(growable: false);

  @override
  Future<int> threadHistoryRev(String threadId) async =>
      _nodes.where((n) => n.threadId == threadId).length;
}
