part of 'engine_models.dart';

/// Result of executing a built-in workspace or web tool in Rust `bistre-core`.
class EngineToolOutput {
  const EngineToolOutput({
    required this.toolName,
    required this.riskTier,
    required this.ok,
    required this.summary,
    required this.outputText,
    this.diffText,
    this.checkpointId,
    this.durationMs = 0,
  });

  final String toolName;
  final String riskTier;
  final bool ok;
  final String summary;
  final String outputText;
  final String? diffText;
  final String? checkpointId;
  final int durationMs;

  static EngineToolOutput fromJson(Map<String, Object?> m) => EngineToolOutput(
    toolName: m['tool_name'] as String? ?? '',
    riskTier: m['risk_tier'] as String? ?? 'tier0_read_only',
    ok: m['ok'] as bool? ?? false,
    summary: m['summary'] as String? ?? '',
    outputText: m['output_text'] as String? ?? '',
    diffText: m['diff_text'] as String?,
    checkpointId: m['checkpoint_id'] as String?,
    durationMs: (m['duration_ms'] as num?)?.toInt() ?? 0,
  );
}

/// Pre-image workspace file edit checkpoint persisted in SQLite for 1-click Rewind.
class EngineCheckpoint {
  const EngineCheckpoint({
    required this.id,
    required this.threadId,
    required this.filePath,
    required this.preHashBlake3,
    required this.postHashBlake3,
    required this.createdAtMs,
  });

  final String id;
  final String threadId;
  final String filePath;
  final String preHashBlake3;
  final String postHashBlake3;
  final int createdAtMs;
}

/// Configured MCP server entry (`stdio` or Streamable `http`).
class EngineMcpServerConfig {
  const EngineMcpServerConfig({
    required this.id,
    required this.name,
    required this.transport,
    this.command = '',
    this.args = const <String>[],
    this.url = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String transport;
  final String command;
  final List<String> args;
  final String url;
  final bool enabled;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'transport': transport,
    'command': command,
    'args': args,
    'url': url,
    'enabled': enabled,
  };

  static EngineMcpServerConfig fromJson(Map<String, Object?> m) {
    final rawArgs = m['args'];
    return EngineMcpServerConfig(
      id: m['id'] as String? ?? '',
      name: m['name'] as String? ?? '',
      transport: m['transport'] as String? ?? 'http',
      command: m['command'] as String? ?? '',
      args: rawArgs is List<Object?>
          ? rawArgs.whereType<String>().toList(growable: false)
          : const <String>[],
      url: m['url'] as String? ?? '',
      enabled: m['enabled'] as bool? ?? true,
    );
  }
}

/// MCP discovery result detailing negotiated protocol (`2026-07-28` vs `2025-11-25`) and tool names.
/// One page of MCP Registry search results.
class EngineMcpRegistryPage {
  const EngineMcpRegistryPage({required this.entries, this.nextCursor});

  final List<EngineMcpRegistryEntry> entries;

  /// Continues the search; `null` on the last page.
  final String? nextCursor;

  /// Core's page as JSON; anything else is a broken bridge, not data.
  static EngineMcpRegistryPage fromJson(Map<String, Object?> m) =>
      EngineMcpRegistryPage(
        entries: <EngineMcpRegistryEntry>[
          for (final e in m['entries']! as List<Object?>)
            EngineMcpRegistryEntry.fromJson(e! as Map<String, Object?>),
        ],
        nextCursor: m['next_cursor'] as String?,
      );
}

/// A registry server: its listing plus the turned-off profile that adds it.
class EngineMcpRegistryEntry {
  const EngineMcpRegistryEntry({
    required this.name,
    required this.description,
    required this.version,
    required this.server,
  });

  final String name;
  final String description;
  final String version;
  final EngineMcpServerConfig server;

  static EngineMcpRegistryEntry fromJson(Map<String, Object?> m) =>
      EngineMcpRegistryEntry(
        name: m['name']! as String,
        description: m['description']! as String,
        version: m['version']! as String,
        server: EngineMcpServerConfig.fromJson(
          m['server']! as Map<String, Object?>,
        ),
      );
}

class EngineMcpDiscoveryReport {
  const EngineMcpDiscoveryReport({
    required this.negotiatedProtocol,
    this.toolNames = const <String>[],
  });

  final String negotiatedProtocol;
  final List<String> toolNames;

  static EngineMcpDiscoveryReport fromJson(Map<String, Object?> m) {
    final rawTools = m['tools'];
    final names = <String>[];
    if (rawTools is List<Object?>) {
      for (final item in rawTools) {
        if (item is Map<String, Object?> && item['name'] is String) {
          names.add(item['name']! as String);
        }
      }
    }
    return EngineMcpDiscoveryReport(
      negotiatedProtocol: m['negotiated_protocol'] as String? ?? '',
      toolNames: names,
    );
  }
}

/// Persistent cross-chat / workspace memory item backed by SQLite `memory_entries`.
class EngineMemoryEntry {
  const EngineMemoryEntry({
    required this.id,
    required this.scope,
    required this.scopeId,
    required this.key,
    required this.content,
    this.pinned = false,
    this.updatedAtMs = 0,
  });

  final String id;
  final String scope;
  final String scopeId;
  final String key;
  final String content;
  final bool pinned;
  final int updatedAtMs;
}

/// Progressive-disclosure `SKILL.md` frontmatter index entry.
class EngineSkillIndex {
  const EngineSkillIndex({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;

  static EngineSkillIndex fromJson(Map<String, Object?> m) => EngineSkillIndex(
    name: m['name'] as String? ?? '',
    description: m['description'] as String? ?? '',
    path: m['path'] as String? ?? '',
  );
}

/// Scheduled background cron/timer automation job backed by SQLite `cron_jobs`.
class EngineCronJob {
  const EngineCronJob({
    this.id = '',
    required this.name,
    this.workspaceId = 'default',
    this.assistantId = 'default_assistant',
    required this.scheduleExpr,
    required this.prompt,
    this.mode = 'chat',
    this.unattendedPolicy = 'pause_and_notify',
    this.useWorktree = false,
    this.enabled = true,
    this.nextRunMs = 0,
    this.lastRunId,
    this.lastStatus = 'idle',
  });

  final String id;
  final String name;
  final String workspaceId;
  final String assistantId;
  final String scheduleExpr;
  final String prompt;
  final String mode;
  final String unattendedPolicy;
  final bool useWorktree;
  final bool enabled;
  final int nextRunMs;
  final String? lastRunId;
  final String lastStatus;
}

/// Live catalog metadata returned for a single model (`Fill from catalog`).
class EngineModelCatalogInfo {
  const EngineModelCatalogInfo({
    this.contextWindow,
    this.maxOutputTokens,
    this.inputPerMtokMicros,
    this.outputPerMtokMicros,
    this.cachedInputPerMtokMicros,
    this.cacheWritePerMtokMicros,
    this.cacheWrite1hPerMtokMicros,
    this.reasoning,
    this.effortLevels = const <String>[],
    this.writesText = true,
    this.aspectRatios = const <String>[],
    this.resolutions = const <String>[],
    this.durationsS = const <int>[],
  });

  final int? contextWindow;
  final int? maxOutputTokens;
  final int? inputPerMtokMicros;
  final int? outputPerMtokMicros;
  final int? cachedInputPerMtokMicros;
  final int? cacheWritePerMtokMicros;
  final int? cacheWrite1hPerMtokMicros;
  final bool? reasoning;

  /// The thinking levels the model accepts (`off` to `max`); empty when the catalog lists
  /// none, so every level is offered.
  final List<String> effortLevels;

  /// False for a model that only draws, films, or speaks: it has no thinking setting.
  final bool writesText;

  /// The format choices the catalog lists; empty leaves that setting to the provider.
  final List<String> aspectRatios;
  final List<String> resolutions;
  final List<int> durationsS;

  bool get hasMediaChoices =>
      aspectRatios.isNotEmpty ||
      resolutions.isNotEmpty ||
      durationsS.isNotEmpty;
}

/// User-selected file attachment passed from Flutter composer into Rust core.
class EngineAttachmentInput {
  const EngineAttachmentInput({
    required this.name,
    required this.mimeType,
    required this.localPath,
  });

  final String name;
  final String mimeType;
  final String localPath;
}

/// What a paid request was for, as core books it.
enum EngineSpendPurpose { chat, helper, title, summary, translation, voice }

/// Settled spend for one purpose over a time window.
class EnginePurposeUsage {
  const EnginePurposeUsage({
    required this.purpose,
    required this.requests,
    required this.costMicros,
  });

  final EngineSpendPurpose purpose;
  final int requests;
  final int costMicros;
}

/// File entry reported by the Storage & File Manager inside Bistre's data directory.
class EngineStorageFileEntry {
  const EngineStorageFileEntry({
    required this.relPath,
    required this.category,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.deletable,
  });

  final String relPath;
  final String category;
  final int sizeBytes;
  final int modifiedMs;
  final bool deletable;
}

/// One hook from the workspace's `.bistre/hooks.json`, shown for review.
class EngineWorkspaceHook {
  const EngineWorkspaceHook({
    required this.event,
    required this.command,
    this.toolFilter,
  });

  /// `pre_tool_use`, `post_tool_use`, `run_finished`, or `run_failed`.
  final String event;
  final String command;
  final String? toolFilter;
}

/// The workspace's hooks file and whether the user approved exactly this file (by digest).
class EngineWorkspaceHooksStatus {
  const EngineWorkspaceHooksStatus({
    required this.hooks,
    required this.digest,
    required this.approved,
  });

  final List<EngineWorkspaceHook> hooks;
  final String digest;
  final bool approved;
}

/// One web page a reply used; parsed and bounded in core, `http(s)` only.
class EngineGroundingSource {
  const EngineGroundingSource({
    required this.nodeId,
    required this.url,
    required this.title,
    this.citedText,
  });

  final String nodeId;
  final String url;
  final String title;
  final String? citedText;

  /// The site's host name, shown under the title.
  String get host => Uri.tryParse(url)?.host ?? url;
}

/// What core knows about one API format: its default server URL and chat endpoint.
class EngineDialectDescriptor {
  const EngineDialectDescriptor({
    required this.id,
    required this.defaultBaseUrl,
    required this.endpointPath,
    required this.requiresApiKey,
  });

  final String id;
  final String defaultBaseUrl;
  final String endpointPath;
  final bool requiresApiKey;
}

/// The exact URLs core calls a provider at, shown in settings and connection tests.
class EngineResolvedEndpoint {
  const EngineResolvedEndpoint({
    required this.chatUrl,
    required this.modelsUrl,
  });

  final String chatUrl;
  final String modelsUrl;
}

/// One row of the context breakdown. [kind] is a fixed id from core
/// (`messages`, `built_in_tools`, `mcp_tools`, `system_prompt`, `project_instructions`,
/// `workspace_instructions`,
/// `story`, `attachments`, `draft`, `deferred_mcp_tools`); the app maps it to its own words.
class EngineContextCategory {
  const EngineContextCategory({
    required this.kind,
    required this.tokens,
    this.count,
    this.sent = true,
  });

  final String kind;
  final int tokens;
  final int? count;
  final bool sent;

  @override
  bool operator ==(Object other) =>
      other is EngineContextCategory &&
      other.kind == kind &&
      other.tokens == tokens &&
      other.count == count &&
      other.sent == sent;

  @override
  int get hashCode => Object.hash(kind, tokens, count, sent);
}

/// One MCP tool's schema size in the breakdown.
class EngineMcpToolUsage {
  const EngineMcpToolUsage({
    required this.name,
    required this.tokens,
    required this.deferred,
  });

  final String name;
  final int tokens;
  final bool deferred;
}

/// One MCP server and its tools in the breakdown.
class EngineMcpServerUsage {
  const EngineMcpServerUsage({
    required this.serverId,
    required this.label,
    required this.tools,
  });

  final String serverId;
  final String label;
  final List<EngineMcpToolUsage> tools;

  int get tokens => tools.fold(0, (sum, t) => sum + t.tokens);
}

/// What fills the next request, from core: rows, the window, and the kept-free
/// reserve. Core owns every number.
class EngineContextBreakdown {
  const EngineContextBreakdown({
    this.categories = const <EngineContextCategory>[],
    this.totalSent = 0,
    this.limitTokens,
    this.reserveTokens = 0,
    this.mcp = const <EngineMcpServerUsage>[],
    this.mcpTruncated = false,
  });

  static const EngineContextBreakdown empty = EngineContextBreakdown();

  final List<EngineContextCategory> categories;
  final int totalSent;
  final int? limitTokens;
  final int reserveTokens;
  final List<EngineMcpServerUsage> mcp;
  final bool mcpTruncated;

  int tokensOf(String kind) =>
      categories.where((c) => c.kind == kind).firstOrNull?.tokens ?? 0;

  int? countOf(String kind) =>
      categories.where((c) => c.kind == kind).firstOrNull?.count;

  @override
  bool operator ==(Object other) =>
      other is EngineContextBreakdown &&
      other.totalSent == totalSent &&
      other.limitTokens == limitTokens &&
      other.reserveTokens == reserveTokens &&
      other.mcpTruncated == mcpTruncated &&
      other.mcp.length == mcp.length &&
      _listEquals(other.categories, categories);

  @override
  int get hashCode => Object.hash(
    totalSent,
    limitTokens,
    reserveTokens,
    mcpTruncated,
    mcp.length,
    Object.hashAll(categories),
  );

  static bool _listEquals(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Credential-free snapshot of the exact wire request core would send next for a chat.
class EngineInspectedRequest {
  const EngineInspectedRequest({
    required this.method,
    required this.url,
    required this.dialect,
    required this.model,
    required this.headers,
    required this.bodyJson,
  });

  final String method;
  final String url;
  final String dialect;
  final String model;
  final List<(String, String)> headers;
  final String bodyJson;
}
