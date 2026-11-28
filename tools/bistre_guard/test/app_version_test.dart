import 'dart:io';

import 'package:bistre_guard/app_version.dart';
import 'package:test/test.dart';

AppVersion _v(String semver, int build) =>
    AppVersion.parse(semver, build: build)!;

void main() {
  test(
    'a pull request ships the patch after main, or its own larger version',
    () {
      final main = _v('0.2.0', 4);
      expect(versionAbove(_v('0.2.0', 4), main).toString(), '0.2.1+5');
      expect(
        versionAbove(_v('0.1.9', 9), main).toString(),
        '0.2.1+10',
        reason: 'an older branch still ends above main',
      );
      expect(
        versionAbove(_v('1.0.0', 5), main).toString(),
        '1.0.0+5',
        reason: 'a jump set by hand is kept',
      );
      expect(
        versionAbove(_v('1.0.0', 4), main).toString(),
        '1.0.0+5',
        reason: 'the build number still grows',
      );
    },
  );

  test('bump steps one part and resets the smaller ones', () {
    final v = _v('1.4.7', 12);
    expect(v.bumped('patch').toString(), '1.4.8+13');
    expect(v.bumped('minor').toString(), '1.5.0+13');
    expect(v.bumped('major').toString(), '2.0.0+13');
    expect(() => v.bumped('huge'), throwsArgumentError);
  });

  test('Cargo and pubspec must agree', () {
    expect(
      () => parseAppVersion(
        '[workspace.package]\nversion = "0.2.0"\n',
        'version: 0.3.0+1\n',
      ),
      throwsFormatException,
    );
  });

  test(
    'a written version lands in Cargo.toml, its own lock entries, and pubspec',
    () {
      final root = Directory.systemTemp.createTempSync('bistre-version-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/Cargo.toml').writeAsStringSync(
        '[workspace]\nmembers = []\n\n[workspace.package]\nversion = "0.2.0"\nedition = "2024"\n\n[workspace.dependencies]\nserde = { version = "1" }\n',
      );
      File('${root.path}/Cargo.lock').writeAsStringSync(
        '[[package]]\nname = "bistre-core"\nversion = "0.2.0"\n\n[[package]]\nname = "zip"\nversion = "0.2.0"\n',
      );
      Directory('${root.path}/apps/bistre_app').createSync(recursive: true);
      File('${root.path}/apps/bistre_app/pubspec.yaml')
          .writeAsStringSync('name: bistre_app\nversion: 0.2.0+4\n');
      writeAppVersion(root, _v('0.3.0', 5));
      expect(readAppVersion(root).toString(), '0.3.0+5');
      final lock = File('${root.path}/Cargo.lock').readAsStringSync();
      expect(lock, contains('name = "bistre-core"\nversion = "0.3.0"'));
      expect(
        lock,
        contains('name = "zip"\nversion = "0.2.0"'),
        reason: 'other crates keep their versions',
      );
      expect(
        File('${root.path}/Cargo.toml').readAsStringSync(),
        contains('serde = { version = "1" }'),
      );
    },
  );
}
