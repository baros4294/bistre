import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';
import '../shell/shortcut_combo.dart';

/// Settings > Shortcuts: click a row and press a new shortcut. A press that would take a key
/// away from typing or editing, or that another action already uses, is refused with the
/// reason, and recording goes on. On Windows a second section holds the quick entry
/// shortcut, which works from any app and can be turned off.
class ShortcutsSettingsView extends StatefulWidget {
  const ShortcutsSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ShortcutsSettingsView> createState() => _ShortcutsSettingsViewState();
}

class _ShortcutsSettingsViewState extends State<ShortcutsSettingsView> {
  String? _recordingActionId;

  /// Why the last press while recording was refused.
  String? _refusal;
  final FocusNode _captureFocus = FocusNode();

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  void _startRecording(String actionId) {
    setState(() {
      _recordingActionId = actionId;
      _refusal = null;
    });
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
    final hw = HardwareKeyboard.instance;
    final ctrl = widget.controller;
    final targetId = _recordingActionId!;
    final quickEntry = targetId == _kQuickEntryId;
    final pressed = ShortcutCombo.record(
      key,
      control: hw.isControlPressed,
      meta: hw.isMetaPressed,
      alt: hw.isAltPressed,
      shift: hw.isShiftPressed,
    );
    if (pressed == null) return KeyEventResult.handled;
    final l10n = BistreLocalizations.of(context);
    final combo = pressed.combo;
    // A function key alone is fine inside Bistre, but from any app it would take the key
    // from every other program.
    final bareKey =
        !hw.isControlPressed && !hw.isAltPressed && !hw.isMetaPressed;
    final takenBy = combo == null
        ? null
        : ShortcutActionSpec.defaults
                  .where(
                    (s) =>
                        s.id != targetId &&
                        ShortcutCombo.same(ctrl.shortcutFor(s.id), combo),
                  )
                  .firstOrNull
                  ?.labelKey ??
              (!quickEntry &&
                      Platform.isWindows &&
                      ShortcutCombo.same(ctrl.uiPrefs.quickEntryShortcut, combo)
                  ? L10nKey.shortcutsQuickEntry
                  : null);
    final refusal = switch (pressed.refusal) {
      ShortcutRefusal.needsModifier => l10n.t(L10nKey.shortcutsNeedsModifier),
      null when quickEntry && bareKey => l10n.t(L10nKey.shortcutsNeedsModifier),
      ShortcutRefusal.editing => l10n.t(L10nKey.shortcutsKeptForEditing),
      null when takenBy != null => l10n.t(
        L10nKey.shortcutsTaken,
        <String, Object?>{'action': l10n.t(takenBy)},
      ),
      null => null,
    };
    if (refusal != null || combo == null) {
      setState(() => _refusal = refusal);
      return KeyEventResult.handled;
    }
    setState(() => _recordingActionId = null);
    unawaited(
      quickEntry
          ? ctrl.setQuickEntryShortcut(combo)
          : ctrl.setShortcutBinding(targetId, combo),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;

    return Focus(
      focusNode: _captureFocus,
      onKeyEvent: _handleKeyCapture,
      child: SmoothScrollable(
        builder: (_, scroll) => SingleChildScrollView(
          controller: scroll,
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
                      recordHint:
                          _refusal ?? l10n.t(L10nKey.shortcutsRecordHint),
                      onTap: () => _startRecording(spec.id),
                    ),
                  Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: BistreSpacing.s16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        // The muted row says why it cannot be recorded.
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              InkText(
                                l10n.t(L10nKey.shortcutEscape),
                                role: InkTextRole.bodyCompact,
                                color: theme.inkSecondary,
                              ),
                              InkText(
                                l10n.t(L10nKey.shortcutsEscapeFixed),
                                role: InkTextRole.captionMeta,
                                color: theme.inkMuted,
                              ),
                            ],
                          ),
                        ),
                        const _KeycapStrip(combo: _kEscCombo),
                      ],
                    ),
                  ),
                ],
              ),
              if (Platform.isWindows) ...[
                const SizedBox(height: BistreSpacing.s16),
                _buildQuickEntry(theme, l10n, ctrl),
              ],
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
      ),
    );
  }

  static const String _kEscCombo = 'Esc';

  /// The recording id of the quick entry row; no in-app action uses it.
  static const String _kQuickEntryId = 'quick_entry';

  Widget _buildQuickEntry(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
  ) {
    final combo = ctrl.uiPrefs.quickEntryShortcut;
    return BistreSettingsSection(
      title: l10n.t(L10nKey.shortcutsQuickEntryTitle),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ShortcutRow(
              label: l10n.t(L10nKey.shortcutsQuickEntry),
              combo: combo,
              emptyLabel: l10n.t(L10nKey.shortcutsOff),
              recording: _recordingActionId == _kQuickEntryId,
              recordHint: _refusal ?? l10n.t(L10nKey.shortcutsRecordHint),
              onTap: () => _startRecording(_kQuickEntryId),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                BistreSpacing.s16,
                0,
                BistreSpacing.s16,
                14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkText(
                    l10n.t(L10nKey.shortcutsQuickEntryHint),
                    role: InkTextRole.captionMeta,
                    color: theme.inkMuted,
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: BistreDesktopHost.quickEntryRefused,
                    builder: (context, refused, _) =>
                        refused && combo.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsetsDirectional.only(top: 6),
                            child: InkText(
                              l10n.t(L10nKey.shortcutsQuickEntryRefused),
                              role: InkTextRole.captionMeta,
                              color: theme.statusWarn,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (combo.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    EngravedButton(
                      label: l10n.t(L10nKey.shortcutsTurnOff),
                      compact: true,
                      onPressed: () {
                        setState(() => _recordingActionId = null);
                        unawaited(ctrl.setQuickEntryShortcut(''));
                      },
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ShortcutRow extends StatefulWidget {
  const _ShortcutRow({
    required this.label,
    required this.combo,
    required this.recording,
    required this.recordHint,
    required this.onTap,
    this.emptyLabel = '',
  });

  final String label;

  /// The keys in saved form; when empty the row shows [emptyLabel].
  final String combo;
  final String emptyLabel;
  final bool recording;
  final String recordHint;
  final VoidCallback onTap;

  @override
  State<_ShortcutRow> createState() => _ShortcutRowState();
}

class _ShortcutRowState extends State<_ShortcutRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Semantics(
      button: true,
      label: widget.label,
      value: widget.recording
          ? widget.recordHint
          : (widget.combo.isEmpty ? widget.emptyLabel : widget.combo),
      excludeSemantics: true,
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
            child: ColoredBox(
              color: widget.recording || _hovered || _focused
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
                    else if (widget.combo.isEmpty)
                      InkText(
                        widget.emptyLabel,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      )
                    else
                      _KeycapStrip(combo: widget.combo),
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
