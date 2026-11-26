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
  bool _showOtaDetails = false;

  @override
  void initState() {
    super.initState();
    _feedUrlCtrl.text = widget.controller.settings.otaFeedUrl.isEmpty
        ? _kDefaultRepoSlug
        : widget.controller.settings.otaFeedUrl;
    unawaited(widget.controller.refreshStorageFiles());
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

  Future<void> _exportCurrentChat(String format) async {
    final l10n = BistreLocalizations.of(context);
    final ext = format == 'markdown' ? 'md' : 'json';
    final chosen = await BistreDesktopHost.saveLocalFile(
      title: l10n.t(L10nKey.settingsStorageExportCurrent),
      defaultName: 'bistre-chat.$ext',
      filterLabel: ext == 'md' ? 'Markdown (*.md)' : 'JSON (*.json)',
      filterSpec: '*.$ext',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.exportCurrentThreadToFile(chosen, format: format);
  }

  Future<void> _exportAllChats() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.saveLocalFile(
      title: l10n.t(L10nKey.settingsStorageExportAll),
      defaultName: 'bistre-chats-export.json',
      filterLabel: 'JSON (*.json)',
      filterSpec: '*.json',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.exportAllThreadsToFile(chosen);
  }

  Future<void> _importChats() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.settingsStorageImportChats),
      filterLabel: 'JSON (*.json)',
      filterSpec: '*.json',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.importThreadsFromFile(chosen);
  }

  Future<void> _exportSettings() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.saveLocalFile(
      title: l10n.t(L10nKey.settingsStorageExportSettings),
      defaultName: 'bistre-settings.json',
      filterLabel: 'JSON (*.json)',
      filterSpec: '*.json',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.exportSettingsToFile(chosen);
  }

  Future<void> _importSettings() async {
    final l10n = BistreLocalizations.of(context);
    final chosen = await BistreDesktopHost.pickLocalFile(
      title: l10n.t(L10nKey.settingsStorageImportSettings),
      filterLabel: 'JSON (*.json)',
      filterSpec: '*.json',
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.controller.importSettingsFromFile(chosen);
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
                if (ctrl.lastOtaDiagnostic case final otaDiag?)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      BistreSpacing.s16,
                      0,
                      BistreSpacing.s16,
                      BistreSpacing.s12,
                    ),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.bgSurface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: theme.statusErr.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkText(
                              l10n.t(L10nKey.settingsOtaCheckErrorTitle),
                              role: InkTextRole.labelStrong,
                              color: theme.statusErr,
                            ),
                            const SizedBox(height: 4),
                            InkText(
                              l10n.tRawKey(otaDiag),
                              role: InkTextRole.bodyCompact,
                              color: theme.inkSecondary,
                            ),
                            const SizedBox(height: 6),
                            EngravedButton(
                              label: l10n.t(
                                L10nKey.settingsOtaTechnicalDetails,
                              ),
                              compact: true,
                              leading: BistreIcon(
                                _showOtaDetails
                                    ? BistreUiIcon.chevronUp
                                    : BistreUiIcon.chevronDown,
                                size: 12,
                                color: theme.inkSecondary,
                              ),
                              onPressed: () => setState(
                                () => _showOtaDetails = !_showOtaDetails,
                              ),
                            ),
                            if (_showOtaDetails) ...[
                              const SizedBox(height: 6),
                              InkText(
                                [otaDiag, ?ctrl.lastOtaDetail].join(': '),
                                role: InkTextRole.codeBlock,
                                color: theme.inkMuted,
                              ),
                            ],
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
                  description: l10n.t(L10nKey.settingsOtaRepoHint),
                  trailing: EngravedButton(
                    label: l10n.t(L10nKey.settingsAppearanceFontReset),
                    compact: true,
                    onPressed: () {
                      setState(() => _feedUrlCtrl.text = _kDefaultRepoSlug);
                      unawaited(
                        ctrl.updateSettings(
                          s.copyWith(otaFeedUrl: _kDefaultRepoSlug),
                          quiet: true,
                        ),
                      );
                    },
                  ),
                  bottom: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      QuillInput(
                        controller: _feedUrlCtrl,
                        focusNode: _feedUrlFocus,
                        placeholder: _kDefaultRepoSlug,
                        maxLines: 1,
                        submitOnEnter: false,
                        onSubmitted: () => unawaited(_saveFeedAndCheck()),
                      ),
                      const SizedBox(height: 4),
                      // A-W 7a: a browser downloads the feed file instead of showing it.
                      InkText(
                        l10n.t(L10nKey.settingsOtaFeedDownloadsHint),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // Section 2: Export & Import (Chats + Settings)
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsStorageExportImportTitle),
              subtitle: l10n.t(L10nKey.settingsStorageExportImportHint),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageChatsDataLabel),
                  bottom: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageExportCurrentMd),
                        compact: true,
                        onPressed: ctrl.activeThread == null
                            ? null
                            : () => unawaited(_exportCurrentChat('markdown')),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageExportCurrentJson),
                        compact: true,
                        onPressed: ctrl.activeThread == null
                            ? null
                            : () => unawaited(_exportCurrentChat('json')),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageExportAll),
                        compact: true,
                        onPressed: () => unawaited(_exportAllChats()),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageImportChats),
                        compact: true,
                        onPressed: () => unawaited(_importChats()),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageSettingsDataLabel),
                  bottom: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageExportSettings),
                        compact: true,
                        onPressed: () => unawaited(_exportSettings()),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageImportSettings),
                        compact: true,
                        onPressed: () => unawaited(_importSettings()),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s24),

            // Section 3: Local Storage, Backups & File Manager
            BistreSettingsSection(
              title: l10n.t(L10nKey.settingsStorageSectionTitle),
              subtitle: l10n.t(L10nKey.settingsEngineTelemetry),
              children: [
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageDataDir),
                  description: stats?.dataDir ?? '',
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (ctrl.isDevEnvironment)
                        WaxSealBadge(
                          label: l10n.t(L10nKey.settingsStorageDevBadge),
                          status: WaxSealStatus.warn,
                        ),
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
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (stats != null)
                        WaxSealBadge(
                          label: FolioController.formatBytes(stats.dbSizeBytes),
                          status: WaxSealStatus.neutral,
                        ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageBackupDb),
                        compact: true,
                        onPressed: () => unawaited(_backupDatabase()),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.settingsStorageCleanUnused),
                        compact: true,
                        onPressed: () =>
                            unawaited(ctrl.cleanUnusedStorageFiles()),
                      ),
                    ],
                  ),
                ),
                BistreSettingRow(
                  label: l10n.t(L10nKey.settingsStorageFileManagerTitle),
                  trailing: EngravedButton(
                    label: l10n.t(L10nKey.settingsStorageRefreshFiles),
                    compact: true,
                    onPressed: () => unawaited(ctrl.refreshStorageFiles()),
                  ),
                  bottom: ctrl.storageFiles.isEmpty
                      ? InkText(
                          l10n.t(L10nKey.settingsStorageFilesEmpty),
                          role: InkTextRole.captionMeta,
                          color: theme.inkMuted,
                        )
                      : ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 220),
                          child: SmoothScrollable(
                            builder: (_, scroll) => SingleChildScrollView(
                              controller: scroll,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final f in ctrl.storageFiles.take(80))
                                    Padding(
                                      padding: const EdgeInsetsDirectional.only(
                                        bottom: 4,
                                      ),
                                      child: FolioSurface(
                                        borderRadius: 7,
                                        padding:
                                            const EdgeInsetsDirectional.fromSTEB(
                                              10,
                                              5,
                                              6,
                                              5,
                                            ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: InkText(
                                                f.relPath,
                                                role: InkTextRole.codeBlock,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            InkText(
                                              FolioController.formatBytes(
                                                f.sizeBytes,
                                              ),
                                              role: InkTextRole.captionMeta,
                                              color: theme.inkMuted,
                                            ),
                                            if (f.deletable) ...[
                                              const SizedBox(width: 6),
                                              BistreIconButton(
                                                icon: BistreUiIcon.trash,
                                                size: 12,
                                                dimension: 24,
                                                semanticsLabel: l10n.t(
                                                  L10nKey.threadDelete,
                                                ),
                                                onPressed: () => unawaited(
                                                  ctrl.deleteStorageFile(
                                                    f.relPath,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const String _kDefaultRepoSlug = 'baros4294/bistre';
}
