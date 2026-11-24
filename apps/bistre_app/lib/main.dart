import 'dart:async';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app_appearance.dart';
import 'bridge/bistre_engine.dart';
import 'design/bistre_theme.dart';
import 'features/shell/folio_controller.dart';
import 'features/shell/folio_shell_screen.dart';
import 'l10n/bistre_localizations.dart';
import 'l10n/l10n_keys.g.dart';
import 'platform/desktop_host.dart';
import 'platform/host_memory.dart';

/// Resolves the isolated local data directory for SQLite + encrypted `SecretVault`:
/// 1. Explicit `BISTRE_DATA_DIR` environment variable override (when set)
/// 2. Debug / dev builds: `<repo>/.bistre-dev/` (strictly isolated from real user data;
///    falls back to `%LOCALAPPDATA%\Bistre-Dev` if launched detached outside repo)
/// 3. Release / production builds: OS application data directory (`%LOCALAPPDATA%\Bistre` on Windows)
Future<(Directory, bool)> resolveBistreDataDir() async {
  final envOverride = Platform.environment['BISTRE_DATA_DIR']?.trim() ?? '';
  if (envOverride.isNotEmpty) {
    final dir = Directory(envOverride);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return (dir, kDebugMode || envOverride.contains('.bistre-dev'));
  }

  if (kDebugMode) {
    final repoRoot =
        _findRepoRoot(Directory.current) ??
        _findRepoRoot(File(Platform.resolvedExecutable).parent);
    if (repoRoot != null) {
      final devDir = Directory('${repoRoot.path}/.bistre-dev');
      if (!devDir.existsSync()) devDir.createSync(recursive: true);
      return (devDir, true);
    }
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
      if (localAppData.isNotEmpty) {
        final devDir = Directory('$localAppData\\Bistre-Dev');
        if (!devDir.existsSync()) devDir.createSync(recursive: true);
        return (devDir, true);
      }
    }
  }

  if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    if (localAppData.isNotEmpty) {
      final prodDir = Directory('$localAppData\\Bistre');
      if (!prodDir.existsSync()) prodDir.createSync(recursive: true);
      return (prodDir, false);
    }
  }

  final supportDir = await getApplicationSupportDirectory();
  final dataDir = Directory('${supportDir.path}/bistre_data');
  if (!dataDir.existsSync()) {
    dataDir.createSync(recursive: true);
  }
  return (dataDir, kDebugMode);
}

Directory? _findRepoRoot(Directory start) {
  var dir = start.absolute;
  for (var depth = 0; depth < 12; depth++) {
    if (File('${dir.path}/AGENTS.md').existsSync() &&
        File('${dir.path}/Cargo.toml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

Future<void> main() async {
  final bootClock = Stopwatch()..start();
  WidgetsFlutterBinding.ensureInitialized();
  // Bound decoded image memory (16 MiB normal; lowered to 8 MiB on < 4 GB hosts).
  PaintingBinding.instance.imageCache
    ..maximumSize = 128
    ..maximumSizeBytes = 16 << 20;
  unawaited(configureGpuResourceCacheCap(lowMemory: false));

  final l10nController = await BistreLocalizationController.loadBundled();
  final (dataDir, isDevEnv) = await resolveBistreDataDir();

  final gateway = FrbBistreEngineGateway();
  final folioController = FolioController(
    gateway: gateway,
    defaultThreadTitle: l10nController.t(L10nKey.shellThreadDefaultTitle),
    onLocaleSynced: l10nController.setLocale,
    isDevEnvironment: isDevEnv,
  );
  final bootstrapDone = folioController.bootstrap(dataDir.path);

  // Opt-in perf probe for `just perf` (Spec 11 §5): metrics are appended as `key=value` lines to
  // the file named by `BISTRE_PERF_PROBE`. Never set in normal use.
  final probePath = Platform.environment['BISTRE_PERF_PROBE']?.trim() ?? '';
  void probe(String line) {
    if (probePath.isEmpty) return;
    try {
      File(probePath).writeAsStringSync('$line\n', mode: FileMode.append);
    } on FileSystemException {
      // Probe output is best-effort; a missing directory must never affect the app.
    }
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    final firstFrameMs = bootClock.elapsedMilliseconds;
    final rss = ProcessInfo.currentRss;
    debugPrint(
      '[BISTRE_PERF] first_frame_ms=$firstFrameMs rss_bytes=$rss data_dir=${dataDir.path} dev=$isDevEnv',
    );
    probe('first_frame_ms=$firstFrameMs');
    probe('first_frame_rss_bytes=$rss');
  });
  unawaited(
    bootstrapDone.then((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        probe('chat_ready_ms=${bootClock.elapsedMilliseconds}');
        probe('chat_count=${folioController.threads.length}');
        if (probePath.isNotEmpty) {
          // Wait one settle beat (500 ms) after chat_ready paint before sampling 10 s of true
          // idle frames (Spec 11: 0 wakeups/sec once settled) plus frame-timing percentiles.
          Timer(const Duration(milliseconds: 500), () {
            var idleFrames = 0;
            final vsyncOverheadUs = <int>[];
            final buildUs = <int>[];
            final rasterUs = <int>[];
            void countFrames(List<FrameTiming> timings) {
              idleFrames += timings.length;
              for (final t in timings) {
                vsyncOverheadUs.add(t.vsyncOverhead.inMicroseconds);
                buildUs.add(t.buildDuration.inMicroseconds);
                rasterUs.add(t.rasterDuration.inMicroseconds);
              }
            }

            WidgetsBinding.instance.addTimingsCallback(countFrames);
            Timer(const Duration(seconds: 10), () {
              WidgetsBinding.instance.removeTimingsCallback(countFrames);
              probe('idle_frames=$idleFrames');
              probe('idle_rss_bytes=${ProcessInfo.currentRss}');
              if (buildUs.isNotEmpty) {
                vsyncOverheadUs.sort();
                buildUs.sort();
                rasterUs.sort();
                double p95Ms(List<int> xs) =>
                    xs[((xs.length - 1) * 0.95).round()] / 1000.0;
                probe(
                  'vsync_overhead_p95_ms=${p95Ms(vsyncOverheadUs).toStringAsFixed(2)}',
                );
                probe('build_p95_ms=${p95Ms(buildUs).toStringAsFixed(2)}');
                probe('raster_p95_ms=${p95Ms(rasterUs).toStringAsFixed(2)}');
              }
            });
          });
        }
      });
      WidgetsBinding.instance.scheduleFrame();
    }),
  );

  runApp(
    BistreApp(l10nController: l10nController, folioController: folioController),
  );
}

/// Pure `WidgetsApp` root shell — zero Material or Cupertino UI library dependencies (ADR-0001).
class BistreApp extends StatefulWidget {
  const BistreApp({
    super.key,
    required this.l10nController,
    required this.folioController,
  });

  final BistreLocalizationController l10nController;
  final FolioController folioController;

  @override
  State<BistreApp> createState() => _BistreAppState();
}

class _BistreAppState extends State<BistreApp> with WidgetsBindingObserver {
  BistreThemeData? _lastSyncedDesktopTheme;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncSystemBrightness();
    BistreDesktopHost.attachSystemThemeListener(_syncSystemBrightness);
    BistreDesktopHost.attachWindowBoundsListener(_onWindowBoundsChanged);
    widget.folioController.addListener(_syncWindowTitle);
    _syncWindowTitle();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BistreDesktopHost.detachSystemThemeListener(_syncSystemBrightness);
    BistreDesktopHost.detachWindowBoundsListener(_onWindowBoundsChanged);
    widget.folioController.removeListener(_syncWindowTitle);
    super.dispose();
  }

  void _onWindowBoundsChanged(DesktopWindowBounds bounds) {
    unawaited(widget.folioController.persistWindowBounds(bounds));
  }

  void _syncWindowTitle() =>
      _scheduleWindowTitle(_windowTitle(widget.folioController));

  @override
  void didChangePlatformBrightness() {
    _syncSystemBrightness();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.folioController.persistCurrentWindowBounds());
      unawaited(widget.folioController.flushPendingDeletes());
    }
  }

  void _syncSystemBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    widget.folioController.setSystemBrightness(brightness == Brightness.dark);
  }

  String? _lastWindowTitle;
  AppAppearance? _themeKey;
  BistreThemeData? _theme;

  /// Theme resolution runs contrast adjustment; reuse it until the appearance changes.
  BistreThemeData _themeFor(AppAppearance look) {
    final cached = _theme;
    if (cached != null && _themeKey == look) return cached;
    _themeKey = look;
    return _theme = BistreThemeData.resolve(
      isDark: look.isDark,
      themeId: look.themeId,
      accentPreset: look.accentPreset,
      customAccentHex: look.customAccentHex,
      typography: look.typography,
      reducedEffects: look.reducedEffects,
    );
  }

  /// `<chat title> — Bistre`, `Settings — Bistre`, or a live `Replying · …` caption.
  String _windowTitle(FolioController ctrl) {
    final l10n = widget.l10nController;
    if (ctrl.settingsOpen) return l10n.t(L10nKey.appWindowTitleSettings);
    final title = ctrl.activeThread?.title.trim() ?? '';
    if (title.isEmpty) return l10n.t(L10nKey.appTitle);
    return l10n.t(
      ctrl.isStreaming
          ? L10nKey.appWindowTitleReplying
          : L10nKey.appWindowTitle,
      <String, Object?>{'title': title},
    );
  }

  void _scheduleWindowTitle(String title) {
    if (_lastWindowTitle == title) return;
    _lastWindowTitle = title;
    unawaited(BistreDesktopHost.setWindowTitle(title));
  }

  void _scheduleDesktopThemeSync(BistreThemeData theme) {
    if (_lastSyncedDesktopTheme == theme) return;
    _lastSyncedDesktopTheme = theme;
    unawaited(
      BistreDesktopHost.syncWindowTheme(
        isDark: theme.isDark,
        captionColor: theme.bgCanvas,
        textColor: theme.inkPrimary,
        borderColor: theme.windowBorder,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BistreLocalizations(
      controller: widget.l10nController,
      // Rebuild the app only for appearance or locale changes; the shell listens to the
      // controller itself.
      child: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          widget.l10nController,
          widget.folioController.appearance,
        ]),
        builder: (context, _) {
          final ctrl = widget.folioController;
          final look = ctrl.appearance.value;
          final typography = look.typography;
          final themeData = _themeFor(look);
          _scheduleDesktopThemeSync(themeData);
          _syncWindowTitle();

          return BistreTheme(
            data: themeData,
            child: WidgetsApp(
              title: widget.l10nController.t(L10nKey.appTitle),
              color: themeData.accentWax,
              textStyle: BistreTypography.bodyProse(
                themeData.inkPrimary,
                config: typography,
              ),
              debugShowCheckedModeBanner: false,
              pageRouteBuilder:
                  <T>(RouteSettings settings, WidgetBuilder builder) {
                    return PageRouteBuilder<T>(
                      settings: settings,
                      transitionDuration: BistreMotion.instant,
                      reverseTransitionDuration: BistreMotion.instant,
                      pageBuilder: (ctx, _, _) => builder(ctx),
                    );
                  },
              builder: (context, child) {
                final app = Directionality(
                  textDirection: widget.l10nController.textDirection,
                  child: child ?? const SizedBox.shrink(),
                );
                // The in-app Reduce motion setting applies everywhere, like the OS one.
                if (!look.reduceMotion) return app;
                return MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: true),
                  child: app,
                );
              },
              home: FolioShellScreen(controller: ctrl),
            ),
          );
        },
      ),
    );
  }
}
