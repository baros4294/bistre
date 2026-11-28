part of 'folio_controller.dart';

/// The quick entry shortcut until the user changes or turns it off. It takes the keys from
/// every app, so it uses three modifiers: Ctrl+Alt alone is AltGr on many layouts, and
/// Alt+Space opens the Windows window menu.
const String kDefaultQuickEntryShortcut = 'Ctrl+Alt+Shift+B';

/// Quick entry: the system-wide shortcut (Windows) that opens a new chat from any app.
extension FolioQuickEntry on FolioController {
  /// Saves [combo] as the quick entry shortcut (`''` turns it off) and registers it.
  Future<void> setQuickEntryShortcut(String combo) async {
    await saveUiPrefs(_uiPrefs.copyWith(quickEntryShortcut: combo));
    await BistreDesktopHost.setQuickEntryHotkey(combo);
  }
}

/// Canonical keyboard shortcut action identifiers and default combos.
class ShortcutActionSpec {
  const ShortcutActionSpec({
    required this.id,
    required this.labelKey,
    required this.defaultCombo,
  });

  final String id;
  final L10nKey labelKey;
  final String defaultCombo;

  static const List<ShortcutActionSpec> defaults = <ShortcutActionSpec>[
    ShortcutActionSpec(
      id: 'palette',
      labelKey: L10nKey.shortcutPalette,
      defaultCombo: 'Ctrl+K',
    ),
    ShortcutActionSpec(
      id: 'new_chat',
      labelKey: L10nKey.shortcutNewFolio,
      defaultCombo: 'Ctrl+N',
    ),
    ShortcutActionSpec(
      id: 'sidebar',
      labelKey: L10nKey.shortcutSidebar,
      defaultCombo: 'Ctrl+B',
    ),
    ShortcutActionSpec(
      id: 'settings',
      labelKey: L10nKey.shortcutSettings,
      defaultCombo: 'Ctrl+,',
    ),
    ShortcutActionSpec(
      id: 'search',
      labelKey: L10nKey.shortcutSearch,
      defaultCombo: 'Ctrl+Shift+F',
    ),
    ShortcutActionSpec(
      id: 'theme',
      labelKey: L10nKey.shortcutTheme,
      defaultCombo: 'Ctrl+Shift+L',
    ),
    ShortcutActionSpec(
      id: 'layout',
      labelKey: L10nKey.shortcutLayout,
      defaultCombo: 'Ctrl+Shift+M',
    ),
    ShortcutActionSpec(
      id: 'shortcuts',
      labelKey: L10nKey.shortcutShortcuts,
      defaultCombo: 'Ctrl+/',
    ),
    ShortcutActionSpec(
      id: 'jump_prompt',
      labelKey: L10nKey.shortcutJumpPrompt,
      defaultCombo: 'Ctrl+Alt+G',
    ),
    ShortcutActionSpec(
      id: 'stop_reply',
      labelKey: L10nKey.shortcutStopReply,
      defaultCombo: 'Ctrl+.',
    ),
  ];
}
