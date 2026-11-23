import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';
import 'package:bistre_lints/src/forbid_hardcoded_ui_strings.dart';
import 'package:bistre_lints/src/forbid_layout_animations.dart';
import 'package:bistre_lints/src/forbid_non_directional_geometry.dart';
import 'package:bistre_lints/src/forbid_raw_colors.dart';
import 'package:bistre_lints/src/forbid_ui_kits.dart';

/// Required top-level plugin entrypoint discovered by Dart Analysis Server.
final plugin = BistreLintsPlugin();

class BistreLintsPlugin extends Plugin {
  @override
  String get name => 'bistre_lints';

  @override
  void register(PluginRegistry registry) {
    registry.registerLintRule(ForbidUiKitsRule());
    registry.registerLintRule(ForbidHardcodedUiStringsRule());
    registry.registerLintRule(ForbidLayoutAnimationsRule());
    registry.registerLintRule(ForbidRawColorsRule());
    registry.registerLintRule(ForbidNonDirectionalGeometryRule());
  }
}
