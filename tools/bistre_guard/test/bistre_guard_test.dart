import 'dart:io';

import 'package:bistre_guard/bistre_guard.dart';
import 'package:test/test.dart';

Directory _repoRoot() =>
    File('../../AGENTS.md').existsSync() ? Directory('../..') : Directory('.');

void main() {
  test(
    'repository passes all mechanical code, doc, version, and CI guards',
    () {
      final result = runRepoGuards(_repoRoot());
      expect(result.isValid, isTrue, reason: result.errors.join('\n'));
    },
  );

  test('guards catch broken markdown links, unpinned CI actions, and template injection', () {
    final tmp = Directory.systemTemp.createTempSync('bistre_guard_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    File('${tmp.path}/AGENTS.md')
        .writeAsStringSync('# AGENTS\nSee [broken](docs/missing.md).\n');
    Directory('${tmp.path}/.github/workflows').createSync(recursive: true);
    File('${tmp.path}/.github/workflows/bad.yml').writeAsStringSync('''
name: Bad
on: push
permissions:
  contents: write
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - run: echo "\${{ github.ref_name }}"
''');

    final linkErrors = <String>[];
    checkMarkdownLinks(tmp, linkErrors);
    expect(linkErrors.join('\n'), contains('broken relative link'));

    final ciErrors = <String>[];
    checkWorkflowSecurity(tmp, ciErrors);
    final ciJoined = ciErrors.join('\n');
    expect(ciJoined, contains('write permissions at workflow root'));
    expect(ciJoined, contains('unpinned action'));
    expect(ciJoined, contains('missing `timeout-minutes:`'));
    expect(ciJoined, contains('interpolates GitHub expression inside `run:`'));
    expect(ciJoined, contains('Missing .github/dependabot.yml'));
  });
}
