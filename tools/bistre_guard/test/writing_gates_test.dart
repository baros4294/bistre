import 'dart:io';

import 'package:bistre_guard/writing_gates.dart';
import 'package:test/test.dart';

/// Writes [files] into a fresh temp repo, runs [gate], and returns its errors.
List<String> _run(
  void Function(Directory, List<String>, List<String>) gate,
  Map<String, String> files,
) {
  final root = Directory.systemTemp.createTempSync('bistre_writing_test_');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final e in files.entries) {
    File('${root.path}/${e.key}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(e.value);
  }
  final errors = <String>[];
  gate(root, files.keys.toList()..sort(), errors);
  return errors;
}

void main() {
  final dash = String.fromCharCode(0x2014);

  test('em dashes are rejected in every text file', () {
    final errors = _run(checkProse, <String, String>{
      'docs/a.md': 'One clause${dash}another.\n',
      'crates/a/src/lib.rs': '// fine - a hyphen\nlet x = "a${dash}b";\n',
      'l10n/catalog/en.bistre-l10n.json': '{"m": "x &mdash; y"}\n',
      'apps/bistre_app/assets/fonts/inter-regular.ttf': dash,
      'docs/ok.md': 'Plain words, a colon: and a comma.\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('docs/a.md:1 has an em dash'));
    expect(joined, contains('lib.rs:2 has an em dash'));
    expect(joined, contains('en.bistre-l10n.json:1 has an em dash'));
    expect(errors, hasLength(3), reason: joined);
  });

  test('stock filler words are rejected, fixtures are data', () {
    final errors = _run(checkProse, <String, String>{
      'docs/a.md': 'Switches models Seamlessly.\n',
      'apps/bistre_app/lib/a.dart':
          '/// A robust parser.\nfinal leverageRatio = 1;\n',
      'crates/bistre-core/fixtures/sse/a.sse': 'data: seamless\n',
      'docs/ok.md': 'Switches models without a restart.\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('docs/a.md:1 uses "Seamlessly"'));
    expect(joined, contains('a.dart:1 uses "robust"'));
    expect(errors, hasLength(2), reason: joined);
  });

  test('markdown stays light: no deep headings, no emoji', () {
    final errors = _run(checkProse, <String, String>{
      'docs/a.md': '# A\n## B\n### C\n#### D\n',
      'README.md': 'Fast ${String.fromCharCode(0x1F680)}\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('docs/a.md:4 nests a heading deeper than ###'));
    expect(joined, contains('README.md:1 has an emoji'));
    expect(errors, hasLength(2), reason: joined);
  });

  test(
    'markdown carries structure only: no emphasis, rules, or styled numbers',
    () {
      final errors = _run(checkProse, <String, String>{
        'docs/a.md': [
          '- **Label**: text',
          'An *italic* word and an _underscored_ one.',
          '---',
          'A budget of `<= 400 ms`.',
          'It works! Then...',
          'Callers MUST check `NOT NULL` first.',
          '- Label: `Inter` 400, `Medium` 500, `**/*.rs`, `a_b_c`, `x != y`, `a...b`.',
          '![logo](a.png) and snake_case_name.',
          '```',
          '**bold in a fence** is code!',
          '```',
        ].join('\n'),
        '.agents/skill.md': '---\nname: x\n---\nBody.\n',
      });
      final joined = errors.join('\n');
      expect(joined, contains('docs/a.md:1 uses bold or italics'));
      expect(joined, contains('docs/a.md:2 uses bold or italics'));
      expect(joined, contains('docs/a.md:3 has a horizontal rule'));
      expect(joined, contains('docs/a.md:4 puts a plain number in backticks'));
      expect(
        joined,
        contains('docs/a.md:5 has an exclamation mark or ellipsis'),
      );
      expect(joined, contains('docs/a.md:6 shouts a rule word'));
      expect(errors, hasLength(6), reason: joined);
    },
  );

  test('file and folder names are lowercase unless a tool needs the name', () {
    final errors = _run(checkFileNames, <String, String>{
      'docs/adr/ADR-0001-x.md': '',
      'docs/Design/notes.md': '',
      'apps/bistre_app/assets/fonts/Inter-Bold.ttf': '',
      'docs/my notes.md': '',
      'AGENTS.md': '',
      'README.md': '',
      'crates/a/Cargo.toml': '',
      'apps/bistre_app/windows/CMakeLists.txt': '',
      'apps/bistre_app/android/app/src/main/AndroidManifest.xml': '',
      'apps/bistre_app/android/app/src/main/kotlin/dev/a/MainActivity.kt': '',
      '.github/ISSUE_TEMPLATE/bug_report.yml': '',
      'docs/adr/adr-0002-y.md': '',
      'apps/bistre_app/lib/folio_shell.dart': '',
    });
    final joined = errors.join('\n');
    expect(joined, contains('docs/adr/ADR-0001-x.md'));
    expect(joined, contains('docs/Design/notes.md'));
    expect(joined, contains('Inter-Bold.ttf'));
    expect(joined, contains('docs/my notes.md'));
    expect(errors, hasLength(4), reason: joined);
  });

  test('AGENTS.md and tasks.md stay short; tasks.md holds open work only', () {
    final errors = _run(checkDocBudgets, <String, String>{
      'AGENTS.md': 'x' * (maxDocChars + 1),
      'tasks.md': '- [ ] open item\n- [v] finished item\n  - done: old evidence\n- [u] needs a device\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('AGENTS.md has ${maxDocChars + 1} characters'));
    expect(joined, contains('tasks.md:2 lists finished work'));
    expect(joined, contains('tasks.md:3 lists finished work'));
    expect(errors, hasLength(3), reason: joined);
  });
}
