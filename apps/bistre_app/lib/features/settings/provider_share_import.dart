import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// "Add from a share code" in Add provider: paste a code copied on another device; core reads
/// it and adds a new provider. A code core rejects says so under the field.
class ProviderShareImportCard extends StatefulWidget {
  const ProviderShareImportCard({
    super.key,
    required this.controller,
    required this.onImported,
  });

  final FolioController controller;
  final ValueChanged<EngineProvider> onImported;

  @override
  State<ProviderShareImportCard> createState() =>
      _ProviderShareImportCardState();
}

class _ProviderShareImportCardState extends State<ProviderShareImportCard> {
  final TextEditingController _code = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _failed = false;

  @override
  void dispose() {
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    if (_code.text.trim().isEmpty) return;
    final created = await widget.controller.importProviderShareCode(_code.text);
    if (!mounted) return;
    if (created == null) {
      setState(() => _failed = true);
      return;
    }
    _code.clear();
    setState(() => _failed = false);
    widget.onImported(created);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return BistreSettingsSection(
      title: l10n.t(L10nKey.providerImportTitle),
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: QuillInput(
                      controller: _code,
                      focusNode: _focus,
                      placeholder: l10n.t(L10nKey.providerImportPlaceholder),
                      semanticsLabel: l10n.t(L10nKey.providerImportTitle),
                      maxLines: 1,
                      onChanged: (_) {
                        if (_failed) setState(() => _failed = false);
                      },
                      onSubmitted: () => unawaited(_import()),
                    ),
                  ),
                  const SizedBox(width: 10),
                  EngravedButton(
                    label: l10n.t(L10nKey.providerImportAction),
                    onPressed: () => unawaited(_import()),
                  ),
                ],
              ),
              if (_failed) ...[
                const SizedBox(height: 6),
                InkText(
                  l10n.t(L10nKey.providerImportInvalid),
                  role: InkTextRole.captionMeta,
                  color: theme.statusErr,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
