import 'dart:convert';
import 'dart:io';

/// Validation report for Bistre ICU localization catalogs.
class CatalogCheckResult {
  const CatalogCheckResult(this.errors);
  final List<String> errors;
  bool get isValid => errors.isEmpty;
}

/// Validates all `l10n/catalog/*.bistre-l10n.json` files against `en.bistre-l10n.json`
/// for filename parity, key parity, metadata integrity, balanced ICU braces,
/// placeholder name & type parity, and `max_chars`.
///
/// When [rustProtocolFile] is provided and exists, also verifies every Rust
/// `DiagnosticKey` (`diag.*`) is present in `en.bistre-l10n.json`.
/// When [dartOutFile] and [assetOutDir] are provided, also verifies generated
/// `l10n_keys.g.dart` and bundled `assets/l10n/` files are strictly up-to-date.
CatalogCheckResult validateCatalogDirectory(
  Directory catalogDir, {
  File? rustProtocolFile,
  File? dartOutFile,
  Directory? assetOutDir,
}) {
  final errors = <String>[];
  final masterFile = File('${catalogDir.path}/en.bistre-l10n.json');
  if (!masterFile.existsSync()) {
    return CatalogCheckResult(<String>[
      'Missing master catalog: ${masterFile.path}',
    ]);
  }

  final master = _parseCatalog(masterFile, errors);
  if (master == null) {
    return CatalogCheckResult(errors);
  }

  final files =
      catalogDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.bistre-l10n.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final masterEntries = master['entries'] as Map<String, dynamic>;
  for (final file in files) {
    final catalog = _parseCatalog(file, errors);
    if (catalog == null) continue;
    final locale = catalog['locale'] as String;
    final fileName = file.uri.pathSegments.last;
    final expectedFileName = '$locale.bistre-l10n.json';
    if (fileName != expectedFileName) {
      errors.add(
        '[$locale] Filename "$fileName" does not match locale "$locale" (expected "$expectedFileName")',
      );
    }

    final entries = catalog['entries'] as Map<String, dynamic>;

    for (final key in masterEntries.keys) {
      if (!entries.containsKey(key)) {
        errors.add('[$locale] Missing translation key: $key');
        continue;
      }
      final masterEntry = masterEntries[key] as Map<String, dynamic>;
      final entry = entries[key] as Map<String, dynamic>;
      _validateEntry(locale, key, masterEntry, entry, errors);
    }

    for (final extraKey in entries.keys) {
      if (!masterEntries.containsKey(extraKey)) {
        errors.add('[$locale] Extra key not present in en master: $extraKey');
      }
    }
  }

  if (rustProtocolFile != null) {
    _validateRustDiagnosticParity(rustProtocolFile, masterEntries, errors);
  }

  if (errors.isEmpty && dartOutFile != null && assetOutDir != null) {
    _validateGeneratedSync(
      catalogDir: catalogDir,
      masterEntries: masterEntries,
      catalogFiles: files,
      dartOutFile: dartOutFile,
      assetOutDir: assetOutDir,
      errors: errors,
    );
  }

  return CatalogCheckResult(errors);
}

void _validateRustDiagnosticParity(
  File rustProtocolFile,
  Map<String, dynamic> masterEntries,
  List<String> errors,
) {
  if (!rustProtocolFile.existsSync()) {
    errors.add('Missing Rust protocol file: ${rustProtocolFile.path}');
    return;
  }
  final source = rustProtocolFile.readAsStringSync();
  final matches = RegExp(r'#\[serde\(rename\s*=\s*"(diag\.[a-z0-9_.]+)"\)\]')
      .allMatches(source);
  final rustKeys = <String>{for (final m in matches) m.group(1)!};
  if (rustKeys.isEmpty) {
    errors.add(
      'Failed to discover any DiagnosticKey entries in ${rustProtocolFile.path}',
    );
    return;
  }
  for (final key in rustKeys) {
    if (!masterEntries.containsKey(key)) {
      errors.add(
        '[rust-parity] Rust DiagnosticKey "$key" is missing from en.bistre-l10n.json',
      );
    }
  }
}

void _validateGeneratedSync({
  required Directory catalogDir,
  required Map<String, dynamic> masterEntries,
  required List<File> catalogFiles,
  required File dartOutFile,
  required Directory assetOutDir,
  required List<String> errors,
}) {
  final expectedDart = _normalizeLf(_renderL10nKeysDart(masterEntries));
  if (!dartOutFile.existsSync()) {
    errors.add(
      '[i18n-sync] Missing generated file ${dartOutFile.path}; run `just i18n-gen`.',
    );
  } else {
    final actualDart = _normalizeLf(dartOutFile.readAsStringSync());
    if (actualDart != expectedDart) {
      errors.add(
        '[i18n-sync] Stale generated file ${dartOutFile.path}; run `just i18n-gen`.',
      );
    }
  }

  final locales = <String>[];
  for (final file in catalogFiles) {
    final name = file.uri.pathSegments.last;
    locales.add(name.replaceAll('.bistre-l10n.json', ''));
    final bundled = File('${assetOutDir.path}/$name');
    if (!bundled.existsSync()) {
      errors.add(
        '[i18n-sync] Missing bundled asset ${bundled.path}; run `just i18n-gen`.',
      );
      continue;
    }
    if (_normalizeLf(bundled.readAsStringSync()) !=
        _normalizeLf(file.readAsStringSync())) {
      errors.add(
        '[i18n-sync] Bundled asset ${bundled.path} is out of sync with ${catalogDir.path}/$name; run `just i18n-gen`.',
      );
    }
  }

  locales.sort();
  final expectedManifest = _normalizeLf(_renderManifestJson(locales));
  final manifestFile = File('${assetOutDir.path}/manifest.json');
  if (!manifestFile.existsSync()) {
    errors.add(
      '[i18n-sync] Missing ${manifestFile.path}; run `just i18n-gen`.',
    );
  } else if (_normalizeLf(manifestFile.readAsStringSync()) !=
      expectedManifest) {
    errors.add('[i18n-sync] Stale ${manifestFile.path}; run `just i18n-gen`.');
  }
}

Map<String, dynamic>? _parseCatalog(File file, List<String> errors) {
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      errors.add('${file.path}: root must be a JSON object');
      return null;
    }
    final locale = decoded['locale'];
    final direction = decoded['direction'];
    final entries = decoded['entries'];
    if (locale is! String || locale.length < 2) {
      errors.add('${file.path}: invalid "locale" field');
      return null;
    }
    if (direction != 'ltr' && direction != 'rtl') {
      errors.add('${file.path}: "direction" must be "ltr" or "rtl"');
      return null;
    }
    if (entries is! Map<String, dynamic> || entries.isEmpty) {
      errors.add('${file.path}: "entries" must be a non-empty object');
      return null;
    }
    return decoded;
  } catch (e) {
    errors.add('${file.path}: JSON parse error: $e');
    return null;
  }
}

void _validateEntry(
  String locale,
  String key,
  Map<String, dynamic> masterEntry,
  Map<String, dynamic> entry,
  List<String> errors,
) {
  final message = entry['message'];
  final context = entry['context'];
  final tone = entry['tone'];
  final maxChars = entry['max_chars'];
  final placeholders = entry['placeholders'];

  if (message is! String || message.trim().isEmpty) {
    errors.add('[$locale][$key] "message" must be a non-empty string');
    return;
  }
  if (context is! String || context.trim().length < 4) {
    errors.add('[$locale][$key] "context" must be >= 4 chars');
  }
  _validatePlainWords(locale, key, message, errors);
  if (tone != 'calm_editorial' &&
      tone != 'concise_action' &&
      tone != 'diagnostic') {
    errors.add('[$locale][$key] invalid "tone": $tone');
  }
  if (maxChars is! int || maxChars < 4) {
    errors.add('[$locale][$key] invalid "max_chars": $maxChars');
  } else if (!message.contains(', plural,') &&
      !message.contains(', select,') &&
      message.length > maxChars) {
    errors.add(
      '[$locale][$key] message length (${message.length}) exceeds max_chars ($maxChars)',
    );
  }
  if (placeholders is! Map<String, dynamic>) {
    errors.add('[$locale][$key] "placeholders" must be an object');
    return;
  }

  // Verify balanced ICU braces.
  var depth = 0;
  for (var i = 0; i < message.length; i++) {
    final ch = message[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth < 0) {
        errors.add(
          '[$locale][$key] unbalanced closing brace "}" in ICU message',
        );
        return;
      }
    }
  }
  if (depth != 0) {
    errors.add('[$locale][$key] unclosed opening brace "{" in ICU message');
    return;
  }

  // Verify declared placeholder names & types match master `en`.
  final masterPlaceholders =
      masterEntry['placeholders'] as Map<String, dynamic>;
  final masterKeys = masterPlaceholders.keys.toSet();
  final entryKeys = placeholders.keys.toSet();
  if (!masterKeys.containsAll(entryKeys) ||
      !entryKeys.containsAll(masterKeys)) {
    errors.add(
      '[$locale][$key] placeholder mismatch (expected $masterKeys, got $entryKeys)',
    );
  } else {
    for (final name in masterKeys) {
      final masterMeta = masterPlaceholders[name];
      final entryMeta = placeholders[name];
      if (masterMeta is Map<String, dynamic> &&
          entryMeta is Map<String, dynamic>) {
        final expectedType = masterMeta['type'];
        final actualType = entryMeta['type'];
        if (actualType != expectedType) {
          errors.add(
            '[$locale][$key] placeholder "$name" type mismatch (expected "$expectedType", got "$actualType")',
          );
        }
      } else {
        errors.add(
          '[$locale][$key] placeholder "$name" metadata must be an object',
        );
      }
    }
  }

  // Verify every placeholder referenced in message is declared.
  final referenced = _extractIcuVariables(message);
  for (final ref in referenced) {
    if (!placeholders.containsKey(ref)) {
      errors.add('[$locale][$key] undeclared ICU variable "{$ref}"');
    }
  }
  for (final decl in placeholders.keys) {
    if (!referenced.contains(decl)) {
      errors.add(
        '[$locale][$key] declared placeholder "$decl" not used in message',
      );
    }
  }
}

Set<String> _extractIcuVariables(String message) {
  final vars = <String>{};
  final regex = RegExp(r'\{([a-zA-Z_][a-zA-Z0-9_]*)\s*(?:,|\})');
  for (final m in regex.allMatches(message)) {
    final name = m.group(1);
    if (name != null) vars.add(name);
  }
  return vars;
}

/// Generates strongly typed Dart `L10nKey` enum + copies validated catalogs to Flutter assets.
void generateL10nArtifacts({
  required Directory catalogDir,
  required File dartOutFile,
  required Directory assetOutDir,
}) {
  final check = validateCatalogDirectory(catalogDir);
  if (!check.isValid) {
    throw StateError('Catalog validation failed:\n${check.errors.join('\n')}');
  }

  final masterFile = File('${catalogDir.path}/en.bistre-l10n.json');
  final master =
      jsonDecode(masterFile.readAsStringSync()) as Map<String, dynamic>;
  final entries = master['entries'] as Map<String, dynamic>;

  dartOutFile.parent.createSync(recursive: true);
  dartOutFile.writeAsStringSync(_renderL10nKeysDart(entries));

  assetOutDir.createSync(recursive: true);
  final catalogFiles = catalogDir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.bistre-l10n.json'),
  );
  final locales = <String>[];
  for (final file in catalogFiles) {
    final name = file.uri.pathSegments.last;
    final locale = name.replaceAll('.bistre-l10n.json', '');
    locales.add(locale);
    file.copySync('${assetOutDir.path}/$name');
  }
  locales.sort();
  File('${assetOutDir.path}/manifest.json')
      .writeAsStringSync(_renderManifestJson(locales));
}

String _renderL10nKeysDart(Map<String, dynamic> entries) {
  final sortedKeys = entries.keys.toList()..sort();
  final buf = StringBuffer()
    ..writeln('// GENERATED CODE — DO NOT MODIFY BY HAND.')
    ..writeln('// Source: l10n/catalog/en.bistre-l10n.json')
    ..writeln('// Run: dart run tools/bistre_i18n/bin/bistre_i18n.dart gen')
    ..writeln()
    ..writeln(
      '/// Compile-time checked localization keys backed by runtime ICU catalogs.',
    )
    ..writeln('enum L10nKey {');

  for (var i = 0; i < sortedKeys.length; i++) {
    final dotKey = sortedKeys[i];
    final enumName = _toCamelCase(dotKey);
    final sep = i == sortedKeys.length - 1 ? ';' : ',';
    final singleLine = "  $enumName('$dotKey')$sep";
    if (singleLine.length > 80) {
      buf
        ..writeln('  $enumName(')
        ..writeln("    '$dotKey',")
        ..writeln('  )$sep');
    } else {
      buf.writeln(singleLine);
    }
  }

  buf
    ..writeln()
    ..writeln('  const L10nKey(this.key);')
    ..writeln('  final String key;')
    ..writeln()
    ..writeln(
      '  static final Map<String, L10nKey> byKey = {for (final v in values) v.key: v};',
    )
    ..writeln('}');
  return buf.toString();
}

String _renderManifestJson(List<String> locales) {
  return '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{'locales': locales})}\n';
}

String _normalizeLf(String input) => input.replaceAll('\r\n', '\n');

String _toCamelCase(String dotKey) {
  final parts = dotKey.split(RegExp(r'[._-]+'));
  if (parts.isEmpty) return dotKey;
  final out = StringBuffer(parts.first.toLowerCase());
  for (var i = 1; i < parts.length; i++) {
    final p = parts[i];
    if (p.isEmpty) continue;
    out.write(p[0].toUpperCase());
    out.write(p.substring(1).toLowerCase());
  }
  return out.toString();
}

/// Internal or literary words that must never appear in UI copy, in any locale (AGENTS.md §7).
const List<String> bannedUiWords = <String>[
  'Inscribe',
  'Folio',
  'Passage',
  'Author',
  'Parchment',
  'Candlelight',
  'Guided Craft',
  'Unchained',
  'Wax Seal',
  'Quill',
];

/// English technical terms with a plain replacement (`docs/design/DESIGN.md` §9).
const Map<String, String> plainWordGlossary = <String, String>{
  'base url': 'Server URL',
  'endpoint': 'Server URL',
  'compaction': 'Shorten the conversation',
  'compact context': 'Shorten the conversation',
  'context window': 'Conversation limit',
  'steer': 'Send now',
  'reasoning effort': 'Thinking',
  'auto-retrying': 'Trying again',
};

void _validatePlainWords(
  String locale,
  String key,
  String message,
  List<String> errors,
) {
  for (final word in bannedUiWords) {
    if (RegExp('\\b${RegExp.escape(word)}\\b').hasMatch(message)) {
      errors.add('[$locale][$key] uses the banned UI word "$word"');
    }
  }
  if (locale != 'en') return;
  final lower = message.toLowerCase();
  plainWordGlossary.forEach((term, plain) {
    if (RegExp('\\b${RegExp.escape(term)}\\b').hasMatch(lower)) {
      errors.add('[$locale][$key] uses "$term"; say "$plain" (DESIGN.md §9)');
    }
  });
}
