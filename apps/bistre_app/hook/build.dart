import 'dart:io';

import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

/// Android `aarch64` rustflags kept identical to `.cargo/config.toml`.
const List<String> androidRustflags = <String>[
  '-C force-unwind-tables=no',
  '-C link-arg=-Wl,--gc-sections',
  '-C link-arg=-Wl,--icf=safe',
  '-C link-arg=-Wl,-z,max-page-size=16384',
];

/// Size-focused C flags for the bundled SQLite amalgamation on Android.
const List<String> androidSqliteCflags = <String>[
  '-Oz',
  '-fno-unwind-tables',
  '-fno-asynchronous-unwind-tables',
  '-DSQLITE_OMIT_LOAD_EXTENSION',
  '-DSQLITE_OMIT_DEPRECATED',
  '-DSQLITE_OMIT_UTF16',
  '-DSQLITE_OMIT_TRACE',
  '-DSQLITE_OMIT_PROGRESS_CALLBACK',
  '-DSQLITE_OMIT_TCL_VARIABLE',
];

void main(List<String> args) async {
  await build(args, (BuildInput input, BuildOutputBuilder output) async {
    final extraEnv = <String, String>{};
    // Share the workspace `target/` directory with Cargo & `Swatinem/rust-cache` so
    // `flutter test`, `flutter build`, and `bistre-daemon` reuse compiled Rust rlibs instead
    // of rebuilding ~280 crates from scratch inside `.dart_tool/hooks_runner/`.
    final existingTargetDir = Platform.environment['CARGO_TARGET_DIR']?.trim();
    if (existingTargetDir == null || existingTargetDir.isEmpty) {
      final repoRoot = Directory.fromUri(input.packageRoot.resolve('../..'));
      if (File('${repoRoot.path}${Platform.pathSeparator}Cargo.toml')
          .existsSync()) {
        extraEnv['CARGO_TARGET_DIR'] =
            '${repoRoot.path}${Platform.pathSeparator}target';
      }
    }

    if (_isAndroidBuild(input)) {
      // Size-focused release profile overrides for Android arm64 APK builds (Spec 11).
      extraEnv['CARGO_PROFILE_RELEASE_OPT_LEVEL'] = 'z';
      extraEnv['CARGO_PROFILE_RELEASE_LTO'] = 'fat';
      extraEnv['CARGO_PROFILE_RELEASE_CODEGEN_UNITS'] = '1';
      extraEnv['CARGO_PROFILE_RELEASE_PANIC'] = 'abort';
      extraEnv['CARGO_PROFILE_RELEASE_STRIP'] = 'symbols';
    }
    final androidNdk = _discoverAndroidNdk();
    if (androidNdk != null && androidNdk.isNotEmpty) {
      extraEnv['ANDROID_NDK_HOME'] = androidNdk;
      // Guarantee 16 KB ELF alignment and NDK r28+/r30 clang/ar for bundled C crates (rusqlite).
      final hostTag = Platform.isWindows
          ? 'windows-x86_64'
          : Platform.isMacOS
          ? 'darwin-x86_64'
          : 'linux-x86_64';
      final ext = Platform.isWindows ? '.cmd' : '';
      final exeExt = Platform.isWindows ? '.exe' : '';
      final llvmBin =
          '$androidNdk${Platform.pathSeparator}toolchains${Platform.pathSeparator}llvm'
          '${Platform.pathSeparator}prebuilt${Platform.pathSeparator}$hostTag${Platform.pathSeparator}bin';
      final clang =
          '$llvmBin${Platform.pathSeparator}aarch64-linux-android29-clang$ext';
      final ar = '$llvmBin${Platform.pathSeparator}llvm-ar$exeExt';
      if (File(clang).existsSync()) {
        extraEnv['CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER'] = clang;
        extraEnv['CC_aarch64_linux_android'] = clang;
      }
      if (File(ar).existsSync()) {
        extraEnv['AR_aarch64_linux_android'] = ar;
      }
      // Mirrors `.cargo/config.toml` (env RUSTFLAGS override config rustflags).
      extraEnv['CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS'] =
          androidRustflags.join(' ');
      // Shrink bundled SQLite C objects (Spec 11 §2).
      extraEnv['CFLAGS_aarch64_linux_android'] = androidSqliteCflags.join(' ');
    }

    // Dart's hooks_runner strips LIB/INCLUDE on Windows. Reconstruct them from portable MSVC/Windows Kits on PATH if missing.
    if (Platform.isWindows) {
      _populateWindowsMsvcEnv(extraEnv);
    }

    await FlutterRustBridgeNativeAssetsBuilder(
      assetName: 'bridge/frb_generated.io.dart',
      cratePath: '../../crates/bistre-ffi',
      // Same as every other Cargo command here: build exactly the reviewed Cargo.lock.
      extraCargoBuildArgs: const <String>['--locked'],
      extraCargoEnvironmentVariables: extraEnv,
    ).run(input: input, output: output);
  });
}

bool _isAndroidBuild(BuildInput input) {
  final cfg = input.json['config'];
  if (cfg is! Map) return false;
  final ext = cfg['extensions'];
  if (ext is Map) {
    final codeAssets = ext['code_assets'];
    if (codeAssets is Map && codeAssets['target_os'] == 'android') {
      return true;
    }
  }
  final code = cfg['code'];
  return code is Map && code['target_os'] == 'android';
}

String? _discoverAndroidNdk() {
  for (final key in const <String>['ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT']) {
    final value = Platform.environment[key];
    if (value != null && value.isNotEmpty && Directory(value).existsSync()) {
      return value;
    }
  }
  final sdkRoot =
      Platform.environment['ANDROID_HOME'] ??
      Platform.environment['ANDROID_SDK_ROOT'];
  if (sdkRoot == null || sdkRoot.isEmpty) return null;
  final ndkParent = Directory('$sdkRoot${Platform.pathSeparator}ndk');
  if (!ndkParent.existsSync()) return null;

  final gradleFile = File('android/app/build.gradle.kts');
  if (gradleFile.existsSync()) {
    final match = RegExp(r'ndkVersion\s*=\s*"([^"]+)"')
        .firstMatch(gradleFile.readAsStringSync());
    final pinned = match?.group(1);
    if (pinned != null) {
      final candidate = Directory(
        '${ndkParent.path}${Platform.pathSeparator}$pinned',
      );
      if (candidate.existsSync()) return candidate.path;
    }
  }

  final versions = ndkParent.listSync().whereType<Directory>().toList()
    ..sort((a, b) => b.path.compareTo(a.path));
  return versions.isEmpty ? null : versions.first.path;
}

void _populateWindowsMsvcEnv(Map<String, String> extraEnv) {
  final existingLib = Platform.environment['LIB'];
  final existingInclude = Platform.environment['INCLUDE'];
  if (existingLib != null && existingLib.isNotEmpty) {
    extraEnv['LIB'] = existingLib;
  }
  if (existingInclude != null && existingInclude.isNotEmpty) {
    extraEnv['INCLUDE'] = existingInclude;
  }
  if (extraEnv.containsKey('LIB') && extraEnv.containsKey('INCLUDE')) {
    return;
  }

  final pathEntries = (Platform.environment['PATH'] ?? '').split(';');
  String? msvcVersionDir;
  String? winKitRoot;

  for (final raw in pathEntries) {
    final normalized = raw.trim().replaceAll('/', '\\');
    final lower = normalized.toLowerCase();
    final vcIdx = lower.indexOf('\\vc\\tools\\msvc\\');
    if (vcIdx != -1 && msvcVersionDir == null) {
      final afterVc = normalized.substring(
        vcIdx + '\\vc\\tools\\msvc\\'.length,
      );
      final ver = afterVc.split('\\').first;
      if (ver.isNotEmpty) {
        msvcVersionDir =
            '${normalized.substring(0, vcIdx)}\\VC\\Tools\\MSVC\\$ver';
        final candidateKit =
            '${normalized.substring(0, vcIdx)}\\Windows Kits\\10';
        if (Directory(candidateKit).existsSync()) {
          winKitRoot = candidateKit;
        }
      }
    }
    final kitIdx = lower.indexOf('\\windows kits\\10\\');
    if (kitIdx != -1 && winKitRoot == null) {
      winKitRoot = '${normalized.substring(0, kitIdx)}\\Windows Kits\\10';
    }
  }

  if (msvcVersionDir == null) return;

  final libs = <String>['$msvcVersionDir\\lib\\x64'];
  final includes = <String>['$msvcVersionDir\\include'];

  if (winKitRoot != null) {
    final libRoot = Directory('$winKitRoot\\Lib');
    if (libRoot.existsSync()) {
      final versions = libRoot.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (versions.isNotEmpty) {
        final v = versions.first.path;
        libs.addAll(<String>['$v\\um\\x64', '$v\\ucrt\\x64']);
      }
    }
    final incRoot = Directory('$winKitRoot\\Include');
    if (incRoot.existsSync()) {
      final versions = incRoot.listSync().whereType<Directory>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (versions.isNotEmpty) {
        final v = versions.first.path;
        includes.addAll(<String>['$v\\ucrt', '$v\\um', '$v\\shared']);
      }
    }
  }

  extraEnv.putIfAbsent('LIB', () => libs.join(';'));
  extraEnv.putIfAbsent('INCLUDE', () => includes.join(';'));
}
