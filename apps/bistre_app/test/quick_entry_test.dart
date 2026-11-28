import 'dart:io';

import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/folio_composer.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Quick entry (Windows): Settings > Shortcuts records, refuses, and turns off the shortcut
/// that works from any app, and the host's press opens a new chat with the composer focused.
const MethodChannel _host = MethodChannel('bistre/desktop_host');

/// Answers the host's `setQuickEntryHotkey` with [registers] and records each combo asked.
List<String> _mockHost(WidgetTester tester, {bool registers = true}) {
  final combos = <String>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_host, (call) async {
    if (call.method != 'setQuickEntryHotkey') return null;
    combos.add((call.arguments as Map<Object?, Object?>)['combo']! as String);
    return registers;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_host, null));
  return combos;
}

Future<ShellHarness> _shortcuts(WidgetTester tester) async {
  final shell = await ShellHarness.pump(tester);
  shell.controller.openSettings(SettingsTab.shortcuts);
  await tester.pumpAndSettle();
  return shell;
}

Future<void> _record(
  WidgetTester tester,
  ShellHarness shell,
  List<LogicalKeyboardKey> modifiers,
  LogicalKeyboardKey key,
) async {
  final row = find.text(shell.t(L10nKey.shortcutsQuickEntry));
  await tester.ensureVisible(row);
  await tester.tap(row);
  await tester.pumpAndSettle();
  for (final m in modifiers) {
    await tester.sendKeyDownEvent(m);
  }
  await tester.sendKeyEvent(key);
  for (final m in modifiers.reversed) {
    await tester.sendKeyUpEvent(m);
  }
  await tester.pumpAndSettle();
}

void main() {
  final skip = !Platform.isWindows;

  testWidgets(
    'the default shortcut is registered at start and can be changed',
    (tester) async {
      final combos = _mockHost(tester);
      final shell = await _shortcuts(tester);
      expect(combos.first, kDefaultQuickEntryShortcut);
      await _record(tester, shell, [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ], LogicalKeyboardKey.keyK);
      expect(shell.controller.uiPrefs.quickEntryShortcut, 'Ctrl+Alt+K');
      expect(combos.last, 'Ctrl+Alt+K');
      await tester.pump(const Duration(seconds: 3));
    },
    skip: skip,
  );

  testWidgets(
    'the taken notice shows only when the host says another app holds the shortcut',
    (tester) async {
      _mockHost(tester, registers: false);
      final shell = await _shortcuts(tester);
      final taken = find.text(shell.t(L10nKey.shortcutsQuickEntryRefused));
      expect(taken, findsOneWidget);

      // A host without the method (an older runner) is not "another app".
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _host,
        (call) async => throw MissingPluginException(),
      );
      await shell.controller.setQuickEntryShortcut('Ctrl+Alt+K');
      await tester.pumpAndSettle();
      expect(taken, findsNothing);
      await tester.pump(const Duration(seconds: 3));
    },
    skip: skip,
  );

  testWidgets('a bare function key or an in-app shortcut is refused', (
    tester,
  ) async {
    final combos = _mockHost(tester);
    final shell = await _shortcuts(tester);
    await _record(tester, shell, const [], LogicalKeyboardKey.f5);
    expect(find.text(shell.t(L10nKey.shortcutsNeedsModifier)), findsWidgets);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.text(
        shell.t(L10nKey.shortcutsTaken, <String, Object?>{
          'action': shell.t(L10nKey.shortcutPalette),
        }),
      ),
      findsWidgets,
    );
    expect(combos, [kDefaultQuickEntryShortcut], reason: 'nothing new asked');
  }, skip: skip);

  testWidgets('a shortcut another app holds is reported; Turn off clears it', (
    tester,
  ) async {
    final combos = _mockHost(tester, registers: false);
    final shell = await _shortcuts(tester);
    expect(
      find.text(shell.t(L10nKey.shortcutsQuickEntryRefused)),
      findsOneWidget,
    );
    final off = find.byWidgetPredicate(
      (w) =>
          w is EngravedButton && w.label == shell.t(L10nKey.shortcutsTurnOff),
    );
    await tester.ensureVisible(off);
    await tester.tap(off);
    await tester.pumpAndSettle();
    expect(shell.controller.uiPrefs.quickEntryShortcut, isEmpty);
    expect(combos.last, isEmpty);
    expect(find.text(shell.t(L10nKey.shortcutsOff)), findsOneWidget);
    expect(
      find.text(shell.t(L10nKey.shortcutsQuickEntryRefused)),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3));
  }, skip: skip);

  testWidgets('the host press opens a new chat with the composer focused', (
    tester,
  ) async {
    _mockHost(tester);
    final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
    final chat = gateway.seedThread(title: 'Trip', updatedAtMs: 1000);
    gateway.seedNode(threadId: chat.id, role: 'user', content: 'Where to?');
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    shell.controller.openSettings(SettingsTab.appearance);
    await tester.pumpAndSettle();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _host.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onQuickEntry'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(shell.controller.settingsOpen, isFalse);
    expect(shell.controller.activeThread?.id, isNot(chat.id));
    expect(shell.controller.visibleBranchNodes, isEmpty);
    final field = tester.widget<EditableText>(
      find.descendant(
        of: find.byType(FolioComposer),
        matching: find.byType(EditableText),
      ),
    );
    expect(field.focusNode.hasFocus, isTrue);

    // A second press keeps the empty chat instead of making another.
    final threads = shell.controller.threads.length;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      _host.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onQuickEntry'),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(shell.controller.threads.length, threads);
  }, skip: skip);
}
