import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Pumps frame by frame through a sidebar toggle and records the chat area's width.
Future<Set<double>> _chatWidthsDuringToggle(
  WidgetTester tester,
  ShellHarness shell,
) async {
  final chat = find.byType(BistreScaffold).first;
  final widths = <double>{tester.getSize(chat).width};
  shell.controller.toggleSidebar();
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    widths.add(tester.getSize(chat).width);
  }
  return widths;
}

void main() {
  for (final rtl in [false, true]) {
    testWidgets(
      'opening or closing the sidebar lays the chat out once (3a, rtl: $rtl)',
      (tester) async {
        final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
        final chat = gateway.seedThread(title: 'Chat', updatedAtMs: 1000);
        await gateway.appendNode(
          threadId: chat.id,
          role: 'user',
          content: 'hello',
        );
        final shell = await ShellHarness.pump(
          tester,
          gateway: gateway,
          locale: rtl ? 'ar' : 'en',
        );
        expect(shell.controller.sidebarOpen, isTrue);

        final closing = await _chatWidthsDuringToggle(tester, shell);
        expect(
          closing,
          hasLength(2),
          reason:
              'the chat area takes its final width once, then only slides: $closing',
        );
        final opening = await _chatWidthsDuringToggle(tester, shell);
        expect(opening, hasLength(2), reason: '$opening');
      },
    );
  }

  testWidgets('a closed sidebar stays mounted and keeps its state (3a)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final before = tester.element(
      find.byType(FolioSidebar, skipOffstage: false),
    );
    shell.controller.toggleSidebar();
    await tester.pumpAndSettle();
    expect(
      find.byType(FolioSidebar),
      findsNothing,
      reason: 'hidden when closed',
    );
    shell.controller.toggleSidebar();
    await tester.pumpAndSettle();
    expect(
      identical(tester.element(find.byType(FolioSidebar)), before),
      isTrue,
      reason: 'reopening does not rebuild the sidebar from scratch',
    );
  });

  testWidgets(
    'one sidebar toggle, and the settings button never disappears (3b)',
    (tester) async {
      final shell = await ShellHarness.pump(tester);
      final toggles = find.bySemanticsLabel(shell.t(L10nKey.sidebarToggle));
      final settings = find.bySemanticsLabel(shell.t(L10nKey.sidebarSettings));
      final semantics = tester.ensureSemantics();
      await tester.pumpAndSettle();
      expect(toggles, findsOneWidget, reason: 'open');
      final settingsOpen = tester.widgetList(settings).length;
      shell.controller.toggleSidebar();
      await tester.pumpAndSettle();
      expect(toggles, findsOneWidget, reason: 'closed');
      expect(
        tester.widgetList(settings).length,
        greaterThanOrEqualTo(1),
        reason: 'settings stays reachable from the header',
      );
      expect(settingsOpen, greaterThanOrEqualTo(1));
      semantics.dispose();
    },
  );
}
