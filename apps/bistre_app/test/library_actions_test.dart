import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/bistre_icons.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/settings/mcp_token_row.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_engine_gateway.dart';
import 'support/shell_harness.dart';

/// A chat's files in Studio, Bistre's skills, `/draft` and `/guide`, a new chat on another
/// assistant, saved prompts, and erasing everything at the next start.
Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is BistreIconButton && w.semanticsLabel == label,
);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is EngravedButton && w.label == label);

FakeEngineGateway _chat() {
  final gateway = FakeEngineGateway(seedConnectedOpenAi: true);
  final thread = gateway.seedThread(title: 'Trip', updatedAtMs: 2000);
  final ask = gateway.seedNode(
    threadId: thread.id,
    role: 'user',
    content: 'Where to?',
  );
  gateway.seedNode(
    threadId: thread.id,
    parentId: ask.id,
    role: 'assistant',
    content: 'Porto.',
  );
  return gateway;
}

Future<ShellHarness> _open(
  WidgetTester tester,
  FakeEngineGateway g, {
  ShellLayout layout = ShellLayout.phone,
}) async {
  final shell = await ShellHarness.pump(tester, gateway: g, layout: layout);
  await shell.controller.selectThread(shell.controller.threads.first.id);
  await tester.pumpAndSettle();
  return shell;
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(EditableText).last, text);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

EngineChatFile _file(String name, {required bool fromUser}) => EngineChatFile(
  nodeId: 'node-1',
  fromUser: fromUser,
  name: name,
  mimeType: 'image/png',
  sizeBytes: 2048,
  blobRelPath: 'attachments/$name',
  createdAtMs: 1,
);

void main() {
  testWidgets('Studio Files lists the chat files and filters sent from made', (
    tester,
  ) async {
    final gateway = _chat();
    gateway.chatFiles['thread-1'] = <EngineChatFile>[
      _file('made.png', fromUser: false),
      _file('sent.png', fromUser: true),
    ];
    final shell = await _open(tester, gateway, layout: ShellLayout.desktop);
    shell.controller.setStudioTab(StudioTab.files);
    await tester.pumpAndSettle();
    expect(find.text('made.png'), findsOneWidget);
    expect(find.text('sent.png'), findsOneWidget);

    await tester.tap(find.text(shell.t(L10nKey.studioFilesSent)).first);
    await tester.pumpAndSettle();
    expect(find.text('sent.png'), findsOneWidget);
    expect(find.text('made.png'), findsNothing);

    await tester.tap(find.text(shell.t(L10nKey.studioFilesEdited)));
    await tester.pumpAndSettle();
    expect(find.text(shell.t(L10nKey.studioFilesNoneOfKind)), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a reply is saved as one of Bistre\'s skills', (tester) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final reply = shell.controller.visibleBranchNodes.last;
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionMore)).last);
    await tester.pumpAndSettle();
    await tester.tap(_iconButton(shell.t(L10nKey.chatActionSaveSkill)));
    await tester.pumpAndSettle();
    expect(gateway.callsTo('saveReplyAsSkill').single.args['nodeId'], reply.id);
    expect(shell.controller.appSkills, hasLength(1));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/draft writes the next message into the field, unsent', (
    tester,
  ) async {
    final gateway = _chat()..draftedMessage = 'And after Porto?';
    final shell = await _open(tester, gateway);
    await _type(tester, '/draft ask about Braga');
    expect(
      gateway.callsTo('draftNextMessage').single.args['note'],
      'ask about Braga',
    );
    final field = tester.widget<EditableText>(find.byType(EditableText).last);
    expect(field.controller.text, 'And after Porto?');
    expect(gateway.callsTo('sendAndStreamReply'), isEmpty);
    expect(shell.controller.visibleBranchNodes, hasLength(2));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('/guide regenerates the last reply the way it says', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final ask = shell.controller.visibleBranchNodes.first;
    await _type(tester, '/guide shorter, as a list');
    final call = gateway.callsTo('regenerateReplyGuided').single;
    expect(call.args['userNodeId'], ask.id);
    expect(call.args['guidance'], 'shorter, as a list');
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('another assistant opens a new chat when that is on', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway);
    final ctrl = shell.controller;
    await ctrl.createCustomAssistant(
      name: 'Writer',
      roleSubtitle: '',
      systemPrompt: '',
    );
    // Creating Writer chose it for this chat; switching back now opens a new chat.
    expect(ctrl.activeThread?.id, 'thread-1');
    final updatesBefore = gateway.callsTo('updateThread').length;
    await ctrl.saveUiPrefs(
      ctrl.uiPrefs.copyWith(newChatOnAssistantSwitch: true),
      quiet: true,
    );
    await ctrl.selectAssistant('default_assistant');
    await tester.pumpAndSettle();
    expect(ctrl.activeThread?.id, isNot('thread-1'));
    expect(ctrl.activeThread?.assistantId, 'default_assistant');
    expect(gateway.callsTo('updateThread'), hasLength(updatesBefore));
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('a saved prompt fills the instructions again', (tester) async {
    final shell = await _open(tester, _chat());
    final ctrl = shell.controller;
    await ctrl.savePromptPreset('Be brief.\nAnswer in lists.');
    expect(ctrl.promptPresets.single.name, 'Be brief.');
    await ctrl.savePromptPreset('Be brief.\nOne line only.');
    expect(ctrl.promptPresets.single.text, 'Be brief.\nOne line only.');
    await ctrl.deletePromptPreset(ctrl.promptPresets.single);
    expect(ctrl.promptPresets, isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('an HTTP MCP server keeps a token in the vault; stdio has none', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway, layout: ShellLayout.desktop);
    final ctrl = shell.controller;
    await ctrl.addMcpServer(
      const EngineMcpServerConfig(
        id: 'mcp_local',
        name: 'Local',
        transport: 'stdio',
        command: 'mcp-local',
      ),
    );
    await ctrl.addMcpServer(
      const EngineMcpServerConfig(
        id: 'mcp_remote',
        name: 'Remote',
        transport: 'http',
        url: 'https://mcp.example.com/mcp',
      ),
    );
    ctrl.openSettings(SettingsTab.agent);
    await tester.pumpAndSettle();
    final add = _button(shell.t(L10nKey.settingsAgentMcpTokenAdd));
    expect(add, findsOneWidget);
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    Finder inRow(Finder f) =>
        find.descendant(of: find.byType(McpTokenRow), matching: f);
    await tester.enterText(inRow(find.byType(EditableText)), 'secret-token');
    await tester.tap(inRow(_button(shell.t(L10nKey.threadSave))));
    await tester.pumpAndSettle();
    expect(gateway.mcpTokens, <String>{'mcp_remote'});
    expect(
      find.text(shell.t(L10nKey.settingsAgentMcpTokenSaved)),
      findsOneWidget,
    );
    expect(find.text('secret-token'), findsNothing);

    await tester.tap(_button(shell.t(L10nKey.settingsAgentMcpTokenChange)));
    await tester.pumpAndSettle();
    await tester.tap(inRow(_button(shell.t(L10nKey.shellRemove))));
    await tester.pumpAndSettle();
    expect(gateway.mcpTokens, isEmpty);
    expect(add, findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('erasing everything takes two presses and can be withdrawn', (
    tester,
  ) async {
    final gateway = _chat();
    final shell = await _open(tester, gateway, layout: ShellLayout.desktop);
    shell.controller.openSettings(SettingsTab.updates);
    await tester.pumpAndSettle();
    final erase = _button(shell.t(L10nKey.settingsStorageEraseAction));
    await tester.ensureVisible(erase);
    await tester.pumpAndSettle();
    await tester.tap(erase);
    await tester.pumpAndSettle();
    expect(gateway.callsTo('requestDataWipe'), isEmpty);
    await tester.tap(_button(shell.t(L10nKey.settingsStorageEraseConfirm)));
    await tester.pumpAndSettle();
    expect(gateway.callsTo('requestDataWipe'), hasLength(1));
    expect(
      find.text(shell.t(L10nKey.settingsStorageErasePending)),
      findsOneWidget,
    );

    await tester.tap(_button(shell.t(L10nKey.settingsStorageEraseCancel)));
    await tester.pumpAndSettle();
    expect(shell.controller.dataWipePending, isFalse);
    await tester.pump(const Duration(seconds: 9));
  });
}
