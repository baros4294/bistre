import 'dart:io';

import 'package:bistre_i18n/bistre_i18n.dart';
import 'package:test/test.dart';

Directory _repoRoot() => Directory('../../l10n/catalog').existsSync()
    ? Directory('../..')
    : Directory('.');

void main() {
  test('repository catalogs, Rust DiagnosticKey parity, and generated assets pass all checks', () {
    final root = _repoRoot();
    final result = validateCatalogDirectory(
      Directory('${root.path}/l10n/catalog'),
      rustProtocolFile: File('${root.path}/crates/bistre-protocol/src/lib.rs'),
      dartOutFile: File(
        '${root.path}/apps/bistre_app/lib/l10n/l10n_keys.g.dart',
      ),
      assetOutDir: Directory('${root.path}/apps/bistre_app/assets/l10n'),
    );
    expect(result.isValid, isTrue, reason: result.errors.join('\n'));
  });

  test('validator rejects unbalanced ICU braces, placeholder type mismatches, and missing Rust keys', () {
    final tmp = Directory.systemTemp.createTempSync('bistre_i18n_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    File('${tmp.path}/en.bistre-l10n.json').writeAsStringSync('''
{
  "locale": "en",
  "direction": "ltr",
  "entries": {
    "demo.hello": {
      "message": "Hello {name}",
      "context": "Greeting label",
      "tone": "calm_editorial",
      "max_chars": 20,
      "placeholders": {
        "name": { "type": "string", "example": "Ada" }
      }
    }
  }
}
''');
    File('${tmp.path}/fr.bistre-l10n.json').writeAsStringSync('''
{
  "locale": "fr",
  "direction": "ltr",
  "entries": {
    "demo.hello": {
      "message": "Bonjour {name",
      "context": "Greeting label",
      "tone": "calm_editorial",
      "max_chars": 20,
      "placeholders": {
        "name": { "type": "int", "example": "1" }
      }
    }
  }
}
''');
    File('${tmp.path}/de.bistre-l10n.json').writeAsStringSync('''
{
  "locale": "de",
  "direction": "ltr",
  "entries": {
    "demo.hello": {
      "message": "Hallo {name}",
      "context": "Greeting label",
      "tone": "calm_editorial",
      "max_chars": 20,
      "placeholders": {
        "name": { "type": "int", "example": "1" }
      }
    }
  }
}
''');
    final fakeRust = File('${tmp.path}/protocol.rs')
      ..writeAsStringSync('#[serde(rename = "diag.missing.key")]');

    final res = validateCatalogDirectory(tmp, rustProtocolFile: fakeRust);
    expect(res.isValid, isFalse);
    final joined = res.errors.join('\n');
    expect(joined, contains('unclosed opening brace'));
    expect(joined, contains('type mismatch'));
    expect(joined, contains('diag.missing.key'));
  });
}
