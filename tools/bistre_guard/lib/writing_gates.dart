import 'dart:io';

/// Prose and naming gates for the writing rules in `AGENTS.md` section 4: no em dashes,
/// filler words, or emoji anywhere; Markdown carries structure only; names are lowercase.

/// Hard cap on `AGENTS.md` and `tasks.md` (characters).
const int maxDocChars = 10000;

/// Files held to [maxDocChars].
const List<String> docBudgetFiles = <String>['AGENTS.md', 'tasks.md'];

/// Names tools look up exactly; every other file or folder name is lowercase.
const Set<String> toolRequiredNames = <String>{
  'AGENTS.md', 'README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', //
  'CODE_OF_CONDUCT.md',
  'SKILL.md',
  'PULL_REQUEST_TEMPLATE.md',
  'ISSUE_TEMPLATE',
  'Cargo.toml', 'Cargo.lock', 'CMakeLists.txt', 'AndroidManifest.xml',
};

/// This file and its test name the banned words and characters, so they are not scanned.
const Set<String> _selfFiles = <String>{
  'tools/bistre_guard/lib/writing_gates.dart',
  'tools/bistre_guard/test/writing_gates_test.dart',
};

final String _emDash = String.fromCharCode(0x2014);

/// Marketing and filler words that say nothing a plain word would not.
final RegExp slopWords = RegExp(
  r'\b(seamless(ly)?|effortless(ly)?|delv(e|es|ed|ing)|world-class|cutting-edge'
  r'|state-of-the-art|best-in-class|game-?changers?|supercharg(e|es|ed|ing)'
  r'|unleash(es|ed|ing)?|leverag(e|es|ed|ing)|utiliz(e|es|ed|ing|ation)'
  r'|robust(ly|ness)?|bullet-?proof|rock-solid|battle-tested|blazing(ly)?)\b',
  caseSensitive: false,
);

/// Pictographic emoji blocks (symbols, dingbats, and the supplemental planes).
bool _isEmoji(int rune) =>
    (rune >= 0x1F300 && rune <= 0x1FAFF) || (rune >= 0x2600 && rune <= 0x27BF);

const Set<String> _binaryExts = <String>{
  '.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.icns', '.ttf', '.otf', //
  '.woff2', '.vec', '.zip', '.gz', '.wav', '.mp3', '.mp4', '.jar', '.so',
};

bool _isProse(String rel) {
  if (_selfFiles.contains(rel)) return false;
  // Recorded provider streams and lockfiles are data, not writing.
  if (rel.contains('/fixtures/') || rel.endsWith('.lock')) return false;
  if (rel.endsWith('verification-metadata.xml')) return false;
  final dot = rel.lastIndexOf('.');
  final ext = dot < 0 ? '' : rel.substring(dot).toLowerCase();
  return !_binaryExts.contains(ext);
}

/// Em dashes, filler words, emoji, and Markdown headings deeper than `###`.
void checkProse(Directory root, List<String> files, List<String> errors) {
  for (final rel in files) {
    if (!_isProse(rel)) continue;
    final String text;
    try {
      text = File('${root.path}/$rel').readAsStringSync();
    } on FileSystemException {
      // Not UTF-8 text (a binary without a known extension): nothing to read.
      continue;
    }
    final markdown = rel.endsWith('.md');
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final at = '$rel:${i + 1}';
      if (line.contains(_emDash) || line.contains('&mdash;')) {
        errors.add(
          '[writing] $at has an em dash; use a comma, colon, or period.',
        );
      }
      final slop = slopWords.firstMatch(line);
      if (slop != null) {
        errors.add(
          '[writing] $at uses "${slop.group(0)}"; say what it does instead.',
        );
      }
      if (line.runes.any(_isEmoji)) {
        errors.add('[writing] $at has an emoji; use words.');
      }
      if (markdown && line.startsWith('####')) {
        errors.add(
          '[writing] $at nests a heading deeper than ###; flatten it.',
        );
      }
    }
    if (markdown) _checkMarkdown(rel, lines, errors);
  }
}

/// An inline code span (`x`), removed before prose checks so code keeps its symbols.
final RegExp _codeSpan = RegExp(r'`[^`]*`');

/// Markdown that styles words: bold and italics. Structure (headings, bullets) is fine.
final RegExp _emphasis = RegExp(
  r'\*\*[^*\s][^*]*\*\*|__[^_\s][^_]*__|(^|[\s(])\*[^*\s][^*]*\*(?=[\s.,;:)]|$)'
  r'|(^|[\s(])_[^_\s][^_]*_(?=[\s.,;:)]|$)',
);

/// A code span that holds only a number, unit, or comparison: plain text, never code.
final RegExp _numberSpan = RegExp(
  r'^`[<>=~ ]*\d[\d.,_]*\s?(%|x|ms|s|h|min|KiB|MiB|GiB|KB|MB|GB|dp|px|bps|chars|lines)?`$',
);

/// Rule words shouted in capitals; the sentence carries the force in lowercase.
final RegExp _capsEmphasis = RegExp(
  r'\b(MUST|NEVER|ALWAYS|SHALL|SHOULD|ONLY|NOT|IMPORTANT|CRITICAL|REQUIRED)\b',
);

/// Prose punctuation the writing rules ban: exclamation marks and ellipses.
final RegExp _shout = RegExp(r'!(\s|$)|\.\.\.|…');

/// Markdown structure only: no bold, italics, horizontal rules, code spans around plain
/// numbers, capitalised rule words, exclamation marks, or ellipses outside code. YAML front
/// matter is skipped.
void _checkMarkdown(String rel, List<String> lines, List<String> errors) {
  var inFence = false;
  var inFrontMatter = lines.isNotEmpty && lines.first.trim() == '---';
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final at = '$rel:${i + 1}';
    if (inFrontMatter) {
      if (i > 0 && line.trim() == '---') inFrontMatter = false;
      continue;
    }
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    if (RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$').hasMatch(line)) {
      errors.add('[writing] $at has a horizontal rule; use a heading.');
    }
    if (_codeSpan
        .allMatches(line)
        .any((m) => _numberSpan.hasMatch(m.group(0)!))) {
      errors.add(
        '[writing] $at puts a plain number in backticks; write it as text.',
      );
    }
    final prose = line.replaceAll(_codeSpan, '``');
    if (_emphasis.hasMatch(prose)) {
      errors.add('[writing] $at uses bold or italics; let the words carry it.');
    }
    if (_capsEmphasis.hasMatch(prose)) {
      errors.add(
        '[writing] $at shouts a rule word in capitals; write it in lowercase.',
      );
    }
    if (_shout.hasMatch(prose.replaceAll(RegExp(r'!\['), '['))) {
      errors.add(
        '[writing] $at has an exclamation mark or ellipsis; state it plainly.',
      );
    }
  }
}

/// Every file and folder name is lowercase with no spaces, unless a tool needs the exact
/// name ([toolRequiredNames]) or it is a Kotlin class file.
void checkFileNames(Directory root, List<String> files, List<String> errors) {
  final ok = RegExp(r'^\.?[a-z0-9][a-z0-9._-]*$');
  for (final rel in files) {
    final segments = rel.split('/');
    for (var i = 0; i < segments.length; i++) {
      final name = segments[i];
      final isFile = i == segments.length - 1;
      if (ok.hasMatch(name) || toolRequiredNames.contains(name)) continue;
      if (isFile && name.endsWith('.kt') && rel.contains('/kotlin/')) continue;
      errors.add(
        '[naming] $rel: "$name" must be lowercase with "-", "_" or "." only.',
      );
      break;
    }
  }
}

/// `AGENTS.md` and `tasks.md` stay under [maxDocChars]; `tasks.md` lists open work only.
void checkDocBudgets(Directory root, List<String> files, List<String> errors) {
  for (final rel in docBudgetFiles) {
    final f = File('${root.path}/$rel');
    if (!f.existsSync()) continue;
    final text = f.readAsStringSync();
    final chars = text.runes.length;
    if (chars > maxDocChars) {
      errors.add('[doc-budget] $rel has $chars characters (> $maxDocChars).');
    }
    if (rel != 'tasks.md') continue;
    final finished = RegExp(r'^\s*-\s+(\[(v|g)\]|done:)');
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (finished.hasMatch(lines[i])) {
        errors.add(
          '[doc-budget] tasks.md:${i + 1} lists finished work; delete it.',
        );
      }
    }
  }
}
