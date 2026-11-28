import 'dart:async';

import 'package:flutter/services.dart';
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

/// The model field: one combobox. Focusing or clicking it opens the provider's models
/// under it (fetched once if none are loaded); typing filters them; arrow keys move the
/// highlight; Enter picks the highlighted model, or keeps the typed id when nothing matches;
/// Esc or a click elsewhere closes the list. Shared by Default models, Assistants, and the
/// chat parameters drawer.
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
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  final Object _tapGroup = Object();
  int _highlight = 0;

  /// The text when the list opened: an unchanged field lists every model.
  String _openedWith = '';

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(ModelPickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChanged);
      widget.focusNode.addListener(_onFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChanged);
    super.dispose();
  }

  String _effectiveProviderId() {
    if (widget.providerId.trim().isNotEmpty) return widget.providerId.trim();
    return widget.controller.activeProvider?.id ??
        (widget.controller.providers.isNotEmpty
            ? widget.controller.providers.first.id
            : '');
  }

  void _onFocusChanged() {
    if (widget.focusNode.hasFocus) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    if (_portal.isShowing) return;
    final ctrl = widget.controller;
    final pid = _effectiveProviderId();
    if (pid.isNotEmpty &&
        ctrl.modelsForProvider(pid).isEmpty &&
        ctrl.loadingModelsProviderId != pid) {
      unawaited(ctrl.fetchModelsForProvider(pid));
    }
    _openedWith = widget.textController.text;
    setState(() => _highlight = 0);
    _portal.show();
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  List<EngineProviderModel> _matches() {
    final ctrl = widget.controller;
    final pid = _effectiveProviderId();
    final typed = widget.textController.text.trim().toLowerCase();
    final query = widget.textController.text == _openedWith ? '' : typed;
    return modelPickerMatches(
      ctrl.modelsForProvider(pid),
      ctrl.hiddenModelIdsFor(pid),
      query,
    );
  }

  void _commit(String id) {
    final clean = id.trim();
    if (!widget.textController.value.composing.isValid &&
        widget.textController.text != clean) {
      widget.textController.value = TextEditingValue(
        text: clean,
        selection: TextSelection.collapsed(offset: clean.length),
      );
    }
    _openedWith = clean;
    _close();
    if (clean.isNotEmpty) widget.onSelectedModel(clean);
  }

  void _submit() {
    final matches = _matches();
    if (_portal.isShowing &&
        matches.isNotEmpty &&
        widget.textController.text != _openedWith) {
      _commit(matches[_highlight.clamp(0, matches.length - 1)].id);
    } else {
      _commit(widget.textController.text);
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (widget.textController.value.composing.isValid) {
      return KeyEventResult.ignored;
    }
    final count = _matches().length;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        if (!_portal.isShowing) {
          _open();
        } else if (count > 0) {
          setState(() => _highlight = (_highlight + 1) % count);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (_portal.isShowing && count > 0) {
          setState(() => _highlight = (_highlight - 1 + count) % count);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (!_portal.isShowing) return KeyEventResult.ignored;
        _close();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: _buildList,
      child: CompositedTransformTarget(
        link: _link,
        child: TapRegion(
          groupId: _tapGroup,
          onTapOutside: (_) => widget.focusNode.unfocus(),
          child: Focus(
            onKeyEvent: _onKey,
            child: QuillInput(
              controller: widget.textController,
              focusNode: widget.focusNode,
              placeholder: widget.placeholder,
              maxLines: 1,
              onSubmitted: _submit,
              onChanged: (_) {
                if (!_portal.isShowing) _open();
                setState(() => _highlight = 0);
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final pid = _effectiveProviderId();
    final box = this.context.findRenderObject();
    final width = box is RenderBox && box.hasSize ? box.size.width : 320.0;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[ctrl, widget.textController]),
      builder: (context, _) {
        final matches = _matches();
        final loading = ctrl.loadingModelsProviderId == pid;
        final current = widget.textController.text.trim();
        return CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.bottomStart.resolve(
            Directionality.of(context),
          ),
          followerAnchor: AlignmentDirectional.topStart.resolve(
            Directionality.of(context),
          ),
          offset: const Offset(0, 4),
          child: Align(
            alignment: AlignmentDirectional.topStart,
            child: TapRegion(
              groupId: _tapGroup,
              child: SizedBox(
                width: width,
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  borderRadius: 10,
                  boxShadow: theme.floatingShadow,
                  padding: const EdgeInsetsDirectional.all(8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkText(
                              loading
                                  ? l10n.t(L10nKey.providerActionLoadingModels)
                                  : l10n.t(L10nKey.providerFieldModel),
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                            ),
                          ),
                          EngravedButton(
                            label: l10n.t(L10nKey.providerActionLoadModels),
                            compact: true,
                            onPressed: (loading || pid.isEmpty)
                                ? null
                                : () => unawaited(
                                    ctrl.fetchModelsForProvider(pid),
                                  ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (matches.isEmpty)
                        Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                            vertical: 6,
                            horizontal: 8,
                          ),
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
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: SmoothScrollable(
                            builder: (_, scroll) => ListView.builder(
                              controller: scroll,
                              shrinkWrap: true,
                              itemCount: matches.length,
                              itemBuilder: (_, i) => _PickerModelItem(
                                model: matches[i],
                                selected: current == matches[i].id,
                                highlighted: i == _highlight,
                                onTap: () => _commit(matches[i].id),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PickerModelItem extends StatefulWidget {
  const _PickerModelItem({
    required this.model,
    required this.selected,
    required this.highlighted,
    required this.onTap,
  });

  final EngineProviderModel model;
  final bool selected;
  final bool highlighted;
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
              color: widget.selected || widget.highlighted || _hovered
                  ? theme.hoverTint
                  : null,
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

/// The models the picker lists: every visible model, or those matching [query] by id
/// or name. No cap: the list is built lazily, so a provider with hundreds of models shows
/// them all.
List<EngineProviderModel> modelPickerMatches(
  List<EngineProviderModel> models,
  Set<String> hidden,
  String query,
) {
  final q = query.trim().toLowerCase();
  return <EngineProviderModel>[
    for (final m in models)
      if (!hidden.contains(m.id) &&
          (q.isEmpty ||
              m.id.toLowerCase().contains(q) ||
              m.displayName.toLowerCase().contains(q)))
        m,
  ];
}
