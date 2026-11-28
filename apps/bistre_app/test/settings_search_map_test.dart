import 'package:bistre_app/features/settings/settings_workspace.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every settings page can be found by the labels on it (Default models and World book
/// could not be found at all, and several pages missed whole groups of their labels).
void main() {
  test('settings search covers every page\'s own labels', () {
    const cases = <(String, SettingsTab)>[
      ('settings.default_models.global_heading', SettingsTab.defaultModels),
      ('settings.world_book.add_entry', SettingsTab.worldBook),
      ('automations.title', SettingsTab.memory),
      ('skills.title', SettingsTab.memory),
      ('shortcuts.reset_defaults', SettingsTab.shortcuts),
      ('settings.desktop.system_tray', SettingsTab.appearance),
      ('settings.prefs.show_model_name', SettingsTab.appearance),
      ('settings.provider.advanced_page_title', SettingsTab.providers),
      ('settings.model.context_limit', SettingsTab.providers),
    ];
    for (final (key, tab) in cases) {
      final prefixes = settingsSearchPrefixes[tab] ?? const <String>[];
      expect(prefixes.any(key.startsWith), isTrue, reason: '$key on $tab');
    }
  });
}
