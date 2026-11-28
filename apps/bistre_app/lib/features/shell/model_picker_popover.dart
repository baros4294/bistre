import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/popover_placement.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'folio_controller.dart';

class _ModelOption {
  const _ModelOption({
    required this.provider,
    required this.modelId,
    required this.vendorGroup,
  });

  final EngineProvider provider;
  final String modelId;
  final String vendorGroup;
}

/// Cross-provider searchable model picker popover:
/// - Search input at top (`Enter` selects top match, clear button resets query & filters).
/// - Provider filter chips when more than one provider has models.
/// - Vendor/family filter chips when at least two slash-prefixed families exist.
/// - Active model pinned first when unfiltered.
/// - Per-row badges only for exceptions: `On device`, `Stored`, and the provider's name when
///   its icon cannot show it.
class ModelPickerPopover extends StatefulWidget {
  const ModelPickerPopover({
    super.key,
    required this.controller,
    required this.link,
    required this.onDismiss,
    this.anchorKey,
  });

  final FolioController controller;
  final LayerLink link;

  /// The trigger, so the picker stays inside the window (never past its edge).
  final GlobalKey? anchorKey;
  final VoidCallback onDismiss;

  @override
  State<ModelPickerPopover> createState() => _ModelPickerPopoverState();
}

class _ModelPickerPopoverState extends State<ModelPickerPopover> {
  final TextEditingController _queryCtrl = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  String _providerFilter = '';
  String _vendorFilter = '';

  @override
  void dispose() {
    _queryCtrl.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  List<_ModelOption> _buildAllOptions(FolioController ctrl) {
    final out = <_ModelOption>[];
    for (final p in ctrl.providers) {
      final hidden = ctrl.hiddenModelIdsFor(p.id);
      final loaded = ctrl
          .modelsForProvider(p.id)
          .where((m) => !hidden.contains(m.id))
          .toList(growable: false);
      final ids = p.isReady && loaded.isNotEmpty
          ? loaded.map((m) => m.id).toList(growable: false)
          : p.defaultModel.trim().isNotEmpty
          ? <String>[p.defaultModel.trim()]
          : <String>[p.name];
      for (final id in ids) {
        final vendor = id.contains('/') ? id.split('/').first.trim() : '';
        out.add(_ModelOption(provider: p, modelId: id, vendorGroup: vendor));
      }
    }
    return out;
  }

  void _selectOption(_ModelOption opt) {
    widget.onDismiss();
    if (!opt.provider.isReady) {
      widget.controller.openSettings();
      return;
    }
    unawaited(
      widget.controller.setActiveProviderAndModel(
        opt.provider.id,
        opt.modelId,
        forOpenChat: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final ctrl = widget.controller;
    final activeProvId = ctrl.activeProvider?.id ?? '';
    final activeModelId = ctrl.activeModelId;
    final popoverW = PopoverPlacement.popoverWidthFor(context, 460);
    final anchor = widget.anchorKey?.currentContext;
    final shift = anchor == null
        ? 0.0
        : PopoverPlacement.popoverShiftFor(
            anchor,
            width: popoverW,
            alignStart: true,
          );

    final allOptions = _buildAllOptions(ctrl);
    final providerCounts = <(String, String, int)>[];
    final byProvider = <String, int>{};
    final providerNames = <String, String>{};
    for (final opt in allOptions) {
      byProvider[opt.provider.id] = (byProvider[opt.provider.id] ?? 0) + 1;
      providerNames[opt.provider.id] = opt.provider.name;
    }
    for (final entry in byProvider.entries) {
      providerCounts.add((entry.key, providerNames[entry.key]!, entry.value));
    }

    final scoped = _providerFilter.isEmpty
        ? allOptions
        : allOptions
              .where((o) => o.provider.id == _providerFilter)
              .toList(growable: false);
    final vendorMap = <String, int>{};
    for (final opt in scoped) {
      if (opt.vendorGroup.isNotEmpty) {
        vendorMap[opt.vendorGroup] = (vendorMap[opt.vendorGroup] ?? 0) + 1;
      }
    }
    final vendorCounts = vendorMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final tokens = _queryCtrl.text
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    final matched = <_ModelOption>[
      for (final opt in allOptions)
        if ((_providerFilter.isEmpty || opt.provider.id == _providerFilter) &&
            (_vendorFilter.isEmpty ||
                opt.vendorGroup.toLowerCase() == _vendorFilter.toLowerCase()) &&
            (tokens.isEmpty ||
                tokens.every(
                  (t) =>
                      opt.modelId.toLowerCase().contains(t) ||
                      opt.provider.name.toLowerCase().contains(t) ||
                      opt.vendorGroup.toLowerCase().contains(t),
                )))
          opt,
    ];
    final filtered = tokens.isEmpty
        ? <_ModelOption>[
            for (final o in matched)
              if (o.provider.id == activeProvId && o.modelId == activeModelId)
                o,
            for (final o in matched)
              if (!(o.provider.id == activeProvId &&
                  o.modelId == activeModelId))
                o,
          ]
        : matched;
    final hasActiveFilter =
        _queryCtrl.text.isNotEmpty ||
        _providerFilter.isNotEmpty ||
        _vendorFilter.isNotEmpty;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          followerAnchor: AlignmentDirectional.topStart.resolve(dir),
          offset: Offset(shift, 8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, -0.04),
            reduceMotionOverride: ctrl.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: popoverW),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FolioSurface(
                  tone: FolioTone.elevated,
                  boxShadow: theme.floatingShadow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Search input + clear button.
                      if (allOptions.length > 4 || hasActiveFilter) ...[
                        Row(
                          children: [
                            Expanded(
                              child: QuillInput(
                                controller: _queryCtrl,
                                focusNode: _queryFocus,
                                placeholder: l10n.t(L10nKey.chatModelSearch),
                                maxLines: 1,
                                compact: true,
                                submitOnEnter: false,
                                onSubmitted: () {
                                  if (filtered.isNotEmpty) {
                                    _selectOption(filtered.first);
                                  }
                                },
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                            if (hasActiveFilter) ...[
                              const SizedBox(width: 6),
                              BistreIconButton(
                                icon: BistreUiIcon.close,
                                size: 13,
                                dimension: 30,
                                semanticsLabel: l10n.t(
                                  L10nKey.settingsClearSearch,
                                ),
                                onPressed: () => setState(() {
                                  _queryCtrl.clear();
                                  _providerFilter = '';
                                  _vendorFilter = '';
                                }),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: BistreSpacing.s8),
                      ],
                      // Provider filter chips when >1 provider has models.
                      if (providerCounts.length > 1) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            InkChip(
                              label: l10n.t(L10nKey.chatModelAllProviders),
                              selected: _providerFilter.isEmpty,
                              onSelected: () => setState(() {
                                _providerFilter = '';
                                _vendorFilter = '';
                              }),
                            ),
                            for (final (id, name, _) in providerCounts)
                              InkChip(
                                label: name,
                                selected: _providerFilter == id,
                                onSelected: () => setState(() {
                                  _providerFilter = _providerFilter == id
                                      ? ''
                                      : id;
                                  _vendorFilter = '';
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: BistreSpacing.s8),
                      ],
                      // Model family filter chips when >=2 vendors exist.
                      if (vendorCounts.length >= 2) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            InkChip(
                              label: l10n.t(L10nKey.chatModelAllFamilies),
                              selected: _vendorFilter.isEmpty,
                              onSelected: () =>
                                  setState(() => _vendorFilter = ''),
                            ),
                            for (final entry in vendorCounts.take(8))
                              InkChip(
                                label: entry.key,
                                selected:
                                    _vendorFilter.toLowerCase() ==
                                    entry.key.toLowerCase(),
                                onSelected: () => setState(() {
                                  _vendorFilter =
                                      _vendorFilter.toLowerCase() ==
                                          entry.key.toLowerCase()
                                      ? ''
                                      : entry.key;
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: BistreSpacing.s8),
                      ],
                      // Bounded scrollable model list.
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                            vertical: BistreSpacing.s12,
                          ),
                          child: InkText(
                            _queryCtrl.text.trim().isEmpty
                                ? l10n.t(L10nKey.providerStatusNotConnected)
                                : l10n.t(
                                    L10nKey.chatModelNoMatches,
                                    <String, Object?>{
                                      'query': _queryCtrl.text.trim(),
                                    },
                                  ),
                            role: InkTextRole.bodyCompact,
                            color: theme.inkMuted,
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: SmoothScrollable(
                            builder: (_, scroll) => ListView.separated(
                              controller: scroll,
                              shrinkWrap: true,
                              padding: EdgeInsetsDirectional.zero,
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 4),
                              itemBuilder: (context, i) {
                                final opt = filtered[i];
                                final selected =
                                    opt.provider.id == activeProvId &&
                                    opt.modelId == activeModelId;
                                return _ModelOptionRow(
                                  option: opt,
                                  selected: selected,
                                  showProviderBadge: providerCounts.length > 1,
                                  onSelect: () => _selectOption(opt),
                                );
                              },
                            ),
                          ),
                        ),
                      const SizedBox(height: BistreSpacing.s8),
                      const FolioDivider(),
                      const SizedBox(height: BistreSpacing.s4),
                      _ManageProvidersRow(
                        label: l10n.t(L10nKey.settingsTabProviders),
                        onTap: () {
                          widget.onDismiss();
                          ctrl.openSettings();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ModelOptionRow extends StatefulWidget {
  const _ModelOptionRow({
    required this.option,
    required this.selected,
    required this.showProviderBadge,
    required this.onSelect,
  });

  final _ModelOption option;
  final bool selected;
  final bool showProviderBadge;
  final VoidCallback onSelect;

  @override
  State<_ModelOptionRow> createState() => _ModelOptionRowState();
}

class _ModelOptionRowState extends State<_ModelOptionRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final p = widget.option.provider;
    // Rows mark only the exceptions: a provider on this device, one that keeps replies,
    // and the provider's name when its icon cannot say it.
    final storesReplies = providerMayStoreReplies(p) && p.useServerStateCache;
    final iconNamesProvider =
        p.customIconPath.trim().isNotEmpty ||
        LabIconCatalog.resolve(
              iconSlug: p.iconSlug,
              dialect: p.dialect,
              providerName: p.name,
            ) !=
            null;
    final showProviderName = widget.showProviderBadge && !iconNamesProvider;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.showProviderBadge
          ? l10n.t(L10nKey.shellModelOnProvider, <String, Object?>{
              'model': l10n.isolate(widget.option.modelId),
              'provider': l10n.isolate(p.name),
            })
          : widget.option.modelId,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelect();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSelect,
            child: EaseDecoration(
              decoration: BoxDecoration(
                color: widget.selected || _hovered ? theme.hoverTint : null,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused || widget.selected
                      ? theme.accentBrass
                      : theme.borderHairline,
                  width: _focused ? 1.8 : 1,
                ),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                child: Row(
                  children: [
                    LabIcon(
                      iconSlug: p.iconSlug,
                      customIconPath: p.customIconPath,
                      dialect: p.dialect,
                      providerName: p.name,
                      modelId: widget.option.modelId,
                      size: 15,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkText(
                            widget.option.modelId,
                            role: InkTextRole.bodyCompact,
                            color: widget.selected
                                ? theme.accentBrass
                                : theme.inkPrimary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (showProviderName || p.isLocal || storesReplies)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(top: 3),
                              child: Wrap(
                                spacing: 5,
                                runSpacing: 4,
                                children: [
                                  if (showProviderName)
                                    _ModelBadge(
                                      label: p.name,
                                      color: theme.inkSecondary,
                                    ),
                                  if (p.isLocal)
                                    _ModelBadge(
                                      label: l10n.t(L10nKey.chatModelLocal),
                                      color: theme.statusOk,
                                    ),
                                  if (storesReplies)
                                    _ModelBadge(
                                      label: l10n.t(L10nKey.chatModelStored),
                                      color: theme.statusWarn,
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (widget.selected) ...[
                      const SizedBox(width: 6),
                      BistreIcon(
                        BistreUiIcon.check,
                        size: 13,
                        color: theme.accentBrass,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelBadge extends StatelessWidget {
  const _ModelBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.11),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 5,
          vertical: 1,
        ),
        child: InkText(
          label,
          role: InkTextRole.captionMeta,
          color: color,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _ManageProvidersRow extends StatefulWidget {
  const _ManageProvidersRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_ManageProvidersRow> createState() => _ManageProvidersRowState();
}

class _ManageProvidersRowState extends State<_ManageProvidersRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      label: widget.label,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: PressFeedback(
          pressScale: kRowPressScale,
          hoverScale: 1,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _hovered ? theme.hoverTint : null,
                borderRadius: BorderRadius.circular(8),
                border: _focused
                    ? Border.all(color: theme.accentBrass, width: 1.8)
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.settings,
                      size: 14,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        widget.label,
                        role: InkTextRole.labelStrong,
                        color: theme.accentBrass,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether a provider may keep replies on its servers (the picker's storage badge). Dialect
/// ids are core's (`google_gemini`, never `gemini`: the badge never showed for Gemini).
bool providerMayStoreReplies(EngineProvider p) =>
    !p.isLocal &&
    (p.dialect == 'openai' ||
        p.dialect == 'google_gemini' ||
        p.useServerStateCache);
