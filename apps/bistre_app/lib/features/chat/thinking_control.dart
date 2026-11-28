import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/popover_placement.dart';
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

/// The words for [value]: a level, Adaptive, or Auto (anything else).
L10nKey thinkingLabelKey(String value) => value == 'adaptive'
    ? L10nKey.chatEffortAdaptive
    : kThinkingStops[thinkingStopIndex(value)].$2;

/// Whether [value] is a level on the slider (Off to Max), not Auto or Adaptive, which show
/// on their own chip; only a level is repeated beside a heading.
bool isThinkingLevel(String value) =>
    value != 'adaptive' && thinkingLabelKey(value) != L10nKey.chatEffortAuto;

/// The one Thinking control (composer, chat inspector, provider settings): Auto and
/// Adaptive as choices, then a slider over the fixed levels, Off to Max. While Auto or
/// Adaptive is chosen the slider has no fill and a hollow thumb, so it shows no level.
class ThinkingEffortPicker extends StatelessWidget {
  const ThinkingEffortPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.reduceMotionOverride = false,
    this.allowedLevels = const <String>[],
  });

  final String value;
  final ValueChanged<String> onChanged;
  final bool reduceMotionOverride;

  /// The levels the model accepts (catalog keys, `off` to `max`); empty offers every level.
  final List<String> allowedLevels;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final levels = kThinkingStops
        .sublist(1)
        .where((s) => allowedLevels.isEmpty || allowedLevels.contains(s.$1))
        .toList();
    final at = levels.indexWhere((s) => s.$1 == value);
    final isAuto = value != 'adaptive' && at < 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            InkChip(
              label: l10n.t(L10nKey.chatEffortAuto),
              selected: isAuto,
              onSelected: () => onChanged('default'),
            ),
            InkChip(
              label: l10n.t(L10nKey.chatEffortAdaptive),
              selected: value == 'adaptive',
              onSelected: () => onChanged('adaptive'),
            ),
            // One level is a choice, not a range.
            if (levels.length == 1)
              InkChip(
                label: l10n.t(levels.single.$2),
                selected: at == 0,
                onSelected: () => onChanged(levels.single.$1),
              ),
          ],
        ),
        if (levels.length > 1) ...[
          const SizedBox(height: BistreSpacing.s8),
          BistreSlider(
            // Unset, the thumb rests mid-track: its place claims no level.
            value: at < 0 ? (levels.length - 1) / 2 : at.toDouble(),
            min: 0,
            max: (levels.length - 1).toDouble(),
            unset: at < 0,
            valueLabel: l10n.t(
              at < 0 ? thinkingLabelKey(value) : levels[at].$2,
            ),
            reduceMotionOverride: reduceMotionOverride,
            semanticsLabel: l10n.t(L10nKey.chatReasoningEffort),
            onChanged: (v) {
              final i = v.round().clamp(0, levels.length - 1);
              if (i != at) onChanged(levels[i].$1);
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
        ],
      ],
    );
  }
}

/// Composer chip `Thinking: Medium` that opens a [ThinkingEffortPicker] above itself. Usable
/// by mouse, touch, keyboard (arrows), and screen reader; the popover closes on an outside
/// tap or Escape.
class ThinkingControl extends StatefulWidget {
  const ThinkingControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.reduceMotionOverride = false,
    this.compact = false,
    this.allowedLevels = const <String>[],
  });

  /// Passed to [ThinkingEffortPicker.allowedLevels].
  final List<String> allowedLevels;

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

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final level = l10n.t(thinkingLabelKey(widget.value));
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
    final width = PopoverPlacement.popoverWidthFor(context, 320);
    final shift = PopoverPlacement.popoverShiftFor(
      this.context,
      width: width,
      alignStart: true,
    );
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
          // Moved back inside the window on a narrow screen (never off its edge).
          offset: Offset(shift, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            reduceMotionOverride: widget.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: width, maxWidth: width),
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
                        // Auto and Adaptive show on their chip; a level shows here.
                        if (isThinkingLevel(widget.value))
                          InkText(
                            l10n.t(thinkingLabelKey(widget.value)),
                            role: InkTextRole.captionMeta,
                            color: theme.accentBrass,
                          ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    ThinkingEffortPicker(
                      value: widget.value,
                      onChanged: widget.onChanged,
                      reduceMotionOverride: widget.reduceMotionOverride,
                      allowedLevels: widget.allowedLevels,
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.t(L10nKey.chatThinkingHint),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
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
