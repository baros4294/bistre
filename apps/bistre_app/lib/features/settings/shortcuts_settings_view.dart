import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Interactive Keyboard Shortcuts Studio:
/// Click any row to record a custom keybinding (`Ctrl+...`, `Alt+...`, `Shift+...`)
/// and persist it directly into Rust SQLite settings, or reset cleanly to defaults.
class ShortcutsSettingsView extends StatefulWidget {
  const ShortcutsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ShortcutsSettingsView> createState() => _ShortcutsSettingsViewState();
}

class _ShortcutsSettingsViewState extends State<ShortcutsSettingsView> {
  String? _recordingActionId;
  final FocusNode _captureFocus = FocusNode();

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  void _startRecording(String actionId) {
    setState(() => _recordingActionId = actionId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _captureFocus.requestFocus();
    });
  }

  KeyEventResult _handleKeyCapture(FocusNode node, KeyEvent event) {
    if (_recordingActionId == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _recordingActionId = null);
      return KeyEventResult.handled;
    }
    if (_isModifierOnly(key)) {
      return KeyEventResult.handled;
    }

    final hw = HardwareKeyboard.instance;
    final parts = <String>[];
    if (hw.isControlPressed) parts.add('Ctrl');
    if (hw.isMetaPressed) parts.add('Meta');
    if (hw.isAltPressed) parts.add('Alt');
    if (hw.isShiftPressed) parts.add('Shift');
    final keyLabel = _canonicalKeyName(key);
    if (keyLabel == null || parts.isEmpty) {
      return KeyEventResult.handled;
    }
    parts.add(keyLabel);

    final targetId = _recordingActionId!;
    setState(() => _recordingActionId = null);
    unawaited(widget.controller.setShortcutBinding(targetId, parts.join('+')));
    return KeyEventResult.handled;
  }

  static bool _isModifierOnly(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight;

  static String? _canonicalKeyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.period) return '.';
    if (key == LogicalKeyboardKey.semicolon) return ';';
    final label = key.keyLabel.trim();
    if (label.length == 1) return label.toUpperCase();
    if (label.startsWith('F') && label.length <= 3) return label;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;

    return Focus(
      focusNode: _captureFocus,
      onKeyEvent: _handleKeyCapture,
      child: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsTabShortcuts),
              children: [
                for (final spec in ShortcutActionSpec.defaults)
                  _ShortcutRow(
                    label: l10n.t(spec.labelKey),
                    combo: ctrl.shortcutFor(spec.id),
                    recording: _recordingActionId == spec.id,
                    recordHint: l10n.t(L10nKey.shortcutsRecordHint),
                    onTap: () => _startRecording(spec.id),
                  ),
                Padding(
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: BistreSpacing.s16,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.shortcutEscape),
                          role: InkTextRole.bodyCompact,
                          color: theme.inkSecondary,
                        ),
                      ),
                      const _KeycapStrip(combo: _kEscCombo),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: EngravedButton(
                label: l10n.t(L10nKey.shortcutsResetDefaults),
                onPressed: () {
                  setState(() => _recordingActionId = null);
                  unawaited(ctrl.resetShortcuts());
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const String _kEscCombo = 'Esc';
}

class _ShortcutRow extends StatefulWidget {
  const _ShortcutRow({
    required this.label,
    required this.combo,
    required this.recording,
    required this.recordHint,
    required this.onTap,
  });

  final String label;
  final String combo;
  final bool recording;
  final String recordHint;
  final VoidCallback onTap;

  @override
  State<_ShortcutRow> createState() => _ShortcutRowState();
}

class _ShortcutRowState extends State<_ShortcutRow> {
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
        child: ColoredBox(
          color: widget.recording || _hovered
              ? theme.hoverTint
              : theme.bgElevated,
          child: Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: BistreSpacing.s16,
              vertical: 13,
            ),
            child: Row(
              children: [
                Expanded(
                  child: InkText(
                    widget.label,
                    role: InkTextRole.bodyCompact,
                    color: theme.inkPrimary,
                  ),
                ),
                if (widget.recording)
                  WaxSealBadge(
                    label: widget.recordHint,
                    status: WaxSealStatus.warn,
                  )
                else
                  _KeycapStrip(combo: widget.combo),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeycapStrip extends StatelessWidget {
  const _KeycapStrip({required this.combo});

  final String combo;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final keys = combo.split('+');
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < keys.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            DecoratedBox(
              decoration: BoxDecoration(
                color: theme.bgSurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: theme.borderHairline),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                child: Text(
                  keys[i],
                  style: BistreTypography.codeBlock(
                    theme.inkPrimary,
                    config: theme.typography,
                  ).copyWith(fontSize: 11.5, height: 15 / 11.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
