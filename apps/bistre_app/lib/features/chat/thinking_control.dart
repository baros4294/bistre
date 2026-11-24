import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Thinking effort stops, in slider order. The stored value is the setting key core parses
/// (`ReasoningEffort::parse`); `default` lets the model decide and sends nothing.
const List<(String, L10nKey)> kThinkingStops = <(String, L10nKey)>[
  ('default', L10nKey.chatEffortAuto),
  ('off', L10nKey.chatEffortOff),
  ('low', L10nKey.chatEffortLow),
  ('medium', L10nKey.chatEffortMedium),
  ('high', L10nKey.chatEffortHigh),
  ('xhigh', L10nKey.chatEffortExtra),
  ('max', L10nKey.chatEffortMax),
];

/// Index of [value] in [kThinkingStops] (unknown values read as Auto).
int thinkingStopIndex(String value) {
  final i = kThinkingStops.indexWhere((s) => s.$1 == value);
  return i < 0 ? 0 : i;
}

/// Composer chip `Thinking: Medium` that opens a step slider above itself: Auto, Off, Low,
/// Medium, High, Extra, Max, plus a custom effort input. Usable by mouse, touch, keyboard
/// (arrows), and screen reader; the popover closes on an outside tap or Escape.
class ThinkingControl extends StatefulWidget {
  const ThinkingControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.reduceMotionOverride = false,
    this.compact = false,
  });

  /// Narrow windows and large text show only the icon and the level (`Auto`); screen readers
  /// and the hover hint still get the full `Thinking: Auto`.
  final bool compact;
  final String value;
  final ValueChanged<String> onChanged;
  final bool reduceMotionOverride;

  @override
  State<ThinkingControl> createState() => _ThinkingControlState();
}

class _ThinkingControlState extends State<ThinkingControl> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();
  final TextEditingController _customCtrl = TextEditingController();
  final FocusNode _customFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _customCtrl.text = widget.value == 'default' ? '' : widget.value;
  }

  @override
  void didUpdateWidget(ThinkingControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_customFocus.hasFocus) {
      _customCtrl.text = widget.value == 'default' ? '' : widget.value;
    }
  }

  @override
  void dispose() {
    _customCtrl.dispose();
    _customFocus.dispose();
    super.dispose();
  }

  void _commitCustom() {
    final clean = _customCtrl.text.trim().toLowerCase();
    widget.onChanged(clean.isEmpty ? 'default' : clean);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final level = l10n.t(kThinkingStops[thinkingStopIndex(widget.value)].$2);
    final full = l10n.t(L10nKey.chatThinkingChip, <String, Object?>{
      'level': level,
    });
    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: _chip(theme, l10n, level, full),
      ),
    );
  }

  Widget _chip(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    String level,
    String full,
  ) => HoverHint(
    message: l10n.t(L10nKey.chatThinkingHint),
    child: EngravedButton(
      label: widget.compact ? level : full,
      semanticsLabel: widget.compact ? full : null,
      compact: true,
      leading: BistreIcon(
        BistreUiIcon.think,
        size: 13,
        color: theme.inkSecondary,
      ),
      onPressed: _popover.toggle,
    ),
  );
  Widget _buildPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final index = thinkingStopIndex(widget.value);
    final last = kThinkingStops.length - 1;
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
          offset: const Offset(0, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            reduceMotionOverride: widget.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 280, maxWidth: 320),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
                borderRadius: 12,
                boxShadow: theme.floatingShadow,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkText(
                            l10n.t(L10nKey.chatReasoningEffort),
                            role: InkTextRole.labelStrong,
                          ),
                        ),
                        InkText(
                          l10n.t(kThinkingStops[index].$2),
                          role: InkTextRole.captionMeta,
                          color: theme.accentBrass,
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    BistreSlider(
                      value: index.toDouble(),
                      min: 0,
                      max: last.toDouble(),
                      reduceMotionOverride: widget.reduceMotionOverride,
                      semanticsLabel: l10n.t(L10nKey.chatReasoningEffort),
                      onChanged: (v) {
                        final i = v.round().clamp(0, last);
                        if (i != index) widget.onChanged(kThinkingStops[i].$1);
                      },
                    ),
                    Row(
                      children: [
                        InkText(
                          l10n.t(L10nKey.chatThinkingFaster),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                        const Spacer(),
                        InkText(
                          l10n.t(L10nKey.chatThinkingThorough),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        InkChip(
                          label: l10n.t(L10nKey.chatEffortAdaptive),
                          selected: widget.value == 'adaptive',
                          onSelected: () => widget.onChanged('adaptive'),
                        ),
                        InkChip(
                          label: l10n.t(L10nKey.chatEffortAuto),
                          selected:
                              widget.value == 'default' ||
                              widget.value == 'auto',
                          onSelected: () => widget.onChanged('default'),
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.t(L10nKey.chatThinkingHint),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    const FolioDivider(),
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.t(L10nKey.chatThinkingCustomLabel),
                      role: InkTextRole.captionMeta,
                      color: theme.inkSecondary,
                    ),
                    const SizedBox(height: BistreSpacing.s4),
                    QuillInput(
                      controller: _customCtrl,
                      focusNode: _customFocus,
                      placeholder: l10n.t(
                        L10nKey.chatThinkingCustomPlaceholder,
                      ),
                      maxLines: 1,
                      compact: true,
                      onSubmitted: _commitCustom,
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
