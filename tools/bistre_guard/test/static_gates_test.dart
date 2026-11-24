import 'dart:io';

import 'package:bistre_guard/static_gates.dart';
import 'package:test/test.dart';

/// Writes [files] into a fresh temp repo and returns (root, sorted relative paths).
(Directory, List<String>) _repo(Map<String, Object> files) {
  final root = Directory.systemTemp.createTempSync('bistre_gates_test_');
  addTearDown(() => root.deleteSync(recursive: true));
  for (final e in files.entries) {
    final f = File('${root.path}/${e.key}')..parent.createSync(recursive: true);
    final v = e.value;
    if (v is String) {
      f.writeAsStringSync(v);
    } else {
      f.writeAsBytesSync(v as List<int>);
    }
  }
  return (root, files.keys.toList()..sort());
}

List<String> _run(
  void Function(Directory, List<String>, List<String>) gate,
  Map<String, Object> files,
) {
  final (root, rels) = _repo(files);
  final errors = <String>[];
  gate(root, rels, errors);
  return errors;
}

void main() {
  test('process-spawn gate rejects raw Command::new outside the helper', () {
    final errors = _run(checkProcessSpawnAndMmap, <String, Object>{
      'crates/bistre-core/src/tools.rs': 'let c = Command::new("sh");\n',
      'crates/bistre-core/src/process_util.rs':
          'let c = Command::new(program);\n',
      'crates/bistre-core/src/ok.rs': 'let c = crate::process_util::no_window_command("git");\n// Command::new( in a comment\n',
    });
    expect(errors, hasLength(1));
    expect(errors.single, contains('tools.rs:1'));
  });

  test('mmap gate rejects memmap deps and memory-mapped search', () {
    final errors = _run(checkProcessSpawnAndMmap, <String, Object>{
      'crates/bistre-core/Cargo.toml': '[dependencies]\nmemmap2 = "0.9"\n',
      'crates/bistre-core/src/a.rs':
          'let b = SearcherBuilder::new().memory_map(choice);\n',
      'crates/bistre-core/src/b.rs': 'let s = Searcher::new();\n',
    });
    expect(errors.join('\n'), contains('Cargo.toml declares a memmap'));
    expect(errors.join('\n'), contains('a.rs:1'));
    expect(errors.join('\n'), isNot(contains('b.rs')));
  });

  test('encoding gate rejects BOM, non-ASCII .ps1, and LF-only .rc', () {
    final errors = _run(checkEncodingHygiene, <String, Object>{
      'docs/bom.md': <int>[0xEF, 0xBB, 0xBF, 0x23, 0x0A],
      'scripts/build.ps1': 'Write-Output "caf\u00e9"\n',
      'scripts/ok.ps1': 'Write-Output "ok"\n',
      'apps/bistre_app/windows/runner/Runner.rc': 'a\nb\n',
      'apps/bistre_app/windows/runner/Good.rc': 'a\r\nb\r\n',
      'docs/plain.md': '# ok\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('bom.md starts with a UTF-8 BOM'));
    expect(joined, contains('build.ps1 must be ASCII-only'));
    expect(joined, contains('Runner.rc must use CRLF'));
    expect(joined, isNot(contains('ok.ps1')));
    expect(joined, isNot(contains('Good.rc')));
    expect(errors, hasLength(3));
  });

  test('secrets & artifacts gate rejects keys, keystores, binaries, and >1 MiB files', () {
    final fakeKey = <String>['sk-', 'ant-', 'A' * 30].join();
    final errors = _run(checkSecretsAndArtifacts, <String, Object>{
      'release.jks': <int>[1, 2, 3],
      'apps/bistre_app/android/local.properties': 'sdk.dir=x\n',
      'notes.txt': 'key = $fakeKey\n',
      'docs/mention.md': 'Never commit `sk-ant-` keys.\n',
      'bin/tool.exe': <int>[0x4d, 0x5a],
      'docs/huge.json': List<int>.filled(maxTrackedFileBytes + 1, 0x20),
      'apps/bistre_app/assets/fonts/Big.ttf': List<int>.filled(
        maxTrackedFileBytes + 1,
        0,
      ),
    });
    final joined = errors.join('\n');
    expect(joined, contains('release.jks is a secret-bearing file'));
    expect(joined, contains('local.properties is a secret-bearing file'));
    expect(joined, contains('notes.txt contains a credential'));
    expect(joined, contains('tool.exe is a compiled artifact'));
    expect(joined, contains('huge.json'));
    expect(joined, isNot(contains('mention.md')));
    expect(joined, isNot(contains('Big.ttf')));
  });

  test(
    'model & brand gate scans runtime code including presets and skips tests',
    () {
      final brand = <String>['Sam', 'sung'].join();
      final errors = _run(checkHardcodedModelsAndBrands, <String, Object>{
        'crates/bistre-core/src/providers.rs': 'const M: &str = "gpt-4.1";\n#[cfg(test)]\nmod tests { const T: &str = "gpt-4.1"; }\n',
        'apps/bistre_app/lib/features/chat/view.dart':
            "const workaround = '$brand';\n",
        'apps/bistre_app/lib/features/settings/provider_presets.dart':
            "const m = 'gpt-4o-mini';\n",
        'crates/bistre-core/src/lib.rs': '#[cfg(test)]\nmod tests;\n',
        'crates/bistre-core/src/tests.rs': 'const T: &str = "gpt-4.1";\n',
        'crates/bistre-storage/src/tests.rs': 'const T: &str = "gpt-4.1";\n',
        'README.md': 'Works with any model your provider lists.\n',
        'docs/specs/notes.md': 'Benchmarked with "gpt-4.1".\n',
      });
      final joined = errors.join('\n');
      expect(joined, contains('providers.rs:1 hardcodes a model ID'));
      expect(joined, contains('view.dart:1 names OEM brand'));
      expect(joined, contains('provider_presets.dart:1 hardcodes a model ID'));
      expect(joined, contains('bistre-storage/src/tests.rs:1 hardcodes'));
      expect(errors, hasLength(4));
    },
  );

  test('line cap rejects oversized files and skips generated bindings', () {
    final (root, rels) = _repo(<String, Object>{
      'crates/a/src/big.rs': 'x\n' * (maxSourceLines + 1),
      'crates/a/src/frb_generated.rs': 'x\n' * (maxSourceLines + 10),
      'apps/bistre_app/lib/bridge/api/story.dart':
          'x\n' * (maxSourceLines + 10),
      'apps/bistre_app/lib/small.dart': 'x\n',
    });
    final errors = <String>[];
    checkSourceLineCap(root, rels, errors);
    expect(errors, hasLength(1));
    expect(errors.single, contains('big.rs has ${maxSourceLines + 1} lines'));
  });

  test('error silencing is rejected in Rust and Dart', () {
    final errors = _run(checkErrorSilencing, <String, Object>{
      'crates/a/src/lib.rs': 'fn f() {\n    let _ = g();\n    // let _ = in a comment is fine\n    let _guard = h();\n}\n',
      'apps/bistre_app/lib/a.dart': 'void f() {\n  try {\n    g();\n  } catch (_) {\n    // ignored\n  }\n  try {\n    g();\n  } catch (e) {\n    log(e);\n  }\n}\n',
      'apps/bistre_app/lib/bridge/frb_generated.dart':
          'void f() { try { g(); } catch (_) {} }\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('lib.rs:2 discards a value'));
    expect(joined, contains('a.dart:4 has an empty catch'));
    expect(errors, hasLength(2));
  });

  test('dropped storage and vault errors are rejected outside tests', () {
    final errors = _run(checkErrorSilencing, <String, Object>{
      'crates/a/src/run.rs': 'fn f() {\n    let x = storage\n        .list_nodes(id)\n        .ok();\n    if let Ok(n) = storage.append_node(a) {}\n    let y = storage.list_nodes(id)?;\n}\n#[cfg(test)]\nmod tests { fn t() { let z = storage.list_nodes(id).ok(); } }\n',
      'crates/a/src/tests.rs':
          'fn t() { let z = storage.list_nodes(id).ok(); }\n',
      'crates/a/src/lib.rs': '#[cfg(test)]\nmod tests;\nfn g() {\n    if let Ok(s) = storage.load_settings() {}\n}\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('run.rs:2 drops a storage/vault error'));
    expect(joined, contains('run.rs:5 drops a storage/vault error'));
    expect(joined, contains('lib.rs:4 drops a storage/vault error'));
    expect(errors, hasLength(3), reason: joined);
  });

  test('AGENTS.md budget and markdown anchors are enforced', () {
    final (root, rels) = _repo(<String, Object>{
      'AGENTS.md': 'x' * (maxAgentsChars + 1),
      'docs/a.md': '# Title — Sub\n## 1. Setup & Run\nSee [ok](#1-setup--run), [ok2](b.md#target-heading), [bad](b.md#nope), [self](#title--sub).\n',
      'docs/b.md': '## Target `Heading`\n',
    });
    final errors = <String>[];
    checkAgentsBudget(root, errors);
    checkMarkdownAnchors(root, rels, errors);
    final joined = errors.join('\n');
    expect(joined, contains('AGENTS.md has ${maxAgentsChars + 1} characters'));
    expect(joined, contains('missing heading "#nope"'));
    expect(errors, hasLength(2), reason: joined);
  });

  test('single version source spans Cargo, pubspec, Runner.rc, and MCP', () {
    final good = _repo(<String, Object>{
      'Cargo.toml': '[workspace.package]\nversion = "1.2.3"\n',
      'apps/bistre_app/pubspec.yaml': 'version: 1.2.3+4\n',
      'apps/bistre_app/windows/runner/Runner.rc': '#define VERSION_AS_NUMBER 1,2,3,4\r\n#define VERSION_AS_STRING "1.2.3"\r\nVALUE "ProductName", "Bistre" "\\0"\r\n',
      'crates/bistre-core/src/mcp.rs':
          '"clientInfo": { "name": "Bistre", "version": crate::CORE_VERSION }',
    });
    final goodErrors = <String>[];
    checkSingleVersionSource(good.$1, goodErrors);
    expect(goodErrors, isEmpty, reason: goodErrors.join('\n'));

    final bad = _repo(<String, Object>{
      'Cargo.toml': '[workspace.package]\nversion = "1.2.3"\n',
      'apps/bistre_app/pubspec.yaml': 'version: 1.3.0+1\n',
      'apps/bistre_app/windows/runner/Runner.rc': '#define VERSION_AS_NUMBER 1,0,0,0\r\nVALUE "ProductName", "bistre_app" "\\0"\r\n',
      'crates/bistre-core/src/mcp.rs': '"version": "0.1.0"',
    });
    final badErrors = <String>[];
    checkSingleVersionSource(bad.$1, badErrors);
    final joined = badErrors.join('\n');
    expect(joined, contains('!= apps/bistre_app/pubspec.yaml version 1.3.0'));
    expect(joined, contains('Runner.rc fallback version'));
    expect(joined, contains('generator boilerplate'));
    expect(joined, contains('must use crate::CORE_VERSION'));
  });

  test('heading slugs follow GitHub rules', () {
    expect(headingSlug('1. Identity & North Star'), '1-identity--north-star');
    expect(headingSlug('Batch 1 — `QC` Storage'), 'batch-1--qc-storage');
    expect(
      headingSlug('3.5 Offline Vector Iconography'),
      '35-offline-vector-iconography',
    );
  });

  test('test retries are rejected', () {
    final errors = _run(checkNoTestRetries, <String, Object>{
      'apps/bistre_app/test/a_test.dart': "test('x', () {}, retry: 3);\n",
      'apps/bistre_app/test/b_test.dart': "test('y', () {});\n",
      '.config/nextest.toml': '[profile.default]\nretries = 2\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('a_test.dart retries a test'));
    expect(joined, contains('nextest.toml configures nextest retries'));
    expect(errors, hasLength(2), reason: joined);
  });

  test('Rust errors dropped into a silent early return are rejected', () {
    final errors = _run(checkNoSilentRustSkips, <String, Object>{
      'crates/a/src/lib.rs': 'fn t() {\n    let dir = tempdir().ok();\n    let Some(dir) = dir else { return };\n}\n',
      'crates/b/src/lib.rs': 'fn t() -> R {\n    let s = open()\n        .ok();\n    let Some(mut s) = s else {\n        return Ok(());\n    };\n}\n',
      'crates/c/src/lib.rs':
          'fn t() -> R {\n    let dir = tempdir()?;\n    Ok(())\n}\n',
      'crates/d/src/lib.rs': 'fn t() {\n    let x = a().ok();\n    let Some(y) = other else { return };\n}\n',
      'crates/e/src/lib.rs': 'fn t() {\n    let key = gen();\n    assert!(key.is_ok());\n    let Ok(key) = key else { return };\n}\n',
      'crates/f/src/lib.rs': 'fn t() {\n    let Ok(h) = h else {\n        warn();\n        return;\n    };\n}\n',
    });
    final joined = errors.join('\n');
    expect(joined, contains('crates/a/src/lib.rs: `dir`'));
    expect(joined, contains('crates/b/src/lib.rs: `s`'));
    expect(joined, contains('crates/e/src/lib.rs: `key`'));
    expect(errors, hasLength(3), reason: joined);
  });
}
