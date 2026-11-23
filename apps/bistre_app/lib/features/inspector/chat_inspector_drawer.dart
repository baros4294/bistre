import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/reasoning_block.dart';
import '../shell/folio_controller.dart';

/// Collapsible right-side `312px` Chat Parameters & Export Inspector.
/// Closed by default so the main reading canvas stays completely distraction-free.
class ChatInspectorDrawer extends StatefulWidget {
  const ChatInspectorDrawer({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ChatInspectorDrawer> createState() => _ChatInspectorDrawerState();
}

class _ChatInspectorDrawerState extends State<ChatInspectorDrawer> {
  final TextEditingController _promptCtrl = TextEditingController();
  final FocusNode _promptFocus = FocusNode();
  final TextEditingController _modelOverrideCtrl = TextEditingController();
  final FocusNode _modelOverrideFocus = FocusNode();
  String? _syncedThreadId;

  @override
  void initState() {
    super.initState();
    _syncFromThread();
    widget.controller.addListener(_syncFromThread);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromThread);
    _promptCtrl.dispose();
    _promptFocus.dispose();
    _modelOverrideCtrl.dispose();
    _modelOverrideFocus.dispose();
    super.dispose();
  }

  void _syncFromThread() {
    final t = widget.controller.activeThread;
    if (t == null || t.id == _syncedThreadId) return;
    _syncedThreadId = t.id;
    _promptCtrl.text = t.systemPromptOverride ?? '';
    _modelOverrideCtrl.text = t.modelIdOverride ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final thread = ctrl.activeThread;

    final tempMilli = thread?.temperatureMilli;
    final maxTok = thread?.maxOutputTokens;
    final topPMilli = thread?.topPMilli;

    // Sum tokens across active visible branch.
    var totalIn = 0;
    var totalOut = 0;
    var totalMicros = 0;
    for (final n in ctrl.visibleBranchNodes) {
      final meta = n.usageMeta;
      if (meta != null) {
        totalIn += meta.inputTokens;
        totalOut += meta.outputTokens;
        totalMicros += meta.costMicros;
      }
    }

    return FolioFadeSlide(
      beginOffset: const Offset(0.04, 0),
      reduceMotionOverride: ctrl.reduceMotionOverride,
      child: SizedBox(
        width: BistreSpacing.inspectorWidth,
        child: ColoredBox(
          color: theme.bgSurface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 10, 10, 10),
                child: Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.sliders,
                      size: 15,
                      color: theme.accentBrass,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: InkText(
                        l10n.t(L10nKey.chatInspectorTitle),
                        role: InkTextRole.labelStrong,
                        color: theme.inkPrimary,
                      ),
                    ),
                    BistreIconButton(
                      icon: BistreUiIcon.close,
                      size: 14,
                      dimension: 28,
                      semanticsLabel: l10n.t(L10nKey.settingsClose),
                      onPressed: ctrl.toggleInspector,
                    ),
                  ],
                ),
              ),
              const FolioDivider(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsetsDirectional.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Provider override
                      InkText(
                        l10n.t(L10nKey.settingsAssistantsDefaultProvider),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 6),
                      _ProviderOverrideList(
                        providers: ctrl.providers,
                        selectedId: thread?.providerIdOverride,
                        defaultLabel: l10n.t(
                          L10nKey.settingsAssistantsUseGlobalDefault,
                        ),
                        onSelect: (pid) {
                          if (pid == null) {
                            unawaited(
                              ctrl.updateActiveThreadOverrides(
                                clearProviderOverride: true,
                              ),
                            );
                          } else {
                            unawaited(
                              ctrl.updateActiveThreadOverrides(
                                providerIdOverride: pid,
                              ),
                            );
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      // Model override
                      InkText(
                        l10n.t(L10nKey.providerFieldModel),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 6),
                      QuillInput(
                        controller: _modelOverrideCtrl,
                        focusNode: _modelOverrideFocus,
                        placeholder: ctrl.activeModelId.isNotEmpty
                            ? ctrl.activeModelId
                            : l10n.t(L10nKey.providerFieldModelPlaceholder),
                        maxLines: 1,
                        compact: true,
                        onSubmitted: () {
                          final v = _modelOverrideCtrl.text.trim();
                          unawaited(
                            ctrl.updateActiveThreadOverrides(
                              modelIdOverride: v.isEmpty ? null : v,
                              clearModelOverride: v.isEmpty,
                            ),
                          );
                        },
                        onChanged: (v) {
                          final trimmed = v.trim();
                          unawaited(
                            ctrl.updateActiveThreadOverrides(
                              modelIdOverride: trimmed.isEmpty ? null : trimmed,
                              clearModelOverride: trimmed.isEmpty,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),

                      // System prompt override
                      InkText(
                        l10n.t(L10nKey.chatInspectorOverridePrompt),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 6),
                      QuillInput(
                        controller: _promptCtrl,
                        focusNode: _promptFocus,
                        placeholder: l10n.t(
                          L10nKey.chatInspectorOverridePromptHint,
                        ),
                        minLines: 3,
                        submitOnEnter: false,
                        onSubmitted: () {},
                        onChanged: (v) {
                          final trimmed = v.trim();
                          unawaited(
                            ctrl.updateActiveThreadOverrides(
                              systemPromptOverride: trimmed.isEmpty
                                  ? null
                                  : trimmed,
                              clearSystemPromptOverride: trimmed.isEmpty,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 18),

                      // Temperature slider
                      Row(
                        children: [
                          Expanded(
                            child: InkText(
                              l10n.t(L10nKey.settingsAssistantsTemperature),
                              role: InkTextRole.captionMeta,
                              color: theme.inkSecondary,
                            ),
                          ),
                          InkText(
                            tempMilli != null
                                ? (tempMilli / 1000.0).toStringAsFixed(2)
                                : l10n.t(
                                    L10nKey.settingsAssistantsParamsDefault,
                                  ),
                            role: InkTextRole.captionMeta,
                            color: theme.accentBrass,
                          ),
                        ],
                      ),
                      BistreSlider(
                        value: (tempMilli ?? 700) / 1000.0,
                        min: 0.0,
                        max: 2.0,
                        step: 0.05,
                        semanticsLabel: l10n.t(
                          L10nKey.settingsAssistantsTemperature,
                        ),
                        onChanged: (v) => unawaited(
                          ctrl.updateActiveThreadOverrides(
                            temperatureMilli: (v * 1000).round(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Max output tokens slider
                      Row(
                        children: [
                          Expanded(
                            child: InkText(
                              l10n.t(L10nKey.settingsAssistantsMaxTokens),
                              role: InkTextRole.captionMeta,
                              color: theme.inkSecondary,
                            ),
                          ),
                          InkText(
                            maxTok != null
                                ? maxTok.toString()
                                : l10n.t(
                                    L10nKey.settingsAssistantsParamsDefault,
                                  ),
                            role: InkTextRole.captionMeta,
                            color: theme.accentBrass,
                          ),
                        ],
                      ),
                      BistreSlider(
                        value: (maxTok ?? 4096).toDouble().clamp(256, 32768),
                        min: 256,
                        max: 32768,
                        step: 256,
                        semanticsLabel: l10n.t(
                          L10nKey.settingsAssistantsMaxTokens,
                        ),
                        onChanged: (v) => unawaited(
                          ctrl.updateActiveThreadOverrides(
                            maxOutputTokens: v.round(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Top-P slider
                      Row(
                        children: [
                          Expanded(
                            child: InkText(
                              l10n.t(L10nKey.settingsAssistantsTopP),
                              role: InkTextRole.captionMeta,
                              color: theme.inkSecondary,
                            ),
                          ),
                          InkText(
                            topPMilli != null
                                ? (topPMilli / 1000.0).toStringAsFixed(2)
                                : l10n.t(
                                    L10nKey.settingsAssistantsParamsDefault,
                                  ),
                            role: InkTextRole.captionMeta,
                            color: theme.accentBrass,
                          ),
                        ],
                      ),
                      BistreSlider(
                        value: (topPMilli ?? 1000) / 1000.0,
                        min: 0.1,
                        max: 1.0,
                        step: 0.05,
                        semanticsLabel: l10n.t(L10nKey.settingsAssistantsTopP),
                        onChanged: (v) => unawaited(
                          ctrl.updateActiveThreadOverrides(
                            topPMilli: (v * 1000).round(),
                          ),
                        ),
                      ),

                      if (thread?.hasAnyOverride == true) ...[
                        const SizedBox(height: 10),
                        EngravedButton(
                          label: l10n.t(L10nKey.chatInspectorResetParams),
                          compact: true,
                          onPressed: () {
                            _promptCtrl.clear();
                            _modelOverrideCtrl.clear();
                            unawaited(ctrl.resetActiveThreadOverrides());
                          },
                        ),
                      ],

                      const SizedBox(height: 18),
                      const FolioDivider(),
                      const SizedBox(height: 14),

                      // Reasoning effort & reversible context compaction
                      InkText(
                        l10n.t(L10nKey.chatReasoningEffort),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 8),
                      ReasoningEffortSelector(
                        value: ctrl.settings.reasoningEffort,
                        onChanged: (effort) =>
                            unawaited(ctrl.setReasoningEffort(effort)),
                      ),
                      const SizedBox(height: 12),
                      EngravedButton(
                        label: l10n.t(L10nKey.chatCompactAction),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.document,
                          size: 13,
                          color: theme.inkSecondary,
                        ),
                        onPressed:
                            !ctrl.isStreaming &&
                                ctrl.visibleBranchNodes.length > 4
                            ? () => unawaited(ctrl.compactActiveThread())
                            : null,
                      ),

                      const SizedBox(height: 20),
                      const FolioDivider(),
                      const SizedBox(height: 16),

                      // Export section
                      InkText(
                        l10n.t(L10nKey.chatInspectorExportSection),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: EngravedButton(
                              label: l10n.t(L10nKey.chatInspectorExportMd),
                              compact: true,
                              leading: const BistreIcon(
                                BistreUiIcon.exportIcon,
                                size: 13,
                              ),
                              onPressed: () => unawaited(
                                ctrl.exportActiveThreadToFileOrClipboard(
                                  'markdown',
                                  saveTitle: l10n.t(
                                    L10nKey.chatInspectorExportMd,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: EngravedButton(
                              label: l10n.t(L10nKey.chatInspectorExportJson),
                              compact: true,
                              leading: const BistreIcon(
                                BistreUiIcon.code,
                                size: 13,
                              ),
                              onPressed: () => unawaited(
                                ctrl.exportActiveThreadToFileOrClipboard(
                                  'json',
                                  saveTitle: l10n.t(
                                    L10nKey.chatInspectorExportJson,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      if (totalIn > 0 || totalOut > 0) ...[
                        const SizedBox(height: 18),
                        FolioSurface(
                          tone: FolioTone.canvas,
                          padding: const EdgeInsetsDirectional.all(10),
                          borderRadius: 9,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InkText(
                                l10n.t(
                                  L10nKey.chatTokensMeta,
                                  <String, Object?>{
                                    'input': totalIn,
                                    'output': totalOut,
                                  },
                                ),
                                role: InkTextRole.captionMeta,
                                color: theme.inkSecondary,
                              ),
                              if (totalMicros > 0) ...[
                                const SizedBox(height: 2),
                                InkText(
                                  FolioController.formatMicrosUsd(
                                    totalMicros,
                                    showSubCent: true,
                                  ),
                                  role: InkTextRole.labelStrong,
                                  color: theme.accentBrass,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderOverrideList extends StatelessWidget {
  const _ProviderOverrideList({
    required this.providers,
    required this.selectedId,
    required this.defaultLabel,
    required this.onSelect,
  });

  final List<EngineProvider> providers;
  final String? selectedId;
  final String defaultLabel;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return FolioSurface(
      tone: FolioTone.elevated,
      padding: const EdgeInsetsDirectional.all(4),
      borderRadius: 10,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _OverrideTile(
            label: defaultLabel,
            selected: selectedId == null,
            leading: BistreIcon(
              BistreUiIcon.assistant,
              size: 14,
              color: selectedId == null ? theme.accentBrass : theme.inkMuted,
            ),
            onTap: () => onSelect(null),
          ),
          for (final p in providers)
            _OverrideTile(
              label: p.name,
              selected: selectedId == p.id,
              leading: LabIcon(
                iconSlug: p.iconSlug,
                customIconPath: p.customIconPath,
                dialect: p.dialect,
                providerName: p.name,
                size: 14,
              ),
              onTap: () => onSelect(p.id),
            ),
        ],
      ),
    );
  }
}

class _OverrideTile extends StatefulWidget {
  const _OverrideTile({
    required this.label,
    required this.selected,
    required this.leading,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Widget leading;
  final VoidCallback onTap;

  @override
  State<_OverrideTile> createState() => _OverrideTileState();
}

class _OverrideTileState extends State<_OverrideTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: widget.selected
                ? theme.bgSurface
                : (_hovered ? theme.hoverTint : null),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 8,
              vertical: 6,
            ),
            child: Row(
              children: [
                widget.leading,
                const SizedBox(width: 8),
                Expanded(
                  child: InkText(
                    widget.label,
                    role: widget.selected
                        ? InkTextRole.labelStrong
                        : InkTextRole.captionMeta,
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
    );
  }
}
