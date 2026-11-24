import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../../platform/desktop_host.dart';
import '../shell/folio_controller.dart';

/// Updates & Local Storage Studio:
/// - Real zero-telemetry Track-A/B OTA update checks + offline Ed25519 signature verification
/// - Release channel (`Stable | Beta`), configurable manifest feed URL, active-run deferral banner
/// - Local storage folder inspector with Dev Environment isolation badge, OS "Open folder",
///   and WAL-safe `VACUUM INTO` database backup.
class UpdatesStorageSettingsView extends StatefulWidget {
  const UpdatesStorageSettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<UpdatesStorageSettingsView> createState() =>
      _UpdatesStorageSettingsViewState();
}

class _UpdatesStorageSettingsViewState
    extends State<UpdatesStorageSettingsView> {
  final TextEditingController _feedUrlCtrl = TextEditingController();
  final FocusNode _feedUrlFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _feedUrlCtrl.text = widget.controller.settings.otaFeedUrl;
  }

  @override
  void dispose() {
    _feedUrlCtrl.dispose();
    _feedUrlFocus.dispose();
    super.dispose();
  }

  Future<void> _saveFeedAndCheck() async {
    final ctrl = widget.controller;
    final url = _feedUrlCtrl.text.trim();
    if (url != ctrl.settings.otaFeedUrl) {
      await ctrl.updateSettings(
        ctrl.settings.copyWith(otaFeedUrl: url),
        quiet: true,
      );
    }
    await ctrl.checkForUpdates(feedUrlOverride: url.isNotEmpty ? url : null);
  }

  Future<void> _backupDatabase() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.saveLocalFile(
      title: l10n.t(L10nKey.settingsStorageBackupDb),
      defaultName: 'bistre-backup.sqlite3',
      filterLabel: 'SQLite Database',
      filterSpec: '*.sqlite3',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.backupDatabaseTo(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final s = ctrl.settings;
    final health = ctrl.health;
    final stats = ctrl.storageStats;
    final check = ctrl.updateCheck;
    final installedVersion = health?.coreVersion ?? '0.1.0';

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Section 1: Software & Data Updates (OTA)
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsOtaSectionTitle),
              subtitle: l10n.t(L10nKey.settingsOtaSectionSubtitle),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsOtaCurrentVersion),
                  description: 'v$installedVersion',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (check != null && !check.updateAvailable) ...[
                        WaxSealBadge(
                          label: l10n.t(
                            L10nKey.settingsOtaUpToDate,
                            <String, Object?>{'version': check.currentVersion},
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      EngravedButton(
                        label: ctrl.checkingUpdates
                            ? l10n.t(L10nKey.settingsOtaChecking)
                            : l10n.t(L10nKey.settingsOtaCheckButton),
                        primary: true,
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.download,
                          size: 13,
                          color: theme.onAccentWax,
                        ),
                        onPressed: ctrl.checkingUpdates
                            ? null
                            : () => unawaited(_saveFeedAndCheck()),
                      ),
                    ],
                  ),
                ),
                if (check != null && check.updateAvailable)
                  Padding(
                    padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.bgSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: theme.accentBrass.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: InkText(
                                    l10n.t(
                                      L10nKey.settingsOtaUpdateAvailable,
                                      <String, Object?>{
                                        'version': check.latestVersion,
                                      },
                                    ),
                                    role: InkTextRole.labelStrong,
                                    color: theme.inkPrimary,
                                  ),
                                ),
                                if (check.signatureVerified)
                                  WaxSealBadge(
                                    label: l10n.t(
                                      L10nKey.settingsOtaSignatureVerified,
                                    ),
                                  ),
                              ],
                            ),
                            if (check.releaseNotes.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              InkText(
                                check.releaseNotes,
                                role: InkTextRole.bodyCompact,
                                color: theme.inkSecondary,
                              ),
                            ],
                            if (ctrl.hasAnyActiveRun ||
                                check.activeRunsBlocking) ...[
                              const SizedBox(height: 8),
                              InkText(
                                l10n.t(L10nKey.settingsOtaActiveRunsNotice),
                                role: InkTextRole.captionMeta,
                                color: theme.statusWarn,
                              ),
                            ],
                            const SizedBox(height: 10),
                            if (ctrl.stagedUpdatePath != null)
                              WaxSealBadge(
                                label: l10n.t(L10nKey.settingsOtaStagedReady),
                              )
                            else
                              EngravedButton(
                                label: ctrl.stagingUpdate
                                    ? l10n.t(L10nKey.settingsOtaStaging)
                                    : l10n.t(L10nKey.settingsOtaDownloadStage),
                                primary: true,
                                compact: true,
                                onPressed: ctrl.stagingUpdate
                                    ? null
                                    : () => unawaited(
                                        ctrl.stageAvailableUpdate(),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsOtaChannel),
                  trailing: BistreSegmentedControl<String>(
                    selected: s.otaChannel,
                    onSelected: (v) => unawaited(
                      ctrl.updateSettings(s.copyWith(otaChannel: v)),
                    ),
                    options: <BistreSegmentedOption<String>>[
                      BistreSegmentedOption<String>(
                        value: 'stable',
                        label: l10n.t(L10nKey.settingsOtaChannelStable),
                      ),
                      BistreSegmentedOption<String>(
                        value: 'beta',
                        label: l10n.t(L10nKey.settingsOtaChannelBeta),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsOtaFeedUrl),
                  bottom: QuillInput(
                    controller: _feedUrlCtrl,
                    focusNode: _feedUrlFocus,
                    placeholder: _kFeedUrlHint,
                    maxLines: 1,
                    submitOnEnter: false,
                    onSubmitted: () => unawaited(_saveFeedAndCheck()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // Section 2: Local Storage & Backups
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsStorageSectionTitle),
              subtitle: l10n.t(L10nKey.settingsEngineTelemetry),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageDataDir),
                  description: stats?.dataDir ?? '',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (ctrl.isDevEnvironment) ...[
                        WaxSealBadge(
                          label: l10n.t(L10nKey.settingsStorageDevBadge),
                          status: WaxSealStatus.warn,
                        ),
                        const SizedBox(width: 8),
                      ],
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageOpenFolder),
                        compact: true,
                        leading: BistreIcon(
                          BistreUiIcon.folder,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        onPressed: () => unawaited(ctrl.openDataFolder()),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageDbSize),
                  description: health != null
                      ? l10n.t(L10nKey.settingsEngineMetrics, <String, Object?>{
                          'version': health.coreVersion,
                          'schema': health.schemaVersion,
                          'threads': health.threadCount,
                          'nodes': health.nodeCount,
                          'runs': health.activeRuns,
                        })
                      : null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (stats != null) ...[
                        WaxSealBadge(
                          label: FolioController.formatBytes(stats.dbSizeBytes),
                          status: WaxSealStatus.neutral,
                        ),
                        const SizedBox(width: 10),
                      ],
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageBackupDb),
                        compact: true,
                        onPressed: () => unawaited(_backupDatabase()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const String _kFeedUrlHint = 'https://...';
}
