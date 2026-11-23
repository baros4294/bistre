import 'dart:io';

/// Files allowed to construct `Command::new(...)` directly. Every other Rust file must spawn
/// children through `process_util::no_window_command` so Windows never flashes a console.
const Set<String> processSpawnAllowlist = <String>{
  'crates/bistre-core/src/process_util.rs',
  'crates/bistre-daemon/src/power_linux.rs',
};

/// Provider registry preset files: the only runtime code allowed to name concrete model IDs.
const Set<String> modelPresetAllowlist = <String>{
  'apps/bistre_app/lib/features/settings/provider_presets.dart',
};

/// Hard cap on lines per non-generated `.rs` / `.dart` file.
const int maxSourceLines = 1500;

/// Hard cap on `AGENTS.md` size (characters).
const int maxAgentsChars = 14000;

/// Hard cap on any tracked file outside the approved font directory.
const int maxTrackedFileBytes = 1024 * 1024;

/// Approved directory for OFL font binaries (still budgeted to 2.0 MB total by Spec 11).
const String approvedFontDir = 'apps/bistre_app/assets/fonts/';

/// Compiled artifacts that must never be committed.
const Set<String> bannedArtifactExtensions = <String>{
  '.exe', '.dll', '.so', '.dylib', '.apk', '.aab', '.pdb', '.rlib', //
  '.rmeta', '.jar', '.aot', '.msi', '.o', '.a', '.lib', '.obj',
};

/// Secret-bearing file types that must never be committed.
const Set<String> bannedSecretExtensions = <String>{
  '.jks', '.keystore', '.p12', '.pfx', '.pem', '.key', //
};

/// Files whose every line break must be CRLF (Windows tooling requirement).
const Set<String> crlfExtensions = <String>{'.bat', '.cmd', '.iss', '.rc'};

/// OEM / device brand names banned from runtime code, Android sources, and `README.md`.
/// Built from fragments so this file does not trip its own scan.
final List<String> bannedBrands = <String>[
  const <String>['One', 'Plus'].join(),
  const <String>['Xiao', 'mi'].join(),
  const <String>['MI', 'UI'].join(),
  const <String>['Hyper', 'OS'].join(),
  const <String>['Sam', 'sung'].join(),
  const <String>['Hua', 'wei'].join(),
  const <String>['OP', 'PO'].join(),
  const <String>['Vi', 'vo'].join(),
  const <String>['Real', 'me'].join(),
];

/// Rotting hardcoded model identifiers (runtime code must read models from the registry).
final RegExp hardcodedModelPattern = RegExp(
  '["\'`](?:gpt-[0-9]|o[134]-(?:mini|pro)|claude-(?:[0-9]|opus|sonnet|haiku)|'
  'gemini-[0-9]|llama-?[0-9]|mistral-(?:large|small|medium)|'
  'deepseek-(?:chat|r1|v[0-9])|grok-[0-9]|qwen[0-9])',
);

/// Credential prefixes with enough trailing entropy to be real keys.
final List<RegExp> credentialPatterns = <RegExp>[
  RegExp(['sk-', 'proj-', r'[A-Za-z0-9_\-]{20,}'].join()),
  RegExp(['sk-', 'ant-', r'[A-Za-z0-9_\-]{20,}'].join()),
  RegExp(['AI', 'za', r'Sy[0-9A-Za-z_\-]{33}'].join()),
  RegExp(['gh', 'p_', '[A-Za-z0-9]{36}'].join()),
  RegExp(['github', '_pat_', '[A-Za-z0-9_]{22,}'].join()),
  RegExp(
    [
      '-----BEGIN ',
      r'(?:RSA |EC |OPENSSH |ENCRYPTED )?',
      'PRIVATE KEY-----',
    ].join(),
  ),
];

/// Runs every Batch-2 static anti-pattern gate.
void runStaticGates(
  Directory repoRoot,
  List<String> workspaceFiles,
  List<String> errors,
) {
  checkProcessSpawnAndMmap(repoRoot, workspaceFiles, errors);
  checkEncodingHygiene(repoRoot, workspaceFiles, errors);
  checkSecretsAndArtifacts(repoRoot, workspaceFiles, errors);
  checkHardcodedModelsAndBrands(repoRoot, workspaceFiles, errors);
  checkSourceLineCap(repoRoot, workspaceFiles, errors);
  checkErrorSilencing(repoRoot, workspaceFiles, errors);
  checkNoTestRetries(repoRoot, workspaceFiles, errors);
  checkAgentsBudget(repoRoot, errors);
  checkMarkdownAnchors(repoRoot, workspaceFiles, errors);
  checkSingleVersionSource(repoRoot, errors);
}

bool _isGenerated(String rel) =>
    rel.endsWith('.g.dart') ||
    rel.contains('frb_generated') ||
    rel == 'apps/bistre_app/lib/bridge/api.dart' ||
    rel.startsWith('apps/bistre_app/lib/bridge/api/');

String _read(Directory root, String rel) =>
    File('${root.path}/$rel').readAsStringSync();

/// Rust source up to the first `#[cfg(test)]` (unit-test modules sit at the end of each file).
String _rustRuntimePart(String content) {
  final idx = content.indexOf('#[cfg(test)]');
  return idx == -1 ? content : content.substring(0, idx);
}

/// Split-out unit tests: `src/**/tests.rs` declared by a sibling `#[cfg(test)] mod tests;`,
/// or `src/**/<name>_tests.rs` declared by `<name>.rs` via `#[path = "<name>_tests.rs"]`.
bool _isRustTestModule(Directory root, String rel) {
  if (rel.endsWith('_tests.rs')) {
    final slash = rel.lastIndexOf('/');
    final name = rel.substring(slash + 1, rel.length - '_tests.rs'.length);
    final parent = File('${root.path}/${rel.substring(0, slash + 1)}$name.rs');
    return parent.existsSync() &&
        parent.readAsStringSync().contains('#[path = "${name}_tests.rs"]');
  }
  if (!rel.endsWith('/tests.rs')) return false;
  final dir = rel.substring(0, rel.length - 'tests.rs'.length);
  final decl = RegExp(r'#\[cfg\(test\)\]\s*mod tests;');
  return <String>['lib.rs', 'main.rs', 'mod.rs'].any((parent) {
    final f = File('${root.path}/$dir$parent');
    return f.existsSync() && decl.hasMatch(f.readAsStringSync());
  });
}

/// 1–2. Ban raw `Command::new(` outside the centralized helper and ban memory-mapped I/O.
void checkProcessSpawnAndMmap(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  final mmapPattern = RegExp(
    r'\bmemmap2?\b|\bMmap(?:Mut|Options|Choice)?::|\.memory_map\(',
  );
  for (final rel in files) {
    if (!rel.startsWith('crates/')) continue;
    if (rel.endsWith('Cargo.toml')) {
      if (RegExp(
        r'^\s*memmap2?\s*=',
        multiLine: true,
      ).hasMatch(_read(root, rel))) {
        errors.add(
          '[mmap-ban] $rel declares a memmap dependency (stream with std::io::Read instead).',
        );
      }
      continue;
    }
    if (!rel.endsWith('.rs') || _isGenerated(rel)) continue;
    final lines = _read(root, rel).split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('//')) continue;
      if (!processSpawnAllowlist.contains(rel) &&
          line.contains('Command::new(')) {
        errors.add(
          '[process-spawn] $rel:${i + 1} uses raw Command::new; spawn via process_util::no_window_command (CREATE_NO_WINDOW).',
        );
      }
      if (mmapPattern.hasMatch(line)) {
        errors.add(
          '[mmap-ban] $rel:${i + 1} uses memory-mapped I/O (SIGBUS on concurrently modified files).',
        );
      }
    }
  }
  final rootCargo = File('${root.path}/Cargo.toml');
  if (rootCargo.existsSync() &&
      RegExp(
        r'^\s*memmap2?\s*=',
        multiLine: true,
      ).hasMatch(rootCargo.readAsStringSync())) {
    errors.add('[mmap-ban] Cargo.toml declares a memmap workspace dependency.');
  }
}

/// 3. UTF-8 BOM ban, ASCII-only `.ps1`, and CRLF for Windows script/resource files.
void checkEncodingHygiene(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  for (final rel in files) {
    final ext = _ext(rel);
    if (bannedArtifactExtensions.contains(ext) || _isBinaryAsset(ext)) continue;
    final file = File('${root.path}/$rel');
    if (!file.existsSync()) continue;
    final bytes = file.readAsBytesSync();
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      errors.add(
        '[encoding] $rel starts with a UTF-8 BOM; save as UTF-8 without BOM.',
      );
    }
    if (ext == '.ps1' && bytes.any((b) => b > 0x7F)) {
      errors.add(
        '[encoding] $rel must be ASCII-only (Windows PowerShell 5.1 misreads UTF-8 without BOM).',
      );
    }
    if (crlfExtensions.contains(ext)) {
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 10 && (i == 0 || bytes[i - 1] != 13)) {
          errors.add(
            '[eol-hygiene] $rel must use CRLF line endings (see .gitattributes).',
          );
          break;
        }
      }
    }
  }
}

/// 4 & 6. Secret files, credential prefixes, compiled artifacts, and the 1 MiB tracked-file cap.
void checkSecretsAndArtifacts(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  for (final rel in files) {
    final name = rel.split('/').last;
    final ext = _ext(rel);
    if (bannedSecretExtensions.contains(ext) ||
        name == 'local.properties' ||
        name == 'key.properties' ||
        name == '.env' ||
        name.startsWith('.env.')) {
      errors.add(
        '[secrets] $rel is a secret-bearing file and must never be committed.',
      );
      continue;
    }
    if (bannedArtifactExtensions.contains(ext)) {
      errors.add(
        '[artifacts] $rel is a compiled artifact; build outputs must never be committed.',
      );
      continue;
    }
    final file = File('${root.path}/$rel');
    if (!file.existsSync()) continue;
    final size = file.lengthSync();
    if (size > maxTrackedFileBytes && !rel.startsWith(approvedFontDir)) {
      errors.add(
        '[artifacts] $rel is ${(size / 1048576).toStringAsFixed(2)} MiB (> 1 MiB tracked-file cap).',
      );
    }
    if (_isBinaryAsset(ext) || size > maxTrackedFileBytes) continue;
    final text = String.fromCharCodes(file.readAsBytesSync());
    for (final pattern in credentialPatterns) {
      if (pattern.hasMatch(text)) {
        errors.add(
          '[secrets] $rel contains a credential matching ${pattern.pattern.split('[').first}...',
        );
        break;
      }
    }
  }
}

/// 5. No hardcoded model IDs in runtime code / README and no OEM brand strings.
void checkHardcodedModelsAndBrands(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  for (final rel in files) {
    final isRuntimeRust =
        rel.startsWith('crates/') &&
        rel.contains('/src/') &&
        rel.endsWith('.rs');
    final isRuntimeDart =
        rel.startsWith('apps/bistre_app/lib/') && rel.endsWith('.dart');
    final isAndroid = rel.startsWith('apps/bistre_app/android/app/src/');
    final isReadme = rel == 'README.md';
    if (!(isRuntimeRust || isRuntimeDart || isAndroid || isReadme) ||
        _isGenerated(rel) ||
        modelPresetAllowlist.contains(rel)) {
      continue;
    }
    if (_isBinaryAsset(_ext(rel))) continue;
    var content = _read(root, rel);
    if (isRuntimeRust) {
      content = _isRustTestModule(root, rel) ? '' : _rustRuntimePart(content);
    }
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!isAndroid && hardcodedModelPattern.hasMatch(line)) {
        errors.add(
          '[hardcoded-model] $rel:${i + 1} hardcodes a model ID; read models from the provider registry.',
        );
      }
      for (final brand in bannedBrands) {
        if (RegExp('\\b$brand\\b').hasMatch(line)) {
          errors.add(
            '[device-brand] $rel:${i + 1} names OEM brand "$brand"; use generic platform behavior.',
          );
        }
      }
    }
  }
}

/// 7. `<= 1,500` lines per non-generated `.rs` / `.dart` file.
void checkSourceLineCap(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  for (final rel in files) {
    if (!(rel.endsWith('.rs') || rel.endsWith('.dart')) || _isGenerated(rel))
      continue;
    final lines = '\n'.allMatches(_read(root, rel)).length;
    if (lines > maxSourceLines) {
      errors.add(
        '[file-size] $rel has $lines lines (> $maxSourceLines); split it by responsibility.',
      );
    }
  }
}

/// 7b. Ban silently discarded errors: Rust `let _ =` and Dart catch blocks with no code.
void checkErrorSilencing(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  final rustDiscard = RegExp(r'\blet _\s*=');
  final dartCatch = RegExp(r'catch\s*\([^)]*\)\s*\{');
  // Storage and vault results whose error is dropped (`.ok()` or `if let Ok(..)`) in
  // non-test Rust: the failure mode behind empty histories and lost run states.
  final silencedStore = RegExp(
    r'((storage|vault)\s*\.\s*\w+\([^;]*?\)\s*\.ok\(\))|(if let Ok\([^)]*\)\s*=\s*(self\.)?(storage|vault)\s*\.)',
    dotAll: true,
  );
  for (final rel in files) {
    if (_isGenerated(rel)) continue;
    if (rel.startsWith('crates/') && rel.endsWith('.rs')) {
      final content = _read(root, rel);
      // Only an inline `#[cfg(test)] mod name {` starts test code; a `mod tests;` declaration
      // near the top of a file must not hide the runtime code after it.
      final testStart =
          RegExp(r'#\[cfg\(test\)\]\s*(?:#\[[^\]]*\]\s*)*mod \w+ \{')
              .firstMatch(content)
              ?.start ??
          -1;
      final prod = rel.endsWith('/tests.rs') || _isRustTestModule(root, rel)
          ? ''
          : (testStart < 0 ? content : content.substring(0, testStart));
      for (final m in silencedStore.allMatches(prod)) {
        final line = '\n'.allMatches(prod.substring(0, m.start)).length + 1;
        errors.add(
          '[error-silencing] $rel:$line drops a storage/vault error (`.ok()` or `if let Ok`); propagate it or log it with its key.',
        );
      }
      final lines = content.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (!line.startsWith('//') && rustDiscard.hasMatch(line)) {
          errors.add(
            '[error-silencing] $rel:${i + 1} discards a value with `let _ =`; handle, propagate, or log it.',
          );
        }
      }
    } else if (rel.endsWith('.dart') &&
        (rel.startsWith('apps/') || rel.startsWith('tools/')) &&
        // The guard's own tests embed offending snippets as fixtures.
        !rel.startsWith('tools/bistre_guard/test/')) {
      final content = _read(root, rel);
      for (final m in dartCatch.allMatches(content)) {
        var depth = 1;
        var k = m.end;
        while (depth > 0 && k < content.length) {
          final c = content[k];
          if (c == '{') depth++;
          if (c == '}') depth--;
          k++;
        }
        final body = content
            .substring(m.end, k - 1)
            .replaceAll(RegExp(r'//[^\n]*'), '')
            .trim();
        if (body.isEmpty) {
          final line =
              '\n'.allMatches(content.substring(0, m.start)).length + 1;
          errors.add(
            '[error-silencing] $rel:$line has an empty catch; handle or log the error.',
          );
        }
      }
    }
  }
}

/// 8a. `AGENTS.md` character budget.
void checkAgentsBudget(Directory root, List<String> errors) {
  final f = File('${root.path}/AGENTS.md');
  if (!f.existsSync()) return;
  final chars = f.readAsStringSync().runes.length;
  if (chars > maxAgentsChars) {
    errors.add(
      '[doc-budget] AGENTS.md has $chars characters (> $maxAgentsChars).',
    );
  }
}

/// GitHub-style heading slug.
String headingSlug(String heading) {
  final text = heading
      .replaceAll(RegExp(r'`'), '')
      .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
      .trim()
      .toLowerCase();
  final buf = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == ' ') {
      buf.write('-');
    } else if (ch == '-' ||
        ch == '_' ||
        RegExp(r'[a-z0-9]').hasMatch(ch) ||
        rune > 0x7F && !_isUnicodePunctuation(rune)) {
      buf.write(ch);
    }
  }
  return buf.toString();
}

bool _isUnicodePunctuation(int rune) =>
    (rune >= 0x2000 && rune <= 0x206F) || // general punctuation (—, –, …)
    (rune >= 0x2190 && rune <= 0x21FF) || // arrows
    (rune >= 0x2200 && rune <= 0x22FF) || // math operators (≤, ≥)
    (rune >= 0x2500 && rune <= 0x27BF) || // box drawing, symbols, dingbats
    (rune >= 0x1F000); // emoji

/// All anchors (with GitHub duplicate suffixes) for a Markdown file.
Set<String> markdownAnchors(String content) {
  final anchors = <String>{};
  final counts = <String, int>{};
  var inFence = false;
  for (final line in content.split('\n')) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final m = RegExp(r'^#{1,6}\s+(.+?)\s*#*\s*$').firstMatch(line);
    if (m == null) continue;
    final slug = headingSlug(m.group(1)!);
    final n = counts[slug] ?? 0;
    anchors.add(n == 0 ? slug : '$slug-$n');
    counts[slug] = n + 1;
  }
  return anchors;
}

/// 8b. Every `file.md#anchor` and `#anchor` link resolves to a real heading.
void checkMarkdownAnchors(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  final linkPattern = RegExp(r'\[[^\]]*\]\(([^)\s]+)\)');
  final cache = <String, Set<String>>{};
  for (final rel in files.where((f) => f.endsWith('.md'))) {
    final content = _read(root, rel);
    var inFence = false;
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      for (final m in linkPattern.allMatches(line)) {
        final target = m.group(1)!;
        if (target.startsWith('http://') ||
            target.startsWith('https://') ||
            !target.contains('#')) {
          continue;
        }
        final hashIdx = target.indexOf('#');
        final pathPart = target.substring(0, hashIdx);
        final anchor = target.substring(hashIdx + 1);
        if (pathPart.isNotEmpty && !pathPart.endsWith('.md')) continue;
        final targetRel = pathPart.isEmpty
            ? rel
            : Uri.parse(rel).resolve(pathPart).path;
        final targetFile = File('${root.path}/$targetRel');
        if (!targetFile.existsSync())
          continue; // broken paths are reported by checkMarkdownLinks
        final anchors = cache.putIfAbsent(
          targetRel,
          () => markdownAnchors(targetFile.readAsStringSync()),
        );
        if (!anchors.contains(Uri.decodeComponent(anchor).toLowerCase())) {
          errors.add(
            '[doc-anchor] $rel:${i + 1} links to missing heading "#$anchor" in $targetRel.',
          );
        }
      }
    }
  }
}

/// 8c. One app version across Cargo, pubspec, the Win32 resource fallback, and MCP `clientInfo`.
void checkSingleVersionSource(Directory root, List<String> errors) {
  final cargo = File('${root.path}/Cargo.toml');
  final pubspec = File('${root.path}/apps/bistre_app/pubspec.yaml');
  final rc = File('${root.path}/apps/bistre_app/windows/runner/Runner.rc');
  final mcp = File('${root.path}/crates/bistre-core/src/mcp.rs');
  if (!cargo.existsSync() || !pubspec.existsSync()) return;
  final workspacePkg = RegExp(r'\[workspace\.package\]([\s\S]*?)(?:\n\[|$)')
      .firstMatch(cargo.readAsStringSync())
      ?.group(1);
  final cargoVersion = RegExp(
    r'^version\s*=\s*"([^"]+)"',
    multiLine: true,
  ).firstMatch(workspacePkg ?? '')?.group(1);
  final pubMatch = RegExp(
    r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?',
    multiLine: true,
  ).firstMatch(pubspec.readAsStringSync());
  if (cargoVersion == null || pubMatch == null) {
    errors.add(
      '[version-sync] Could not parse the app version from Cargo.toml and apps/bistre_app/pubspec.yaml.',
    );
    return;
  }
  final pubVersion = pubMatch.group(1)!;
  final build = pubMatch.group(2) ?? '0';
  if (cargoVersion != pubVersion) {
    errors.add(
      '[version-sync] Cargo.toml version $cargoVersion != apps/bistre_app/pubspec.yaml version $pubVersion.',
    );
  }
  if (rc.existsSync()) {
    final text = rc.readAsStringSync();
    final expectedNumber = '${pubVersion.replaceAll('.', ',')},$build';
    if (!text.contains('#define VERSION_AS_NUMBER $expectedNumber') ||
        !text.contains('#define VERSION_AS_STRING "$pubVersion"')) {
      errors.add(
        '[version-sync] Runner.rc fallback version must be $pubVersion ($expectedNumber).',
      );
    }
    for (final boilerplate in const <String>['"bistre_app" "', 'dev.bistre']) {
      if (text.contains(boilerplate)) {
        errors.add(
          '[version-sync] Runner.rc still contains generator boilerplate $boilerplate; use real Bistre product metadata.',
        );
      }
    }
  }
  if (mcp.existsSync()) {
    final text = mcp.readAsStringSync();
    if (!text.contains('"version": crate::CORE_VERSION')) {
      errors.add(
        '[version-sync] MCP clientInfo.version must use crate::CORE_VERSION.',
      );
    }
    if (RegExp(r'"version"\s*:\s*"[0-9]').hasMatch(text)) {
      errors.add(
        '[version-sync] crates/bistre-core/src/mcp.rs hardcodes a version literal.',
      );
    }
  }
}

String _ext(String rel) {
  final name = rel.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot).toLowerCase();
}

bool _isBinaryAsset(String ext) => const <String>{
  '.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.icns', '.ttf', '.otf', //
  '.woff2', '.vec', '.zip', '.gz', '.wav', '.mp3', '.mp4',
}.contains(ext);

/// 7c. Never retry flaky tests (Parchment `3247bf0d`: a retry hid a real crash). Rejects Dart
/// `retry:` test arguments and nextest `retries` settings.
void checkNoTestRetries(
  Directory root,
  List<String> files,
  List<String> errors,
) {
  final dartRetry = RegExp(r'\bretry:\s*\d');
  final nextestRetry = RegExp(r'^\s*retries\s*=', multiLine: true);
  for (final rel in files) {
    final isDartTest =
        rel.endsWith('_test.dart') &&
        // The guard's own tests embed offending snippets as fixtures.
        !rel.startsWith('tools/bistre_guard/test/');
    if (isDartTest && dartRetry.hasMatch(_read(root, rel))) {
      errors.add(
        '[test-retry] $rel retries a test; find and fix the root cause instead.',
      );
    }
    if (rel.endsWith('nextest.toml') &&
        nextestRetry.hasMatch(_read(root, rel))) {
      errors.add(
        '[test-retry] $rel configures nextest retries; find and fix the root cause instead.',
      );
    }
  }
}
