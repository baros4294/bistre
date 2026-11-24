import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';

/// Extended Preferences sections mounted inside Appearance & Preferences:
/// - Message navigation rail & Chat item display toggles
/// - Rendering & Light/Dark code syntax theme selector with live preview
/// - Behavior, Global instructions & Desktop App controls (OS notify, tray, startup, Quick Entry)
class AppearancePreferencesExtra extends StatefulWidget {
  const AppearancePreferencesExtra({super.key, required this.controller});

  final FolioController controller;

  @override
  State<AppearancePreferencesExtra> createState() =>
      _AppearancePreferencesExtraState();
}

class _AppearancePreferencesExtraState
    extends State<AppearancePreferencesExtra> {
  static const String _kCodeSample =
      'fn greet(name: &str) -> String { format!("Hello, {name}!") }';
  final TextEditingController _globalInstrCtrl = TextEditingController();
  final FocusNode _globalInstrFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _globalInstrCtrl.text = widget.controller.uiPrefs.globalInstructions;
  }

  @override
  void dispose() {
    _globalInstrCtrl.dispose();
    _globalInstrFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final p = ctrl.uiPrefs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BistreSpacing.s24),
        // 1. Chat Item Display & Message Nav Rail
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsPrefsDisplayHeading),
          children: [
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsPrefsMessageNav),
              trailing: BistreSegmentedControl<String>(
                selected: p.messageNavVisibility,
                onSelected: (v) => unawaited(
                  ctrl.saveUiPrefs(
                    p.copyWith(messageNavVisibility: v),
                    quiet: true,
                  ),
                ),
                options: <BistreSegmentedOption<String>>[
                  BistreSegmentedOption<String>(
                    value: 'always',
                    label: l10n.t(L10nKey.settingsPrefsNavAlways),
                  ),
                  BistreSegmentedOption<String>(
                    value: 'while_scrolling',
                    label: l10n.t(L10nKey.settingsPrefsNavScrolling),
                  ),
                  BistreSegmentedOption<String>(
                    value: 'hidden',
                    label: l10n.t(L10nKey.settingsPrefsNavHidden),
                  ),
                ],
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowModelName),
              value: p.showModelName,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showModelName: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowProviderModel),
              value: p.showProviderAfterModel,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(showProviderAfterModel: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowThinking),
              value: p.showThinkingCards,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showThinkingCards: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowTools),
              value: p.showToolCards,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showToolCards: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowChatDates),
              value: p.showChatListDates,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showChatListDates: v), quiet: true),
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s24),

        // 2. Rendering & Code Syntax Theme
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsPrefsRenderingHeading),
          children: [
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsRenderUserMd),
              value: p.renderUserMarkdown,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(renderUserMarkdown: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsRenderMath),
              value: p.renderMathFormulas,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(renderMathFormulas: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsCollapseCode),
              value: p.autoCollapseCodeBlocks,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(autoCollapseCodeBlocks: v),
                  quiet: true,
                ),
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsPrefsSyntaxTheme),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final id in const <String>[
                        'sepia_warm',
                        'github_light',
                        'espresso_amber',
                        'slate_dark',
                      ])
                        InkChip(
                          label: id.replaceAll('_', ' '),
                          selected:
                              (theme.isDark
                                  ? p.codeSyntaxThemeDark
                                  : p.codeSyntaxThemeLight) ==
                              id,
                          onSelected: () => unawaited(
                            ctrl.saveUiPrefs(
                              theme.isDark
                                  ? p.copyWith(codeSyntaxThemeDark: id)
                                  : p.copyWith(codeSyntaxThemeLight: id),
                              quiet: true,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  FolioSurface(
                    padding: const EdgeInsetsDirectional.all(10),
                    borderRadius: 8,
                    child: InkText(
                      _kCodeSample,
                      role: InkTextRole.codeBlock,
                      color: theme.inkPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: BistreSpacing.s24),

        // 3. Behavior & Global Instructions
        BistreSettingsSection(
          title: l10n.t(L10nKey.settingsPrefsBehaviorHeading),
          children: [
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsCollapseThinking),
              value: p.autoCollapseThinking,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(autoCollapseThinking: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsConfirmDelete),
              value: p.confirmBeforeDeletingChat,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(confirmBeforeDeletingChat: v),
                  quiet: true,
                ),
              ),
            ),
            BistreSettingRow(
              label: l10n.t(L10nKey.settingsPrefsGlobalInstructions),
              description: l10n.t(L10nKey.settingsPrefsGlobalInstructionsHint),
              bottom: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  QuillInput(
                    controller: _globalInstrCtrl,
                    focusNode: _globalInstrFocus,
                    placeholder: l10n.t(
                      L10nKey.settingsPrefsGlobalInstructionsHint,
                    ),
                    maxLines: 4,
                    submitOnEnter: false,
                    onSubmitted: () {},
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: EngravedButton(
                      label: l10n.t(L10nKey.threadSave),
                      compact: true,
                      onPressed: () => unawaited(
                        ctrl.saveUiPrefs(
                          p.copyWith(
                            globalInstructions: _globalInstrCtrl.text.trim(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (Platform.isWindows || Platform.isLinux) ...[
          const SizedBox(height: BistreSpacing.s24),
          // 4. Desktop App Controls (Phase 5: OS Notify, Sound, Startup, Tray)
          BistreSettingsSection(
            title: l10n.t(L10nKey.settingsDesktopHeading),
            children: [
              _PrefToggle(
                label: l10n.t(L10nKey.settingsDesktopNotify),
                value: p.desktopNotifyOnComplete,
                reduceMotion: ctrl.reduceMotionOverride,
                onChanged: (v) => unawaited(
                  ctrl.saveUiPrefs(
                    p.copyWith(desktopNotifyOnComplete: v),
                    quiet: true,
                  ),
                ),
              ),
              _PrefToggle(
                label: l10n.t(L10nKey.settingsDesktopNotifySound),
                value: p.desktopNotifySound,
                reduceMotion: ctrl.reduceMotionOverride,
                onChanged: (v) => unawaited(
                  ctrl.saveUiPrefs(
                    p.copyWith(desktopNotifySound: v),
                    quiet: true,
                  ),
                ),
              ),
              _PrefToggle(
                label: l10n.t(L10nKey.settingsDesktopRunStartup),
                value: p.runOnStartup,
                reduceMotion: ctrl.reduceMotionOverride,
                onChanged: (v) {
                  unawaited(BistreDesktopHost.setAutoStart(v));
                  unawaited(
                    ctrl.saveUiPrefs(p.copyWith(runOnStartup: v), quiet: true),
                  );
                },
              ),
              _PrefToggle(
                label: l10n.t(L10nKey.settingsDesktopSystemTray),
                value: p.systemTrayEnabled,
                reduceMotion: ctrl.reduceMotionOverride,
                onChanged: (v) {
                  unawaited(BistreDesktopHost.setTrayEnabled(v));
                  unawaited(
                    ctrl.saveUiPrefs(
                      p.copyWith(systemTrayEnabled: v),
                      quiet: true,
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PrefToggle extends StatelessWidget {
  const _PrefToggle({
    required this.label,
    required this.value,
    required this.reduceMotion,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool reduceMotion;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return BistreSettingRow(
      label: label,
      trailing: BistreSwitch(
        value: value,
        semanticsLabel: label,
        reduceMotionOverride: reduceMotion,
        onChanged: onChanged,
      ),
    );
  }
}
