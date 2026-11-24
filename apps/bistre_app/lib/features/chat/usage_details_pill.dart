import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Interactive per-turn token & cost summary pill (Parchment v2.6.0 `UsageDetailsPill`,
/// `MessageTurnFooter.kt:482-552, 598-665`).
/// Shows the compact meta summary at rest, a hover hint on pointer rest, and opens a
/// focusable breakdown card on tap/Enter/Space with model, input/output tokens, and cost.
class UsageDetailsPill extends StatefulWidget {
  const UsageDetailsPill({
    super.key,
    required this.usage,
    required this.summaryText,
    this.reduceMotionOverride = false,
  });

  final NodeUsageMeta usage;
  final String summaryText;
  final bool reduceMotionOverride;

  @override
  State<UsageDetailsPill> createState() => _UsageDetailsPillState();
}

class _UsageDetailsPillState extends State<UsageDetailsPill> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final hint = l10n.t(L10nKey.chatUsageDetailsHint);

    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: HoverHint(
          message: hint,
          child: PressFeedback(
            pressScale: kRowPressScale,
            hoverScale: 1,
            child: Semantics(
              button: true,
              label: widget.summaryText,
              hint: hint,
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
                      _popover.toggle();
                      return null;
                    },
                  ),
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _popover.toggle,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _hovered || _popover.isShowing
                          ? theme.hoverTint
                          : null,
                      borderRadius: BorderRadius.circular(6),
                      border: _focused
                          ? Border.all(color: theme.accentBrass, width: 1.5)
                          : null,
                    ),
                    child: InkText(
                      widget.summaryText,
                      role: InkTextRole.captionMeta,
                      color: _hovered || _popover.isShowing
                          ? theme.accentBrass
                          : theme.inkMuted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final u = widget.usage;
    final costValue = u.costKnown
        ? FolioController.formatMicrosUsd(u.costMicros, showSubCent: true)
        : l10n.t(L10nKey.chatCostUnavailableTitle);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _popover.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.topStart.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          offset: const Offset(0, -6),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.05),
            reduceMotionOverride: widget.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 300),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
                borderRadius: 10,
                boxShadow: theme.floatingShadow,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkText(
                            u.modelId.isNotEmpty
                                ? u.modelId
                                : l10n.t(L10nKey.shellRoleAssistant),
                            role: InkTextRole.labelStrong,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        BistreIconButton(
                          icon: BistreUiIcon.close,
                          size: 11,
                          dimension: 22,
                          semanticsLabel: l10n.t(L10nKey.threadCancel),
                          onPressed: _popover.hide,
                        ),
                      ],
                    ),
                    if (u.providerName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      InkText(
                        u.providerName,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 6),
                    const FolioDivider(),
                    const SizedBox(height: 6),
                    if (u.hasTokens) ...[
                      _DetailRow(
                        label: l10n.t(L10nKey.chatUsageInputTokens),
                        value: '${u.inputTokens}',
                      ),
                      const SizedBox(height: 3),
                      _DetailRow(
                        label: l10n.t(L10nKey.chatUsageOutputTokens),
                        value: '${u.outputTokens}',
                      ),
                      const SizedBox(height: 3),
                    ],
                    _DetailRow(
                      label: l10n.t(L10nKey.chatUsageCostLabel),
                      value: costValue,
                      accent: u.costKnown && u.costMicros > 0,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: InkText(
            label,
            role: InkTextRole.captionMeta,
            color: theme.inkSecondary,
          ),
        ),
        InkText(
          value,
          role: InkTextRole.captionMeta,
          color: accent ? theme.accentBrass : theme.inkPrimary,
        ),
      ],
    );
  }
}
