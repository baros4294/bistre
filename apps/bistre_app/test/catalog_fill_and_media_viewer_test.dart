import 'dart:convert';
import 'dart:io';

import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/chat_overlays.dart';
import 'package:bistre_app/features/settings/provider_subpages.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:bistre_app/platform/desktop_host.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

void main() {
  test('catalog prices fill in exactly, never rounded to cents', () {
    expect(microsAsDollars(75000), '0.075');
    expect(microsAsDollars(18750), '0.01875');
    expect(microsAsDollars(2500000), '2.50');
    expect(microsAsDollars(15000000), '15.00');
    expect(microsAsDollars(1), '0.000001');
    expect(microsAsDollars(0), '0.00');
  });

  testWidgets('the viewer offers exactly the actions it is given', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    var opened = 0;
    await tester.pumpWidget(
      _viewer(
        shell,
        const ComposerAttachment(
          id: 'v',
          name: 'clip.mp4',
          mimeType: 'video/mp4',
          path: 'clip.mp4',
          sizeBytes: 10,
        ),
        onOpenInApp: () => opened++,
        onOpenFolder: () {},
      ),
    );
    await tester.pump();
    expect(find.text('Open in default app'), findsOneWidget);
    expect(find.text('Open folder'), findsOneWidget);
    expect(find.text('Play'), findsNothing);
    expect(find.text('Save a copy'), findsNothing);
    expect(find.text('This file can’t be shown here.'), findsOneWidget);
    await tester.tap(find.text('Open in default app'));
    expect(opened, 1);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a picture offers Copy picture when it is given', (tester) async {
    final shell = await ShellHarness.pump(tester);
    var copied = 0;
    await tester.pumpWidget(
      _viewer(
        shell,
        const ComposerAttachment(
          id: 'p',
          name: 'p.png',
          mimeType: 'image/png',
          path: 'p.png',
          sizeBytes: 1,
          isImage: true,
        ),
        onCopyPicture: () => copied++,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Copy picture'));
    expect(copied, 1);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Copy picture hands the host the decoded pixels', (tester) async {
    final dir = Directory.systemTemp.createTempSync('bistre_copy_picture_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}dot.png')
      ..writeAsBytesSync(base64Decode(_kOnePixelPng));
    final calls = <MethodCall>[];
    const host = MethodChannel('bistre/desktop_host');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(host, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(host, null));
    final copied = await tester.runAsync(
      () => BistreDesktopHost.copyPicture(file.path),
    );
    expect(copied, isTrue);
    expect(calls.single.method, 'copyPicture');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['width'], 1);
    expect(args['height'], 1);
    expect((args['rgba']! as Uint8List).length, 4);
    await tester.pump(const Duration(seconds: 9));
  });

  test('a path starting with two slashes is never opened as a local file', () {
    expect(BistreDesktopHost.isSafeLocalFile(r'\\server\share\a.png'), isFalse);
    expect(BistreDesktopHost.isSafeLocalFile('//server/share/a.png'), isFalse);
    // A Windows extended-length path names a real local file, yet starts like a share.
    final dir = Directory.systemTemp.createTempSync('bistre_safe_file_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}a.png')
      ..writeAsBytesSync(<int>[0]);
    expect(BistreDesktopHost.isSafeLocalFile(file.path), isTrue);
    if (Platform.isWindows) {
      expect(BistreDesktopHost.isSafeLocalFile('\\\\?\\${file.path}'), isFalse);
    }
  });

  testWidgets('a file with no actions shows no action row', (tester) async {
    final shell = await ShellHarness.pump(tester);
    await tester.pumpWidget(
      _viewer(
        shell,
        const ComposerAttachment(
          id: 'p',
          name: 'p.png',
          mimeType: 'image/png',
          path: '',
          sizeBytes: 1,
          isImage: true,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(EngravedButton), findsNothing);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a long text file shows its start as text with Copy', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final dir = Directory.systemTemp.createTempSync('bistre_viewer_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/notes.md')
      ..writeAsStringSync('# Title\n${'x' * (kMaxViewerTextBytes + 10)}');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    var copies = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _viewer(
          shell,
          ComposerAttachment(
            id: 't',
            name: 'notes.md',
            mimeType: 'text/markdown',
            path: file.path,
            sizeBytes: file.lengthSync(),
          ),
          onCopied: () => copies++,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.textContaining('# Title'), findsOneWidget);
    expect(
      find.text(
        shell.l10n.t(L10nKey.viewerTextCut, <String, Object?>{
          'size': shell.l10n.fileSize(kMaxViewerTextBytes),
        }),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is BistreIconButton && w.icon == BistreUiIcon.copy,
      ),
    );
    await tester.pump();
    expect(copied?.length, kMaxViewerTextBytes);
    expect(copies, 1);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('each file gets the actions its platform and kind allow', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    ComposerAttachment file(String name, String mime) =>
        ComposerAttachment(id: name, name: name, mimeType: mime, path: name);
    final desktop = Platform.isWindows || Platform.isLinux;
    expect(ctrl.canOpenFolderOf(file('p.png', 'image/png')), desktop);
    expect(ctrl.canOpenInAppOf(file('report.pdf', 'application/pdf')), desktop);
    expect(
      ctrl.canOpenInAppOf(file('run.bat', 'text/plain')),
      isFalse,
      reason: 'a script is never handed to the system',
    );
    expect(
      ctrl.canPlayOf(file('voice.wav', 'audio/wav')),
      Platform.isWindows || Platform.isAndroid,
    );
    expect(ctrl.canPlayOf(file('song.mp3', 'audio/mpeg')), isFalse);
    expect(ctrl.canSaveCopyOf(file('a.txt', 'text/plain')), Platform.isWindows);
    expect(isViewerText('application/json'), isTrue);
    expect(isViewerText('application/vnd.api+json'), isTrue);
    expect(isViewerText('application/pdf'), isFalse);
    await tester.pump(const Duration(seconds: 9));
  });
}

Widget _viewer(
  ShellHarness shell,
  ComposerAttachment attachment, {
  VoidCallback? onOpenInApp,
  VoidCallback? onOpenFolder,
  VoidCallback? onCopyPicture,
  VoidCallback? onCopied,
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: BistreLocalizations(
    controller: shell.l10n,
    child: BistreTheme(
      data: BistreThemeData.warmSepia,
      // Selectable text needs an overlay, as the app gives it.
      child: Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(
            builder: (_) => AttachmentViewerModal(
              attachment: attachment,
              reduceMotionOverride: true,
              onClose: () {},
              onOpenInApp: onOpenInApp,
              onOpenFolder: onOpenFolder,
              onCopyPicture: onCopyPicture,
              onCopied: onCopied,
            ),
          ),
        ],
      ),
    ),
  ),
);

/// A valid 1 by 1 PNG.
const String _kOnePixelPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
