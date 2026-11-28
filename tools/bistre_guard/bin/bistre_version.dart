import 'dart:io';

import 'package:bistre_guard/app_version.dart';

/// The app version tool (`just version`, `just bump`, and the version-bump workflow).
///
/// - `show`: prints `X.Y.Z`.
/// - `bump <patch|minor|major|X.Y.Z>`: writes the next version, or the given one when it
///   is above the current one.
/// - `above <base Cargo.toml> <base pubspec.yaml>`: makes the version higher than the base
///   branch's: a version already above it is kept, otherwise it becomes the next patch.
///   Prints the version written, or nothing when the files already hold it.
void main(List<String> args) {
  final root = Directory.current;
  try {
    final current = readAppVersion(root);
    switch (args) {
      case ['show']:
        stdout.writeln(current.semver);
      case ['bump', final part]:
        final next =
            AppVersion.parse(part, build: current.build + 1) ??
            current.bumped(part);
        if (next.compareTo(current) <= 0) {
          throw FormatException('$part is not above ${current.semver}');
        }
        writeAppVersion(root, next);
        stdout.writeln(next.semver);
      case ['above', final baseCargo, final basePubspec]:
        final base = parseAppVersion(
          File(baseCargo).readAsStringSync(),
          File(basePubspec).readAsStringSync(),
        );
        final next = versionAbove(current, base);
        if (next.toString() != current.toString()) {
          writeAppVersion(root, next);
          stdout.writeln(next.semver);
        }
      default:
        stderr.writeln(
          'usage: bistre_version show | bump <patch|minor|major|X.Y.Z> | above <Cargo.toml> <pubspec.yaml>',
        );
        exitCode = 64;
    }
  } on Object catch (e) {
    stderr.writeln('bistre_version: $e');
    exitCode = 1;
  }
}
