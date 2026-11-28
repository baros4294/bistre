import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/engine_models.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Search of the public MCP Registry inside the MCP servers card. Core leaves out servers
/// Bistre cannot run as listed; a server added here starts turned off.
class McpRegistryBrowser extends StatefulWidget {
  const McpRegistryBrowser({super.key, required this.controller});

  final FolioController controller;

  @override
  State<McpRegistryBrowser> createState() => _McpRegistryBrowserState();
}

class _McpRegistryBrowserState extends State<McpRegistryBrowser> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  final List<EngineMcpRegistryEntry> _entries = <EngineMcpRegistryEntry>[];
  String? _cursor;
  bool _loading = false;
  bool _failed = false;

  /// Bumped by each new search, so a slower earlier answer is dropped.
  int _search = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(more: false));
  }

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  Future<void> _load({required bool more}) async {
    final search = more ? _search : ++_search;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final page = await widget.controller.searchMcpRegistry(
      _query.text,
      cursor: more ? _cursor : null,
    );
    if (!mounted || search != _search) return;
    setState(() {
      _loading = false;
      _failed = page == null;
      if (!more) _entries.clear();
      if (page != null) {
        _entries.addAll(page.entries);
        _cursor = page.nextCursor;
      }
    });
  }

  bool _isAdded(EngineMcpServerConfig s) => widget.controller.mcpServers.any(
    (m) => s.transport == 'http'
        ? m.url == s.url
        : m.command == s.command && m.args.join(' ') == s.args.join(' '),
  );

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final searchLabel = l10n.t(L10nKey.settingsAgentMcpRegistrySearch);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: QuillInput(
                  controller: _query,
                  focusNode: _queryFocus,
                  placeholder: searchLabel,
                  semanticsLabel: searchLabel,
                  maxLines: 1,
                  compact: true,
                  onSubmitted: () => unawaited(_load(more: false)),
                ),
              ),
              const SizedBox(width: BistreSpacing.s8),
              EngravedButton(
                label: l10n.t(L10nKey.settingsAgentMcpRegistryFind),
                compact: true,
                onPressed: _loading
                    ? null
                    : () => unawaited(_load(more: false)),
              ),
            ],
          ),
          const SizedBox(height: BistreSpacing.s4),
          InkText(
            l10n.t(L10nKey.settingsAgentMcpRegistryHint),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
          const SizedBox(height: BistreSpacing.s8),
          for (final e in _entries) ...[
            _RegistryRow(
              entry: e,
              added: _isAdded(e.server),
              onAdd: () => unawaited(widget.controller.addMcpServer(e.server)),
            ),
            const SizedBox(height: BistreSpacing.s8),
          ],
          if (_failed || (!_loading && _entries.isEmpty))
            InkText(
              l10n.t(
                _failed
                    ? L10nKey.settingsAgentMcpRegistryFailed
                    : L10nKey.settingsAgentMcpRegistryEmpty,
              ),
              role: InkTextRole.captionMeta,
              color: _failed ? theme.statusWarn : theme.inkSecondary,
            ),
          if (_cursor != null && !_failed && _entries.isNotEmpty)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: EngravedButton(
                label: l10n.t(L10nKey.settingsAgentMcpRegistryMore),
                compact: true,
                onPressed: _loading ? null : () => unawaited(_load(more: true)),
              ),
            ),
        ],
      ),
    );
  }
}

class _RegistryRow extends StatelessWidget {
  const _RegistryRow({
    required this.entry,
    required this.added,
    required this.onAdd,
  });

  final EngineMcpRegistryEntry entry;
  final bool added;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final s = entry.server;
    // What will run or be reached, shown before it is added.
    final target = s.transport == 'http'
        ? s.url
        : <String>[s.command, ...s.args].join(' ');
    return FolioSurface(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkText(s.name, role: InkTextRole.labelStrong),
                if (entry.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  InkText(
                    entry.description,
                    role: InkTextRole.captionMeta,
                    color: theme.inkSecondary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                InkText(
                  l10n.isolate(target),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: BistreSpacing.s8),
          EngravedButton(
            label: l10n.t(
              added
                  ? L10nKey.settingsAgentMcpRegistryAdded
                  : L10nKey.settingsAgentMcpRegistryAdd,
            ),
            compact: true,
            onPressed: added ? null : onAdd,
          ),
        ],
      ),
    );
  }
}
