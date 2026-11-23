import 'dart:io';

import 'ledger.dart' show listWorkspaceFiles;
import 'static_gates.dart';

/// Aggregated report from all Bistre repository rigor checks.
class GuardResult {
  const GuardResult(this.errors);
  final List<String> errors;
  bool get isValid => errors.isEmpty;
}

/// Canonical 10 Ink Primitives budget locked by `docs/design/DESIGN.md` & `ADR-0011`.
const Set<String> canonicalInkPrimitives = <String>{
  'ParchmentScaffold',
  'FolioSurface',
  'InkText',
  'EngravedButton',
  'WaxSealBadge',
  'QuillInput',
  'FolioDivider',
  'InkChip',
  'FolioOverlay',
  'EngravedIcon',
};

const Set<String> _forbiddenFlutterDeps = <String>{
  'material_ui',
  'cupertino_ui',
  'flutter_localizations',
  'google_fonts',
  'provider',
  'riverpod',
  'flutter_riverpod',
  'bloc',
  'flutter_bloc',
  'get',
  'mobx',
  'http',
  'dio',
  'sqflite',
  'sqlite3',
  'drift',
};

/// Workspace files (tracked + untracked-not-ignored), falling back to a filtered walk outside git.
List<String> workspaceFiles(Directory repoRoot) {
  try {
    return listWorkspaceFiles(repoRoot);
  } on Object {
    return <String>[
      for (final e in repoRoot.listSync(recursive: true))
        if (e is File && !_isIgnoredBuildPath(_relativePath(repoRoot, e)))
          _relativePath(repoRoot, e),
    ]..sort();
  }
}

/// Runs the complete mechanical anti-slop, doc-integrity, version-sync, and CI-security suite.
GuardResult runRepoGuards(Directory repoRoot) {
  final errors = <String>[];
  runStaticGates(repoRoot, workspaceFiles(repoRoot), errors);
  checkMarkdownLinks(repoRoot, errors);
  checkDocPathsAndIndexes(repoRoot, errors);
  checkCodeHygiene(repoRoot, errors);
  checkLineEndings(repoRoot, errors);
  checkToolchainAndVersionSync(repoRoot, errors);
  checkWorkflowSecurity(repoRoot, errors);
  return GuardResult(errors);
}

/// 1. Verify every relative Markdown link in repository documentation resolves on disk.
void checkMarkdownLinks(Directory repoRoot, List<String> errors) {
  final mdFiles = _collectMarkdownFiles(repoRoot);
  final linkPattern = RegExp(r'!?\[[^\]]*\]\(([^)]+)\)');
  for (final file in mdFiles) {
    final relFile = _relativePath(repoRoot, file);
    final lines = _readLinesStripFencedCode(file);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line == null) continue;
      for (final match in linkPattern.allMatches(line)) {
        final rawTarget = match.group(1)!.trim();
        if (rawTarget.isEmpty ||
            rawTarget.startsWith('#') ||
            rawTarget.startsWith('http://') ||
            rawTarget.startsWith('https://') ||
            rawTarget.startsWith('mailto:')) {
          continue;
        }
        final targetPath = rawTarget.split('#').first.split('?').first.trim();
        if (targetPath.isEmpty) continue;
        final resolved = _resolveLinkTarget(file.parent, targetPath);
        if (!File(resolved).existsSync() && !Directory(resolved).existsSync()) {
          errors.add(
            '[doc-link] $relFile:${i + 1} broken relative link "$rawTarget"',
          );
        }
      }
    }
  }
}

/// 2. Verify Spec/ADR indexes in `AGENTS.md`, ADR template structure, concrete doc paths, and zero boilerplate.
void checkDocPathsAndIndexes(Directory repoRoot, List<String> errors) {
  final agentsFile = File('${repoRoot.path}/AGENTS.md');
  if (!agentsFile.existsSync()) {
    errors.add('[doc-index] Missing root AGENTS.md');
    return;
  }
  final agentsText = agentsFile.readAsStringSync();

  // Verify every docs/specs/*.md file on disk is indexed in AGENTS.md.
  final specsDir = Directory('${repoRoot.path}/docs/specs');
  if (specsDir.existsSync()) {
    final specs =
        specsDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final spec in specs) {
      final stem = spec.uri.pathSegments.last.replaceAll('.md', '');
      if (!agentsText.contains(stem)) {
        errors.add(
          '[doc-index] docs/specs/$stem.md is not indexed in AGENTS.md',
        );
      }
    }
  }

  // Verify every docs/adr/ADR-*.md file is indexed in AGENTS.md and follows the ADR structure.
  final adrDir = Directory('${repoRoot.path}/docs/adr');
  if (adrDir.existsSync()) {
    final adrs =
        adrDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.md'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final adr in adrs) {
      final name = adr.uri.pathSegments.last;
      final idMatch = RegExp(r'^(ADR-\d{4})').firstMatch(name);
      if (idMatch == null) {
        errors.add('[doc-adr] docs/adr/$name must follow ADR-NNNN-slug.md');
        continue;
      }
      final adrId = idMatch.group(1)!;
      if (!agentsText.contains(adrId)) {
        errors.add('[doc-index] $adrId ($name) is not indexed in AGENTS.md');
      }
      final text = adr.readAsStringSync();
      for (final requiredSection in const <String>[
        '- **Status**:',
        '- **Date**:',
        '## Context',
        '## Decision',
        '## Rejected Alternatives',
        '## Consequences & Verification',
      ]) {
        if (!text.contains(requiredSection)) {
          errors.add(
            '[doc-adr] docs/adr/$name missing required section "$requiredSection"',
          );
        }
      }
    }
  }

  // Spec 00 must keep the implementation-status table (specs describe the target; this table
  // records what the code does today).
  final spec00 = File('${repoRoot.path}/docs/specs/00-architecture.md');
  if (spec00.existsSync() &&
      !spec00.readAsStringSync().contains('## 6. Implementation Status')) {
    errors.add(
      '[doc-status] docs/specs/00-architecture.md must keep "## 6. Implementation Status".',
    );
  }

  // Verify AGENTS.md explicitly requires documentation sync for latest changes.
  if (!agentsText.toLowerCase().contains('documentation') ||
      !agentsText.toLowerCase().contains('same change')) {
    errors.add(
      '[doc-policy] AGENTS.md must explicitly mandate updating docs in the same change.',
    );
  }

  // Verify concrete backticked repo paths inside high-authority docs actually exist on disk.
  const checkedDocs = <String>[
    'AGENTS.md',
    'README.md',
    'CONTRIBUTING.md',
    'docs/design/DESIGN.md',
    'docs/SLICE-0-HANDOFF.md',
  ];
  final pathSpanPattern = RegExp(
    r'`((?:docs|crates|apps|tools|l10n|\.github|\.agents|assets)/[A-Za-z0-9_./\-]+)`',
  );
  for (final rel in checkedDocs) {
    final f = File('${repoRoot.path}/$rel');
    if (!f.existsSync()) continue;
    final lines = _readLinesStripFencedCode(f);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line == null) continue;
      for (final m in pathSpanPattern.allMatches(line)) {
        final rawPath = m.group(1)!;
        if (_isSymbolicOrBuildPath(rawPath)) continue;
        final cleaned = rawPath.endsWith('/')
            ? rawPath.substring(0, rawPath.length - 1)
            : rawPath;
        final candidate = '${repoRoot.path}/$cleaned';
        if (!File(candidate).existsSync() &&
            !Directory(candidate).existsSync()) {
          errors.add(
            '[doc-path] $rel:${i + 1} references nonexistent repo path `$rawPath`',
          );
        }
      }
    }
  }

  // Reject leftover Flutter/template boilerplate in README files.
  for (final rel in const <String>['README.md', 'apps/bistre_app/README.md']) {
    final f = File('${repoRoot.path}/$rel');
    if (!f.existsSync()) continue;
    final text = f.readAsStringSync();
    for (final slop in const <String>[
      'A new Flutter project.',
      'This project is a starting point',
    ]) {
      if (text.contains(slop)) {
        errors.add(
          '[doc-slop] $rel contains leftover generator boilerplate: "$slop"',
        );
      }
    }
  }

  // Validate workspace agent skills under .agents/skills/*/SKILL.md carry valid YAML frontmatter.
  final skillsDir = Directory('${repoRoot.path}/.agents/skills');
  if (skillsDir.existsSync()) {
    for (final entry in skillsDir.listSync().whereType<Directory>()) {
      final skillFile = File('${entry.path}/SKILL.md');
      if (!skillFile.existsSync()) continue;
      final text = skillFile.readAsStringSync();
      final fmMatch = RegExp(r'^---\n([\s\S]*?)\n---').firstMatch(text);
      if (fmMatch == null ||
          !fmMatch.group(1)!.contains('name:') ||
          !fmMatch.group(1)!.contains('description:')) {
        errors.add(
          '[skill-hygiene] ${_relativePath(repoRoot, skillFile)} must start with YAML frontmatter containing `name:` and `description:`.',
        );
      }
    }
  }
}

/// 3. Verify anti-slop code hygiene, lint-bypass prevention, 10 Ink Primitives budget, and manifest hygiene.
void checkCodeHygiene(Directory repoRoot, List<String> errors) {
  // Construct marker regex dynamically so this file does not match its own scan.
  final slopCommentPattern = RegExp(
    r'(?://|#|/\*)\s*\b('
    'TO'
    'DO|FIX'
    'ME|HA'
    'CK|XX'
    r'X)\b',
  );
  final dartBypassPattern = RegExp(
    r'//\s*ignore(?:_for_file)?:[^\n]*\bbistre_',
  );
  final rustBypassPattern = RegExp(
    r'#\[\s*allow\s*\([^)]*(?:unsafe_code|clippy::unwrap_used|clippy::expect_used|clippy::panic|clippy::todo|clippy::unimplemented)',
  );

  for (final rootName in const <String>[
    'crates',
    'apps/bistre_app/lib',
    'apps/bistre_app/hook',
    'apps/bistre_app/test',
    'tools',
  ]) {
    final dir = Directory('${repoRoot.path}/$rootName');
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File) continue;
      final rel = _relativePath(repoRoot, entity);
      if (_isIgnoredBuildPath(rel) ||
          rel.endsWith('.g.dart') ||
          rel.endsWith('frb_generated.rs') ||
          rel.contains('frb_generated.')) {
        continue;
      }
      if (!rel.endsWith('.rs') && !rel.endsWith('.dart')) continue;

      final content = entity.readAsStringSync();
      final lines = content.split('\n');
      final isTestFile = rel.contains('/test/') || rel.endsWith('_test.dart');

      if (!isTestFile) {
        for (var i = 0; i < lines.length; i++) {
          if (slopCommentPattern.hasMatch(lines[i])) {
            errors.add(
              '[code-slop] $rel:${i + 1} contains unresolved marker comment (resolve or track in spec/issue).',
            );
          }
        }
      }

      if (rel.startsWith('apps/bistre_app/') &&
          dartBypassPattern.hasMatch(content)) {
        errors.add(
          '[lint-bypass] $rel suppresses a mandatory bistre_* analyzer rule.',
        );
      }

      if (rel.endsWith('.rs') &&
          rel != 'crates/bistre-ffi/src/lib.rs' &&
          rustBypassPattern.hasMatch(content)) {
        errors.add(
          '[lint-bypass] $rel suppresses a forbidden Rust safety lint via #[allow(...)].',
        );
      }

      // Enforce zero hardcoded external icon catalog / CDN references in runtime code (docs/ only).
      if (rel.startsWith('crates/') || rel.startsWith('apps/')) {
        final lower = content.toLowerCase();
        final forbiddenExternalIconRefs = <String>[
          const <String>['lobe', 'hub'].join(),
          const <String>['lobe-', 'icons'].join(),
          const <String>['unpkg.', 'com'].join(),
          const <String>['jsdel', 'ivr.net'].join(),
          const <String>['svgl.', 'app'].join(),
        ];
        for (final token in forbiddenExternalIconRefs) {
          if (lower.contains(token)) {
            errors.add(
              '[external-ref] $rel contains hardcoded external icon reference "$token" (keep strictly in docs/).',
            );
          }
        }
      }
    }
  }

  // Verify every Rust crate inherits workspace lints.
  final cratesDir = Directory('${repoRoot.path}/crates');
  if (cratesDir.existsSync()) {
    for (final entry in cratesDir.listSync().whereType<Directory>()) {
      final cargoToml = File('${entry.path}/Cargo.toml');
      if (!cargoToml.existsSync()) continue;
      final text = cargoToml.readAsStringSync();
      if (!RegExp(r'\[lints\]\s*\n\s*workspace\s*=\s*true').hasMatch(text)) {
        errors.add(
          '[rust-lints] ${_relativePath(repoRoot, cargoToml)} must inherit `[lints] workspace = true`.',
        );
      }
    }
  }

  // Enforce exact 10 Ink Primitives budget in ink_primitives.dart.
  final primitivesFile = File(
    '${repoRoot.path}/apps/bistre_app/lib/design/ink_primitives.dart',
  );
  if (primitivesFile.existsSync()) {
    final text = primitivesFile.readAsStringSync();
    final widgetMatches = RegExp(
      r'^class\s+([A-Z][A-Za-z0-9_]*)\s+extends\s+(?:StatelessWidget|StatefulWidget)\b',
      multiLine: true,
    ).allMatches(text);
    final found = <String>{for (final m in widgetMatches) m.group(1)!};
    if (found.length != canonicalInkPrimitives.length ||
        !found.containsAll(canonicalInkPrimitives)) {
      errors.add(
        '[ui-budget] ink_primitives.dart public widgets $found diverge from the 10 Ink Primitives budget $canonicalInkPrimitives (DESIGN.md / ADR-0011).',
      );
    }
  } else {
    errors.add(
      '[ui-budget] Missing apps/bistre_app/lib/design/ink_primitives.dart',
    );
  }

  // Enforce apps/bistre_app/pubspec.yaml material-off & zero forbidden dependencies.
  final appPubspec = File('${repoRoot.path}/apps/bistre_app/pubspec.yaml');
  if (appPubspec.existsSync()) {
    final text = appPubspec.readAsStringSync();
    if (!text.contains('uses-material-design: false')) {
      errors.add(
        '[flutter-hygiene] apps/bistre_app/pubspec.yaml must declare `uses-material-design: false`.',
      );
    }
    for (final dep in _forbiddenFlutterDeps) {
      if (RegExp('^\\s+$dep:', multiLine: true).hasMatch(text)) {
        errors.add(
          '[flutter-hygiene] apps/bistre_app/pubspec.yaml contains forbidden dependency "$dep".',
        );
      }
    }
  }

  // Enforce Android manifest security & direct-GitHub-only distribution hygiene (ADR-0008, ADR-0010).
  final mainManifest = File(
    '${repoRoot.path}/apps/bistre_app/android/app/src/main/AndroidManifest.xml',
  );
  if (mainManifest.existsSync()) {
    final text = mainManifest.readAsStringSync();
    if (!text.contains('android:allowBackup="false"')) {
      errors.add(
        '[android-hygiene] main AndroidManifest.xml must set android:allowBackup="false".',
      );
    }
    if (!text.contains('android:enableOnBackInvokedCallback="true"')) {
      errors.add(
        '[android-hygiene] main AndroidManifest.xml must set android:enableOnBackInvokedCallback="true".',
      );
    }
  }
  for (final removedFlavor in const <String>['play', 'fdroid']) {
    final flavorDir = Directory(
      '${repoRoot.path}/apps/bistre_app/android/app/src/$removedFlavor',
    );
    if (flavorDir.existsSync()) {
      errors.add(
        '[android-hygiene] Removed store flavor directory android/app/src/$removedFlavor must not exist (direct GitHub distribution only).',
      );
    }
  }
}

/// 4. Verify LF line endings across all text source/config/doc files per `.gitattributes`.
void checkLineEndings(Directory repoRoot, List<String> errors) {
  const textExts = <String>{
    '.rs',
    '.dart',
    '.md',
    '.yml',
    '.yaml',
    '.toml',
    '.json',
    '.kts',
    '.kt',
    '.xml',
    '.properties',
  };
  const exactNames = <String>{
    'justfile',
    '.gitignore',
    '.gitattributes',
    'LICENSE',
  };

  for (final entity in repoRoot.listSync(recursive: true)) {
    if (entity is! File) continue;
    final rel = _relativePath(repoRoot, entity);
    if (_isIgnoredBuildPath(rel)) continue;
    if (rel == 'Cargo.lock' || rel == 'pubspec.lock') continue;
    final name = entity.uri.pathSegments.last;
    final hasTextExt = textExts.any(name.endsWith);
    if (!hasTextExt && !exactNames.contains(name)) continue;

    final bytes = entity.readAsBytesSync();
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 13 && bytes[i + 1] == 10) {
        errors.add(
          '[eol-hygiene] $rel uses CRLF line endings; convert to LF per .gitattributes.',
        );
        break;
      }
    }
  }
}

/// 5. Verify toolchain & SDK versions remain single-source across configs, CI, and docs.
void checkToolchainAndVersionSync(Directory repoRoot, List<String> errors) {
  final rootToolchain = File('${repoRoot.path}/rust-toolchain.toml');
  final ffiToolchain = File(
    '${repoRoot.path}/crates/bistre-ffi/rust-toolchain.toml',
  );
  if (!rootToolchain.existsSync() || !ffiToolchain.existsSync()) {
    errors.add('[version-sync] Missing rust-toolchain.toml file(s).');
    return;
  }

  final rootText = rootToolchain.readAsStringSync();
  final ffiText = ffiToolchain.readAsStringSync();
  if (rootText != ffiText) {
    errors.add(
      '[version-sync] crates/bistre-ffi/rust-toolchain.toml differs from root rust-toolchain.toml.',
    );
  }

  final rustVersion = RegExp(r'channel\s*=\s*"([^"]+)"')
      .firstMatch(rootText)
      ?.group(1);
  if (rustVersion == null) {
    errors.add(
      '[version-sync] Could not parse Rust channel in rust-toolchain.toml.',
    );
    return;
  }

  final clippyToml = File('${repoRoot.path}/clippy.toml');
  if (!clippyToml.existsSync() ||
      !clippyToml.readAsStringSync().contains('msrv = "$rustVersion"')) {
    errors.add(
      '[version-sync] clippy.toml msrv does not match rust-toolchain.toml ($rustVersion).',
    );
  }

  final ciFile = File('${repoRoot.path}/.github/workflows/ci.yml');
  final releaseFile = File('${repoRoot.path}/.github/workflows/release.yml');
  final readmeFile = File('${repoRoot.path}/README.md');
  final gradleFile = File(
    '${repoRoot.path}/apps/bistre_app/android/app/build.gradle.kts',
  );

  for (final pair in <(String, File)>[
    ('.github/workflows/ci.yml', ciFile),
    ('.github/workflows/release.yml', releaseFile),
    ('README.md', readmeFile),
  ]) {
    if (!pair.$2.existsSync()) continue;
    if (!pair.$2.readAsStringSync().contains(rustVersion)) {
      errors.add(
        '[version-sync] ${pair.$1} does not match Rust toolchain version $rustVersion.',
      );
    }
  }

  if (ciFile.existsSync()) {
    final ciText = ciFile.readAsStringSync();
    final flutterVersion = RegExp(
      r'FLUTTER_VERSION:\s*"?([0-9]+\.[0-9]+\.[0-9]+)"?',
    ).firstMatch(ciText)?.group(1);
    if (flutterVersion != null) {
      if (releaseFile.existsSync() &&
          !releaseFile.readAsStringSync().contains(flutterVersion)) {
        errors.add(
          '[version-sync] .github/workflows/release.yml does not match Flutter version $flutterVersion in ci.yml.',
        );
      }
      if (readmeFile.existsSync() &&
          !readmeFile.readAsStringSync().contains(flutterVersion)) {
        errors.add(
          '[version-sync] README.md does not match Flutter version $flutterVersion in ci.yml.',
        );
      }
    }
  }

  if (gradleFile.existsSync()) {
    final ndkVersion = RegExp(r'ndkVersion\s*=\s*"([^"]+)"')
        .firstMatch(gradleFile.readAsStringSync())
        ?.group(1);
    if (ndkVersion != null) {
      for (final pair in <(String, File)>[
        ('.github/workflows/ci.yml', ciFile),
        ('.github/workflows/release.yml', releaseFile),
        ('README.md', readmeFile),
      ]) {
        if (pair.$2.existsSync() &&
            !pair.$2.readAsStringSync().contains(ndkVersion)) {
          errors.add(
            '[version-sync] ${pair.$1} does not match Android ndkVersion $ndkVersion from build.gradle.kts.',
          );
        }
      }
    }
  }
}

/// 6. Verify GitHub Actions workflows satisfy strict security & reliability invariants (mirrors zizmor auditor).
void checkWorkflowSecurity(Directory repoRoot, List<String> errors) {
  final workflowDir = Directory('${repoRoot.path}/.github/workflows');
  if (!workflowDir.existsSync()) {
    errors.add('[ci-security] Missing .github/workflows directory.');
    return;
  }

  final workflows = workflowDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
      .toList();
  if (workflows.isEmpty) {
    errors.add('[ci-security] No workflow YAML files found.');
    return;
  }

  for (final wf in workflows) {
    final rel = _relativePath(repoRoot, wf);
    final text = wf.readAsStringSync();
    final lines = text.split('\n');

    if (!RegExp(r'^permissions:', multiLine: true).hasMatch(text)) {
      errors.add('[ci-security] $rel missing top-level `permissions:` block.');
    }
    if (!RegExp(r'^concurrency:', multiLine: true).hasMatch(text)) {
      errors.add('[ci-security] $rel missing top-level `concurrency:` block.');
    }

    // Check top-level permissions block has no write grants.
    final topPermsMatch = RegExp(
      r'^permissions:\s*\n((?:[ \t]+[^\n]+\n)*)',
      multiLine: true,
    ).firstMatch(text);
    if (topPermsMatch != null &&
        RegExp(r':\s*write\b').hasMatch(topPermsMatch.group(1)!)) {
      errors.add(
        '[ci-security] $rel grants write permissions at workflow root (move write scopes to individual jobs).',
      );
    }

    // Check every `uses:` is pinned to a 40-char lowercase hex commit SHA.
    final usesPattern = RegExp(r'^\s*(?:-\s*)?uses:\s*([^\s#]+)');
    for (var i = 0; i < lines.length; i++) {
      final m = usesPattern.firstMatch(lines[i]);
      if (m == null) continue;
      final target = m.group(1)!;
      if (target.startsWith('./')) continue;
      if (!RegExp(r'@[0-9a-f]{40}$').hasMatch(target)) {
        errors.add(
          '[ci-security] $rel:${i + 1} unpinned action "$target" (must pin to 40-char commit SHA).',
        );
      }
      if (target.startsWith('actions/checkout@')) {
        final windowEnd = (i + 7 < lines.length) ? i + 7 : lines.length;
        final block = lines.sublist(i, windowEnd).join('\n');
        if (!block.contains('persist-credentials: false')) {
          errors.add(
            '[ci-security] $rel:${i + 1} actions/checkout must set `persist-credentials: false`.',
          );
        }
      }
    }

    // Check every job under `jobs:` defines `timeout-minutes:`.
    final jobsIdx = lines.indexWhere((l) => l.trim() == 'jobs:');
    if (jobsIdx != -1) {
      String? currentJob;
      var currentJobLine = 0;
      var hasTimeout = false;
      void finishJob() {
        if (currentJob != null && !hasTimeout) {
          errors.add(
            '[ci-security] $rel:$currentJobLine job "$currentJob" missing `timeout-minutes:`.',
          );
        }
      }

      for (var i = jobsIdx + 1; i < lines.length; i++) {
        final line = lines[i];
        final jobHeader = RegExp(r'^  ([A-Za-z0-9_-]+):\s*$').firstMatch(line);
        if (jobHeader != null) {
          finishJob();
          currentJob = jobHeader.group(1);
          currentJobLine = i + 1;
          hasTimeout = false;
        } else if (currentJob != null &&
            RegExp(r'^    timeout-minutes:\s*\d+').hasMatch(line)) {
          hasTimeout = true;
        }
      }
      finishJob();
    }

    // Check zero `${{ ... }}` template interpolation inside `run:` shell commands.
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final runMatch = RegExp(r'^(\s*)(?:-\s*)?run:\s*(.*)$').firstMatch(line);
      if (runMatch == null) continue;
      final baseIndent = runMatch.group(1)!.length;
      final inlineBody = runMatch.group(2)!.trim();
      if (inlineBody.contains(r'${{')) {
        errors.add(
          '[ci-security] $rel:${i + 1} interpolates GitHub expression inside `run:` (pass via `env:` instead).',
        );
      }
      if (inlineBody == '|' ||
          inlineBody == '|-' ||
          inlineBody == '>' ||
          inlineBody == '>-') {
        for (var j = i + 1; j < lines.length; j++) {
          final next = lines[j];
          if (next.trim().isEmpty) continue;
          final indent = next.length - next.trimLeft().length;
          if (indent <= baseIndent) break;
          if (next.contains(r'${{')) {
            errors.add(
              '[ci-security] $rel:${j + 1} interpolates GitHub expression inside `run:` block (pass via `env:` instead).',
            );
          }
        }
      }
    }
  }

  // Verify Dependabot with supply-chain cooldown exists.
  final dependabot = File('${repoRoot.path}/.github/dependabot.yml');
  if (!dependabot.existsSync()) {
    errors.add(
      '[ci-security] Missing .github/dependabot.yml with cooldown policy.',
    );
  } else {
    final depText = dependabot.readAsStringSync();
    for (final eco in const <String>['github-actions', 'cargo', 'pub']) {
      if (!depText.contains('"$eco"') &&
          !depText.contains("'$eco'") &&
          !depText.contains(' $eco')) {
        errors.add(
          '[ci-security] .github/dependabot.yml missing ecosystem "$eco".',
        );
      }
    }
    if (!depText.contains('cooldown:')) {
      errors.add(
        '[ci-security] .github/dependabot.yml must configure supply-chain `cooldown:`.',
      );
    }
  }
}

List<File> _collectMarkdownFiles(Directory repoRoot) {
  final files = <File>[];
  for (final name in const <String>[
    'AGENTS.md',
    'README.md',
    'CONTRIBUTING.md',
    'SECURITY.md',
    'apps/bistre_app/README.md',
  ]) {
    final f = File('${repoRoot.path}/$name');
    if (f.existsSync()) files.add(f);
  }
  final docsDir = Directory('${repoRoot.path}/docs');
  if (docsDir.existsSync()) {
    for (final e in docsDir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.md')) {
        files.add(e);
      }
    }
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

List<String?> _readLinesStripFencedCode(File file) {
  final raw = file.readAsStringSync().split('\n');
  final out = <String?>[];
  var inFence = false;
  for (final line in raw) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      out.add(null);
      continue;
    }
    out.add(inFence ? null : line);
  }
  return out;
}

String _resolveLinkTarget(Directory baseDir, String relativeTarget) {
  final baseUri = Directory(baseDir.path).uri;
  return File.fromUri(baseUri.resolve(relativeTarget)).path;
}

bool _isSymbolicOrBuildPath(String path) {
  return path.contains('*') ||
      path.contains('..') ||
      path.contains('<') ||
      path.contains('>') ||
      path.contains('{') ||
      path.contains('}') ||
      path.contains('/build/') ||
      path.startsWith('target/');
}

bool _isIgnoredBuildPath(String rel) {
  return rel.startsWith('.git/') ||
      rel.startsWith('.bistre-dev/') ||
      rel.startsWith('.idea/') ||
      rel.contains('/.idea/') ||
      rel.startsWith('.vscode/') ||
      rel.contains('/.vscode/') ||
      rel.startsWith('target/') ||
      rel.startsWith('.dart_tool/') ||
      rel.contains('/.dart_tool/') ||
      rel.contains('/target/') ||
      rel.contains('/build/') ||
      rel.contains('/ephemeral/') ||
      rel.contains('/.gradle/');
}

String _relativePath(Directory root, File file) {
  final rootPath = root.absolute.path.replaceAll('\\', '/');
  final filePath = file.absolute.path.replaceAll('\\', '/');
  if (filePath.startsWith('$rootPath/')) {
    return filePath.substring(rootPath.length + 1);
  }
  return filePath;
}
