import 'dart:io';

import 'package:bistre_i18n/bistre_i18n.dart';

void main(List<String> args) {
  final cmd = args.isEmpty ? 'check' : args.first;
  final repoRoot = _findRepoRoot(Directory.current);
  final catalogDir = Directory('${repoRoot.path}/l10n/catalog');
  final rustProtocol = File(
    '${repoRoot.path}/crates/bistre-protocol/src/lib.rs',
  );
  final dartOut = File(
    '${repoRoot.path}/apps/bistre_app/lib/l10n/l10n_keys.g.dart',
  );
  final assetOut = Directory('${repoRoot.path}/apps/bistre_app/assets/l10n');

  switch (cmd) {
    case 'check':
      final res = validateCatalogDirectory(
        catalogDir,
        rustProtocolFile: rustProtocol,
        dartOutFile: dartOut,
        assetOutDir: assetOut,
      );
      if (!res.isValid) {
        for (final err in res.errors) {
          stderr.writeln('ERROR: $err');
        }
        exit(1);
      }
      stdout.writeln(
        'OK: all ICU localization catalogs, Rust DiagnosticKey parity, and generated assets passed validation.',
      );
    case 'gen':
      generateL10nArtifacts(
        catalogDir: catalogDir,
        dartOutFile: dartOut,
        assetOutDir: assetOut,
      );
      stdout.writeln('GENERATED: ${dartOut.path} and ${assetOut.path}');
    default:
      stderr.writeln('Usage: dart run bistre_i18n <check|gen>');
      exit(2);
  }
}

Directory _findRepoRoot(Directory start) {
  var dir = start.absolute;
  while (true) {
    if (Directory('${dir.path}/l10n/catalog').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return start.absolute;
    }
    dir = parent;
  }
}
