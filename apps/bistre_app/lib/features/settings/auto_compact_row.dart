import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// The range core accepts for the auto-compact point (it clamps to the same bounds).
const int kAutoCompactMinPercent = 50;
const int kAutoCompactMaxPercent = 95;

/// How full a chat may get before a run shortens it: drag the slider, or type a number.
class AutoCompactRow extends StatefulWidget {
  const AutoCompactRow({super.key, required this.controller});

  final FolioController controller;

  @override
  State<AutoCompactRow> createState() => _AutoCompactRowState();
}

class _AutoCompactRowState extends State<AutoCompactRow> {
  late final TextEditingController _box = TextEditingController(
    text: '${_saved()}',
  );
  final FocusNode _focus = FocusNode();

  /// The slider's spot while it is dragged; null shows the saved value.
  int? _dragging;

  int _saved() => widget.controller.settings.autoCompactAtPercent.clamp(
    kAutoCompactMinPercent,
    kAutoCompactMaxPercent,
  );

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _applyBox();
    });
  }

  @override
  void dispose() {
    _box.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _save(int percent) {
    final value = percent.clamp(kAutoCompactMinPercent, kAutoCompactMaxPercent);
    setState(() => _dragging = null);
    if (!_focus.hasFocus) _box.text = '$value';
    final s = widget.controller.settings;
    if (s.autoCompactAtPercent == value) return;
    unawaited(
      widget.controller.updateSettings(
        s.copyWith(autoCompactAtPercent: value),
        quiet: true,
      ),
    );
  }

  /// Out-of-range or unreadable numbers snap back to the nearest allowed value.
  void _applyBox() {
    final typed = int.tryParse(_box.text.trim().replaceAll('%', ''));
    final value = (typed ?? _saved()).clamp(
      kAutoCompactMinPercent,
      kAutoCompactMaxPercent,
    );
    _box.text = '$value';
    _save(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final label = l10n.t(L10nKey.settingsDefaultModelsAutoCompact);
    final shown = _dragging ?? _saved();
    return BistreSettingRow(
      label: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            child: QuillInput(
              controller: _box,
              focusNode: _focus,
              placeholder: '',
              maxLines: 1,
              compact: true,
              submitOnEnter: false,
              semanticsLabel: label,
              onSubmitted: _applyBox,
            ),
          ),
          const SizedBox(width: BistreSpacing.s4),
          InkText(
            l10n.t(L10nKey.settingsDefaultModelsAutoCompactUnit),
            role: InkTextRole.captionMeta,
            color: theme.inkSecondary,
          ),
        ],
      ),
      bottom: BistreSlider(
        value: shown.toDouble(),
        min: kAutoCompactMinPercent.toDouble(),
        max: kAutoCompactMaxPercent.toDouble(),
        semanticsLabel: label,
        valueLabel: l10n.t(
          L10nKey.settingsDefaultModelsAutoCompactValue,
          <String, Object?>{'percent': shown},
        ),
        reduceMotionOverride: widget.controller.reduceMotionOverride,
        onChanged: (v) {
          setState(() => _dragging = v.round());
          if (!_focus.hasFocus) _box.text = '${v.round()}';
        },
        // The slider reports its end before this row rebuilds: the dragged spot is current.
        onChangeEnd: (v) => _save(_dragging ?? v.round()),
      ),
    );
  }
}

/// How many of the latest messages a request sends (core cuts before a message you wrote).
class HistoryLimitRow extends StatelessWidget {
  const HistoryLimitRow({super.key, required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    final ctrl = controller;
    return BistreSettingRow(
      label: l10n.t(L10nKey.settingsHistoryLimit),
      description: l10n.t(L10nKey.settingsHistoryLimitHint),
      bottom: BistreSegmentedControl<int>(
        selected: ctrl.historyMessageLimit,
        onSelected: (v) => unawaited(ctrl.setHistoryMessageLimit(v)),
        options: <BistreSegmentedOption<int>>[
          for (final limit in kHistoryLimits)
            BistreSegmentedOption<int>(
              value: limit,
              label: limit == 0
                  ? l10n.t(L10nKey.settingsHistoryLimitAll)
                  : l10n.t(L10nKey.settingsHistoryLimitCount, <String, Object?>{
                      'count': limit,
                    }),
            ),
        ],
      ),
    );
  }
}
