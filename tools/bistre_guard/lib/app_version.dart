import 'dart:io';

/// The app version: `X.Y.Z` plus the Android build number (`versionCode`), which only grows.
///
/// It lives in two files a tool reads: `Cargo.toml` `[workspace.package] version` (Rust,
/// `CORE_VERSION`) and `apps/bistre_app/pubspec.yaml` `version: X.Y.Z+build` (Flutter, the
/// Windows resource, Android). Only [writeAppVersion] writes them; `just guard` keeps them equal.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, this.build);

  final int major;
  final int minor;
  final int patch;
  final int build;

  /// Parses `X.Y.Z`; null for anything else (a pre-release suffix included).
  static AppVersion? parse(String text, {int build = 0}) {
    final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(text.trim());
    if (m == null) return null;
    return AppVersion(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      build,
    );
  }

  String get semver => '$major.$minor.$patch';

  /// The next `patch`, `minor`, or `major` version, with the next build number.
  AppVersion bumped(String part) => switch (part) {
    'major' => AppVersion(major + 1, 0, 0, build + 1),
    'minor' => AppVersion(major, minor + 1, 0, build + 1),
    'patch' => AppVersion(major, minor, patch + 1, build + 1),
    _ => throw ArgumentError.value(part, 'part', 'patch, minor, or major'),
  };

  /// Compares `X.Y.Z` only; the build number never decides which release is newer.
  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    return 0;
  }

  @override
  String toString() => '$semver+$build';
}

final RegExp _workspaceSection = RegExp(
  r'\[workspace\.package\]([\s\S]*?)(?=\n\[|$)',
);
final RegExp _cargoVersionLine = RegExp(
  r'^version\s*=\s*"([^"]*)"',
  multiLine: true,
);
final RegExp _pubspecVersionLine = RegExp(
  r'^version:\s*(\S+?)(?:\+(\d+))?\s*$',
  multiLine: true,
);

/// Reads the version from `Cargo.toml` and `pubspec.yaml` texts; throws when either is
/// missing or they disagree on `X.Y.Z`.
AppVersion parseAppVersion(String cargoToml, String pubspec) {
  final section = _workspaceSection.firstMatch(cargoToml)?.group(1) ?? '';
  final cargo = _cargoVersionLine.firstMatch(section)?.group(1);
  final pub = _pubspecVersionLine.firstMatch(pubspec);
  if (cargo == null || pub == null) {
    throw const FormatException('no version in Cargo.toml or pubspec.yaml');
  }
  final build = int.parse(pub.group(2) ?? '0');
  final fromCargo = AppVersion.parse(cargo, build: build);
  if (fromCargo == null || cargo != pub.group(1)) {
    throw FormatException(
      'Cargo.toml $cargo and pubspec.yaml ${pub.group(1)} differ',
    );
  }
  return fromCargo;
}

File _cargo(Directory root) => File('${root.path}/Cargo.toml');
File _lock(Directory root) => File('${root.path}/Cargo.lock');
File _pubspec(Directory root) =>
    File('${root.path}/apps/bistre_app/pubspec.yaml');

AppVersion readAppVersion(Directory root) => parseAppVersion(
  _cargo(root).readAsStringSync(),
  _pubspec(root).readAsStringSync(),
);

/// Writes [next] to `Cargo.toml`, the workspace's own packages in `Cargo.lock`, and
/// `pubspec.yaml`.
void writeAppVersion(Directory root, AppVersion next) {
  final current = readAppVersion(root);
  final cargo = _cargo(root).readAsStringSync();
  final section = _workspaceSection.firstMatch(cargo)!;
  final newSection = section
      .group(1)!
      .replaceFirst(_cargoVersionLine, 'version = "${next.semver}"');
  _cargo(root).writeAsStringSync(
    cargo.replaceRange(
      section.start,
      section.end,
      '[workspace.package]$newSection',
    ),
  );

  final lock = _lock(root);
  if (lock.existsSync()) {
    final own = RegExp(
      r'(name = "bistre-[a-z]+"\nversion = )"' +
          RegExp.escape(current.semver) +
          '"',
    );
    lock.writeAsStringSync(
      lock.readAsStringSync().replaceAllMapped(
        own,
        (m) => '${m.group(1)}"${next.semver}"',
      ),
    );
  }

  final pubspec = _pubspec(root).readAsStringSync();
  _pubspec(root).writeAsStringSync(
    pubspec.replaceFirst(_pubspecVersionLine, 'version: $next'),
  );

  // Keep README direct download URLs and version badge aligned with the bumped release.
  final readme = File('${root.path}/README.md');
  if (readme.existsSync()) {
    final text = readme.readAsStringSync();
    final updated = text
        .replaceAll(
          '/releases/download/v${current.semver}/bistre-v${current.semver}-',
          '/releases/download/v${next.semver}/bistre-v${next.semver}-',
        )
        .replaceAll(
          '/releases/download/v${current.semver}/sha256sums-',
          '/releases/download/v${next.semver}/sha256sums-',
        )
        .replaceAll('version-v${current.semver}-', 'version-v${next.semver}-')
        .replaceAll(
          'alt="Version v${current.semver}"',
          'alt="Version v${next.semver}"',
        );
    if (updated != text) {
      readme.writeAsStringSync(updated);
    }
  }
}

/// The version a pull request ships: its own when above [base] (a jump set by hand), else
/// the patch after [base]. The build number always ends above both.
AppVersion versionAbove(AppVersion current, AppVersion base) {
  final build = (current.build > base.build ? current.build : base.build) + 1;
  if (current.compareTo(base) > 0) {
    return current.build > base.build
        ? current
        : AppVersion(current.major, current.minor, current.patch, build);
  }
  return AppVersion(base.major, base.minor, base.patch + 1, build);
}
