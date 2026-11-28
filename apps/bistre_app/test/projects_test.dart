import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/chat/folio_composer.dart';
import 'package:bistre_app/features/inspector/chat_inspector_drawer.dart';
import 'package:bistre_app/features/settings/projects_settings_view.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/features/sidebar/folio_sidebar.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// Projects: the sidebar groups chats under them, a chat starts in one, the chat settings
/// move a chat between them, and Settings creates and deletes them.
Finder _inSidebar(Finder f) =>
    find.descendant(of: find.byType(FolioSidebar), matching: f);

Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is EngravedButton && w.label == label);

/// A project `Novel` holding the chat `Draft chapter`, and a newer chat `Loose` outside it.
FakeEngineGateway _withProject() {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final draft = gateway.seedThread(title: 'Draft chapter', updatedAtMs: 1000);
  gateway.seedThread(title: 'Loose', updatedAtMs: 2000);
  gateway.projects.add(const EngineProject(id: 'p1', name: 'Novel'));
  final at = gateway.chatThreads.indexWhere((t) => t.id == draft.id);
  gateway.chatThreads[at] = draft.withWorkspace('p1');
  return gateway;
}

void main() {
  for (final rtl in [false, true]) {
    testWidgets(
      'the sidebar lists a project with its chats first (rtl: $rtl)',
      (tester) async {
        final shell = await ShellHarness.pump(
          tester,
          gateway: _withProject(),
          locale: rtl ? 'ar' : 'en',
        );
        final project = _inSidebar(find.text('Novel'));
        final inside = _inSidebar(find.text('Draft chapter'));
        final loose = _inSidebar(find.text('Loose'));
        expect(project, findsOneWidget);
        expect(
          tester.getTopLeft(project).dy,
          lessThan(tester.getTopLeft(inside).dy),
        );
        expect(
          tester.getTopLeft(inside).dy,
          lessThan(tester.getTopLeft(loose).dy),
          reason: 'project chats come before the date groups',
        );
        // Indented one step toward the reading end, mirrored in RTL.
        final insideStart = rtl
            ? tester.getTopRight(inside).dx
            : tester.getTopLeft(inside).dx;
        final looseStart = rtl
            ? tester.getTopRight(loose).dx
            : tester.getTopLeft(loose).dx;
        expect(
          rtl ? insideStart < looseStart : insideStart > looseStart,
          isTrue,
        );

        await tester.tap(project);
        await tester.pumpAndSettle();
        expect(
          inside,
          findsNothing,
          reason: 'tapping the project hides its chats',
        );
        expect(
          shell.controller.threads.any((t) => t.title == 'Draft chapter'),
          isTrue,
        );
      },
    );
  }

  testWidgets('New chat on a project row starts the chat in that project', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester, gateway: _withProject());
    await tester.tap(
      _iconButton(
        shell.t(L10nKey.sidebarProjectNewChatIn, <String, Object?>{
          'name': 'Novel',
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(shell.controller.activeThread?.workspaceId, 'p1');
    expect(shell.controller.workspaceRootPath, isEmpty);
  });

  testWidgets('a project folder becomes the open chat folder', (tester) async {
    final gateway = _withProject();
    gateway.projects[0] = const EngineProject(
      id: 'p1',
      name: 'Novel',
      folderPath: '/books/novel',
    );
    final shell = await ShellHarness.pump(tester, gateway: gateway);
    final draft = shell.controller.threads.firstWhere(
      (t) => t.title == 'Draft chapter',
    );
    await shell.controller.selectThread(draft.id);
    await tester.pumpAndSettle();
    expect(shell.controller.workspaceRootPath, '/books/novel');
    final loose = shell.controller.threads.firstWhere(
      (t) => t.title == 'Loose',
    );
    await shell.controller.selectThread(loose.id);
    await tester.pumpAndSettle();
    expect(
      shell.controller.workspaceRootPath,
      shell.controller.appWorkspaceRootPath,
    );
  });

  testWidgets(
    'a project folder shows its hooks in Settings and Allow approves that '
    'folder',
    (tester) async {
      final gateway = _withProject();
      gateway.projects[0] = const EngineProject(
        id: 'p1',
        name: 'Novel',
        folderPath: '/books/novel',
      );
      gateway.workspaceHooks = const EngineWorkspaceHooksStatus(
        hooks: <EngineWorkspaceHook>[
          EngineWorkspaceHook(event: 'pre_tool_use', command: 'lint.sh'),
        ],
        digest: 'd1',
        approved: false,
      );
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      shell.controller.openProjectEditor('p1');
      await tester.pumpAndSettle();
      final view = find.byType(ProjectsSettingsView);
      expect(
        find.descendant(of: view, matching: find.text('lint.sh')),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: view,
          matching: _button(shell.t(L10nKey.settingsAgentHooksAllow)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        gateway.callsTo('approveWorkspaceHooks').single.args,
        <String, Object?>{'workspaceRoot': '/books/novel', 'digest': 'd1'},
      );
      expect(
        find.descendant(
          of: view,
          matching: find.text(shell.t(L10nKey.settingsAgentHooksAllowed)),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
    },
  );

  testWidgets(
    'the composer folder button of a project chat opens the project',
    (tester) async {
      final gateway = _withProject();
      gateway.projects[0] = const EngineProject(
        id: 'p1',
        name: 'Novel',
        folderPath: '/books/novel',
      );
      final shell = await ShellHarness.pump(tester, gateway: gateway);
      final draft = shell.controller.threads.firstWhere(
        (t) => t.title == 'Draft chapter',
      );
      await shell.controller.selectThread(draft.id);
      await tester.pumpAndSettle();
      expect(
        _iconButton(shell.t(L10nKey.settingsAgentAddFolder)),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(FolioComposer),
          matching: _iconButton(
            shell.t(L10nKey.sidebarProjectSettings, <String, Object?>{
              'name': 'Novel',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(shell.controller.editingProjectId, 'p1');
      expect(find.byType(ProjectsSettingsView), findsOneWidget);

      // `@mount` also opens the project rather than picking an app folder.
      shell.controller.closeSettings();
      await tester.pumpAndSettle();
      final appFolder = shell.controller.appWorkspaceRootPath;
      await tester.enterText(find.byType(EditableText).last, '@mount');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ProjectsSettingsView), findsOneWidget);
      expect(shell.controller.appWorkspaceRootPath, appFolder);
    },
  );

  testWidgets('the chat settings move the open chat into a project (phone)', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(
      tester,
      gateway: _withProject(),
      layout: ShellLayout.phone,
    );
    final loose = shell.controller.threads.firstWhere(
      (t) => t.title == 'Loose',
    );
    await shell.controller.selectThread(loose.id);
    shell.controller.toggleInspector();
    await tester.pumpAndSettle();
    final choice = find.descendant(
      of: find.byType(ChatInspectorDrawer),
      matching: find.text('Novel'),
    );
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
    expect(
      shell.gateway.callsTo('moveThreadToProject').single.args['projectId'],
      'p1',
    );
    expect(shell.controller.activeThread?.workspaceId, 'p1');
  });

  for (final layout in ShellLayout.values) {
    testWidgets('Settings creates a project and deleting it keeps its chats '
        '(${layout.name})', (tester) async {
      final shell = await ShellHarness.pump(
        tester,
        gateway: _withProject(),
        layout: layout,
      );
      shell.controller.openProjectEditor('');
      await tester.pumpAndSettle();
      await tester.enterText(
        find
            .descendant(
              of: find.byType(ProjectsSettingsView),
              matching: find.byType(EditableText),
            )
            .first,
        'Thesis',
      );
      await tester.tap(_button(shell.t(L10nKey.settingsProjectsCreate)));
      await tester.pumpAndSettle();
      expect(shell.gateway.projects.map((p) => p.name), contains('Thesis'));

      shell.controller.openProjectEditor('p1');
      await tester.pumpAndSettle();
      final delete = _button(shell.t(L10nKey.settingsProjectsDelete));
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(shell.gateway.projects.any((p) => p.id == 'p1'), isTrue);
      final confirm = _button(shell.t(L10nKey.settingsProjectsDeleteConfirm));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(shell.gateway.projects.any((p) => p.id == 'p1'), isFalse);
      final kept = shell.controller.threads.firstWhere(
        (t) => t.title == 'Draft chapter',
      );
      expect(shell.controller.projectOf(kept), isNull);
      // The Deleted toast times out.
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
