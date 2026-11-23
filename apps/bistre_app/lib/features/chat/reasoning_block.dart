import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Collapsible editorial thinking/reasoning hairline drawer (`Thinking · 3.8s`)
/// supporting live streaming expansion and 1-click quoting into the composer.
class ReasoningBlock extends StatefulWidget {
  const ReasoningBlock({
    super.key,
    required this.thinkingText,
    this.durationMs = 0,
    this.isStreaming = false,
    this.onQuoteIntoComposer,
  });

  final String thinkingText;
  final int durationMs;
  final bool isStreaming;
  final ValueChanged<String>? onQuoteIntoComposer;

  @override
  State<ReasoningBlock> createState() => _ReasoningBlockState();
}

class _ReasoningBlockState extends State<ReasoningBlock> {
  bool _expanded = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isStreaming;
  }

  @override
  void didUpdateWidget(covariant ReasoningBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming && !widget.isStreaming && _expanded) {
      // Collapse gently once final prose arrives so reading canvas stays calm.
      _expanded = false;
    }
  }

  static String _formatSeconds(int ms) {
    final secs = ms / 1000.0;
    return secs >= 10 ? secs.toStringAsFixed(0) : secs.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final headerLabel = widget.durationMs > 0
        ? l10n.t(L10nKey.chatThinkingSeconds, <String, Object?>{
            'seconds': _formatSeconds(widget.durationMs),
          })
        : l10n.t(L10nKey.chatThinkingLabel);

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: BistreSpacing.s12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgSurface.withValues(alpha: theme.isDark ? 0.45 : 0.55),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: theme.borderHairline.withValues(alpha: 0.75),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hovered = true),
              onExit: (_) => setState(() => _hovered = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.think,
                        size: 13,
                        color: widget.isStreaming
                            ? theme.accentWax
                            : theme.accentBrass,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkText(
                          headerLabel,
                          role: InkTextRole.captionMeta,
                          color: _hovered
                              ? theme.inkPrimary
                              : theme.inkSecondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      BistreIcon(
                        _expanded
                            ? BistreUiIcon.chevronUp
                            : BistreUiIcon.chevronDown,
                        size: 13,
                        color: theme.inkMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_expanded && widget.thinkingText.trim().isNotEmpty) ...[
              const FolioDivider(),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: BorderDirectional(
                      start: BorderSide(
                        color: theme.accentBrass.withValues(alpha: 0.45),
                        width: 2,
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 240),
                          child: SingleChildScrollView(
                            child: InkText(
                              widget.thinkingText.trim(),
                              role: InkTextRole.bodyCompact,
                              color: theme.inkSecondary,
                            ),
                          ),
                        ),
                        if (widget.onQuoteIntoComposer != null) ...[
                          const SizedBox(height: 8),
                          EngravedButton(
                            label: l10n.t(L10nKey.chatQuoteThinking),
                            compact: true,
                            leading: BistreIcon(
                              BistreUiIcon.reply,
                              size: 12,
                              color: theme.inkSecondary,
                            ),
                            onPressed: () => widget.onQuoteIntoComposer!(
                              widget.thinkingText.trim(),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact 4-option reasoning effort selector (`Off | Low | Medium | High`).
class ReasoningEffortSelector extends StatelessWidget {
  const ReasoningEffortSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  static const List<(String, L10nKey)> _options = <(String, L10nKey)>[
    ('off', L10nKey.chatEffortOff),
    ('low', L10nKey.chatEffortLow),
    ('medium', L10nKey.chatEffortMedium),
    ('high', L10nKey.chatEffortHigh),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final opt in _options)
          InkChip(
            label: l10n.t(opt.$2),
            selected: value == opt.$1,
            onSelected: () => onChanged(opt.$1),
          ),
      ],
    );
  }
}
