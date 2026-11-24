import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Searchable model picker field combining direct typing with a browsable dropdown of
/// fetched models for [providerId] (reused across Default Models and Assistants settings).
class ModelPickerField extends StatefulWidget {
  const ModelPickerField({
    super.key,
    required this.controller,
    required this.providerId,
    required this.textController,
    required this.focusNode,
    required this.placeholder,
    required this.onSelectedModel,
  });

  final FolioController controller;
  final String providerId;
  final TextEditingController textController;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String> onSelectedModel;

  @override
  State<ModelPickerField> createState() => _ModelPickerFieldState();
}

class _ModelPickerFieldState extends State<ModelPickerField> {
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  bool _open = false;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  String _effectiveProviderId() {
    if (widget.providerId.trim().isNotEmpty) return widget.providerId.trim();
    return widget.controller.activeProvider?.id ??
        (widget.controller.providers.isNotEmpty
            ? widget.controller.providers.first.id
            : '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final pid = _effectiveProviderId();
    final hidden = ctrl.hiddenModelIdsFor(pid);
    final allModels = ctrl
        .modelsForProvider(pid)
        .where((m) => !hidden.contains(m.id))
        .toList(growable: false);
    final loading = ctrl.loadingModelsProviderId == pid;
    final filtered = _query.isEmpty
        ? allModels
        : allModels
              .where(
                (m) =>
                    m.id.toLowerCase().contains(_query) ||
                    m.displayName.toLowerCase().contains(_query),
              )
              .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: QuillInput(
                controller: widget.textController,
                focusNode: widget.focusNode,
                placeholder: widget.placeholder,
                maxLines: 1,
                submitOnEnter: false,
                onSubmitted: () =>
                    widget.onSelectedModel(widget.textController.text.trim()),
              ),
            ),
            const SizedBox(width: 6),
            EngravedButton(
              label: l10n.t(L10nKey.settingsModelPickAction),
              compact: true,
              leading: BistreIcon(
                _open ? BistreUiIcon.chevronUp : BistreUiIcon.chevronDown,
                size: 12,
                color: theme.inkSecondary,
              ),
              onPressed: () {
                final next = !_open;
                setState(() => _open = next);
                if (next && allModels.isEmpty && pid.isNotEmpty && !loading) {
                  unawaited(ctrl.fetchModelsForProvider(pid));
                }
              },
            ),
          ],
        ),
        if (_open) ...[
          const SizedBox(height: 8),
          FolioSurface(
            borderRadius: 10,
            padding: const EdgeInsetsDirectional.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: QuillInput(
                        controller: _searchCtrl,
                        focusNode: _searchFocus,
                        placeholder: l10n.t(
                          L10nKey.settingsProviderFilterModels,
                        ),
                        maxLines: 1,
                        compact: true,
                        submitOnEnter: false,
                        onSubmitted: () {},
                        onChanged: (q) =>
                            setState(() => _query = q.trim().toLowerCase()),
                      ),
                    ),
                    const SizedBox(width: 6),
                    EngravedButton(
                      label: loading
                          ? l10n.t(L10nKey.providerActionLoadingModels)
                          : l10n.t(L10nKey.providerActionLoadModels),
                      compact: true,
                      onPressed: (loading || pid.isEmpty)
                          ? null
                          : () => unawaited(ctrl.fetchModelsForProvider(pid)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsetsDirectional.symmetric(vertical: 8),
                    child: InkText(
                      loading
                          ? l10n.t(L10nKey.providerActionLoadingModels)
                          : l10n.t(L10nKey.settingsModelNoLoaded),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 168),
                    child: SmoothScrollable(
                      builder: (_, scroll) => SingleChildScrollView(
                        controller: scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final m in filtered.take(60))
                              _PickerModelItem(
                                model: m,
                                selected:
                                    widget.textController.text.trim() == m.id,
                                onTap: () {
                                  widget.textController.text = m.id;
                                  widget.onSelectedModel(m.id);
                                  setState(() => _open = false);
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _PickerModelItem extends StatefulWidget {
  const _PickerModelItem({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final EngineProviderModel model;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_PickerModelItem> createState() => _PickerModelItemState();
}

class _PickerModelItemState extends State<_PickerModelItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressFeedback(
        pressScale: kRowPressScale,
        hoverScale: 1,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.selected || _hovered ? theme.hoverTint : null,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.symmetric(
                horizontal: 8,
                vertical: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkText(
                      widget.model.id,
                      role: InkTextRole.captionMeta,
                      color: widget.selected
                          ? theme.inkPrimary
                          : theme.inkSecondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.selected)
                    BistreIcon(
                      BistreUiIcon.check,
                      size: 13,
                      color: theme.accentBrass,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
