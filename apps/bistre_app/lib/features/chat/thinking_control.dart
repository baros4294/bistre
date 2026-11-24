import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
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

/// Composer chip `Thinking: Medium` that opens a step slider above itself (Parchment v2.6.0
/// `ThinkingControl`): Auto, Off, Low, Medium, High, Extra, Max. Usable by mouse, touch,
/// keyboard (arrows), and screen reader; the popover closes on an outside tap or Escape.
class ThinkingControl extends StatefulWidget {
  const ThinkingControl({
    super.key,
    required this.value,
    required this.onChanged,
    this.reduceMotionOverride = false,
  });

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
    final level = l10n.t(kThinkingStops[thinkingStopIndex(widget.value)].$2);
    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: EngravedButton(
          label: l10n.t(L10nKey.chatThinkingChip, <String, Object?>{
            'level': level,
          }),
          compact: true,
          leading: BistreIcon(
            BistreUiIcon.think,
            size: 13,
            color: theme.inkSecondary,
          ),
          onPressed: _popover.toggle,
        ),
      ),
    );
  }

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
                      semanticsLabel: l10n.t(L10nKey.chatReasoningEffort),
                      onChanged: (v) {
                        final i = v.round().clamp(0, last);
                        if (i != index) widget.onChanged(kThinkingStops[i].$1);
                      },
                    ),
                    Row(
                      children: [
                        InkText(
                          l10n.t(kThinkingStops.first.$2),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                        const Spacer(),
                        InkText(
                          l10n.t(kThinkingStops.last.$2),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        ),
                      ],
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
