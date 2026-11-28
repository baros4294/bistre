import 'package:flutter/widgets.dart';

import '../../bridge/engine_models.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// What paid requests were for over the last 30 days, so background work (chat names,
/// shortening, translations, helpers, voice) can be seen beside chats. Shows nothing until
/// there is some use, or when the ledger could not be read.
class UsageByPurposeSection extends StatefulWidget {
  const UsageByPurposeSection({super.key, required this.controller});

  final FolioController controller;

  @override
  State<UsageByPurposeSection> createState() => _UsageByPurposeSectionState();
}

class _UsageByPurposeSectionState extends State<UsageByPurposeSection> {
  late final Future<List<EnginePurposeUsage>?> _usage = widget.controller
      .loadUsageByPurpose();

  static L10nKey _label(EngineSpendPurpose purpose) => switch (purpose) {
    EngineSpendPurpose.chat => L10nKey.settingsDefaultModelsUsageChat,
    EngineSpendPurpose.helper => L10nKey.settingsDefaultModelsUsageHelper,
    EngineSpendPurpose.title => L10nKey.settingsDefaultModelsUsageTitle,
    EngineSpendPurpose.summary => L10nKey.settingsDefaultModelsUsageSummary,
    EngineSpendPurpose.translation =>
      L10nKey.settingsDefaultModelsUsageTranslation,
    EngineSpendPurpose.voice => L10nKey.settingsDefaultModelsUsageVoice,
  };

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return FutureBuilder<List<EnginePurposeUsage>?>(
      future: _usage,
      builder: (context, snap) {
        final rows = snap.data ?? const <EnginePurposeUsage>[];
        if (rows.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s24),
          child: BistreSettingsSection(
            title: l10n.t(L10nKey.settingsDefaultModelsUsageHeading),
            children: [
              for (final u in rows)
                BistreSettingRow(
                  label: l10n.t(_label(u.purpose)),
                  trailing: InkText(
                    l10n.t(
                      L10nKey.settingsDefaultModelsUsageValue,
                      <String, Object?>{
                        'requests': u.requests,
                        'cost': l10n.isolate(
                          FolioController.formatMicrosUsd(
                            u.costMicros,
                            showSubCent: true,
                          ),
                        ),
                      },
                    ),
                    role: InkTextRole.captionMeta,
                    color: theme.inkSecondary,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
