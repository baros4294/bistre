import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// An HTTP MCP server's token: whether one is saved, and a field to add, change, or remove
/// it. The token goes to the vault and is never shown again.
class McpTokenRow extends StatefulWidget {
  const McpTokenRow({
    super.key,
    required this.controller,
    required this.serverId,
  });

  final FolioController controller;
  final String serverId;

  @override
  State<McpTokenRow> createState() => _McpTokenRowState();
}

class _McpTokenRowState extends State<McpTokenRow> {
  final TextEditingController _field = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _saved = false;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final saved = await widget.controller.hasMcpToken(widget.serverId);
    if (mounted) setState(() => _saved = saved);
  }

  Future<void> _save(String token) async {
    final ok = await widget.controller.setMcpToken(widget.serverId, token);
    if (!mounted || !ok) return;
    _field.clear();
    setState(() {
      _saved = token.trim().isNotEmpty;
      _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    if (!_editing) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_saved)
            InkText(
              l10n.t(L10nKey.settingsAgentMcpTokenSaved),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
          EngravedButton(
            label: l10n.t(
              _saved
                  ? L10nKey.settingsAgentMcpTokenChange
                  : L10nKey.settingsAgentMcpTokenAdd,
            ),
            compact: true,
            onPressed: () {
              setState(() => _editing = true);
              _focus.requestFocus();
            },
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkText(
          l10n.t(L10nKey.settingsAgentMcpToken),
          role: InkTextRole.labelStrong,
        ),
        const SizedBox(height: 2),
        InkText(
          l10n.t(L10nKey.settingsAgentMcpTokenHint),
          role: InkTextRole.captionMeta,
          color: theme.inkMuted,
        ),
        const SizedBox(height: 6),
        QuillInput(
          controller: _field,
          focusNode: _focus,
          placeholder: l10n.t(L10nKey.settingsAgentMcpTokenPlaceholder),
          maxLines: 1,
          obscureText: true,
          onSubmitted: () => unawaited(_save(_field.text)),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            EngravedButton(
              label: l10n.t(L10nKey.threadSave),
              primary: true,
              compact: true,
              onPressed: () => unawaited(_save(_field.text)),
            ),
            if (_saved)
              EngravedButton(
                label: l10n.t(L10nKey.shellRemove),
                compact: true,
                onPressed: () => unawaited(_save('')),
              ),
            EngravedButton(
              label: l10n.t(L10nKey.threadCancel),
              compact: true,
              onPressed: () {
                _field.clear();
                setState(() => _editing = false);
              },
            ),
          ],
        ),
      ],
    );
  }
}
