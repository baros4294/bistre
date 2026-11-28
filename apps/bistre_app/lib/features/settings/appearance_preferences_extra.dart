import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../chat/markdown_folio_view.dart';
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
              label: l10n.t(L10nKey.settingsPrefsShowModelIcon),
              value: p.showModelIcon,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showModelIcon: v), quiet: true),
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
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowTimestamps),
              value: p.showUserTimestamp,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showUserTimestamp: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowUserName),
              value: p.showUserName,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showUserName: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsShowSentFiles),
              value: p.showSentFiles,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(showSentFiles: v), quiet: true),
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
                  Builder(
                    builder: (context) {
                      final activeSyntaxId = theme.isDark
                          ? p.codeSyntaxThemeDark
                          : p.codeSyntaxThemeLight;
                      final palette = BistreSyntaxPalette.forId(
                        activeSyntaxId,
                        isDark: theme.isDark,
                      );
                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.background,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: theme.borderHairline),
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.all(10),
                          child: Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text.rich(
                              highlightCodeSpans(
                                _kCodeSample,
                                theme,
                                syntaxThemeIdOverride: activeSyntaxId,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
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
              label: l10n.t(L10nKey.settingsPrefsConfirmRegenerate),
              value: p.confirmBeforeRegenerating,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(confirmBeforeRegenerating: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsCollapseLong),
              value: p.collapseLongMessages,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(collapseLongMessages: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsFollowReplies),
              value: p.followWhileStreaming,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(followWhileStreaming: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsNewChatOnLaunch),
              value: p.newChatOnLaunch,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(p.copyWith(newChatOnLaunch: v), quiet: true),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsNewChatOnAssistant),
              value: p.newChatOnAssistantSwitch,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(newChatOnAssistantSwitch: v),
                  quiet: true,
                ),
              ),
            ),
            _PrefToggle(
              label: l10n.t(L10nKey.settingsPrefsNewChatAfterDelete),
              value: p.newChatAfterDelete,
              reduceMotion: ctrl.reduceMotionOverride,
              onChanged: (v) => unawaited(
                ctrl.saveUiPrefs(
                  p.copyWith(newChatAfterDelete: v),
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
              BistreSettingRow(
                label: l10n.t(L10nKey.settingsDesktopNotifySound),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EngravedButton(
                      label: l10n.t(L10nKey.settingsDesktopNotifyPreview),
                      compact: true,
                      onPressed: () =>
                          unawaited(BistreDesktopHost.playNotificationSound()),
                    ),
                    const SizedBox(width: 8),
                    BistreSwitch(
                      value: p.desktopNotifySound,
                      semanticsLabel: l10n.t(
                        L10nKey.settingsDesktopNotifySound,
                      ),
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onChanged: (v) => unawaited(
                        ctrl.saveUiPrefs(
                          p.copyWith(desktopNotifySound: v),
                          quiet: true,
                        ),
                      ),
                    ),
                  ],
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
