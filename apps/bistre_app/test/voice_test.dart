import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Read aloud uses the speech model chosen in Settings > Default models, never a guess from
/// the chat model's name; without one the system voice reads. Live voice speaks the user's
/// language and its notice can always be dismissed.
void main() {
  testWidgets('a chat model is never taken for a speech model', (tester) async {
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    await ctrl.setActiveProviderAndModel(
      ctrl.providers.first.id,
      'gpt-4o-mini-tts',
    );
    expect(ctrl.activeModelId, 'gpt-4o-mini-tts');
    expect(ctrl.readAloudModel, isNull);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('Read aloud names its speech model, or the system voice', (
    tester,
  ) async {
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    final provider = ctrl.providers.first;
    ctrl.openSettings(SettingsTab.defaultModels);
    await tester.pumpAndSettle();

    final systemVoice = find.widgetWithText(
      InkChip,
      shell.t(L10nKey.settingsDefaultModelsSystemVoice),
    );
    await tester.ensureVisible(systemVoice);
    await tester.pumpAndSettle();
    final chip = tester.widget<InkChip>(systemVoice);
    expect(chip.selected, isTrue);

    await ctrl.saveDefaultModels(
      ctrl.defaultModels.copyWith(
        speechProviderId: provider.id,
        speechModelId: 'speech-model',
      ),
    );
    expect(ctrl.readAloudModel?.provider.id, provider.id);
    expect(ctrl.readAloudModel?.modelId, 'speech-model');

    await tester.pumpAndSettle();
    await tester.tap(systemVoice);
    await tester.pumpAndSettle();
    expect(ctrl.readAloudModel, isNull);
    expect(ctrl.defaultModels.speechModelId, isEmpty);
    await tester.pump(const Duration(seconds: 9));
  });

  testWidgets('live voice ends with a reason in words when the mic fails', (
    tester,
  ) async {
    _mockHost(tester, micStarts: false);
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    await ctrl.toggleLiveVoiceSession();
    await tester.pump();
    expect(ctrl.liveVoiceActive, isFalse);
    expect(ctrl.liveVoiceError, 'diag.voice.mic_unavailable');
    expect(shell.gateway.callsTo('stopLiveVoiceSession'), isNotEmpty);

    await ctrl.stopLiveVoice();
    expect(ctrl.liveVoiceError, isNull, reason: 'End dismisses the notice');
  });

  testWidgets('a live voice failure shows a key, and words carry no prefix', (
    tester,
  ) async {
    _mockHost(tester, micStarts: true);
    final shell = await ShellHarness.pump(tester);
    final ctrl = shell.controller;
    await ctrl.toggleLiveVoiceSession();
    await tester.pump();
    final sid = ctrl.liveVoiceSessionId!;

    shell.gateway.emit(
      LiveVoiceTranscriptEvent(
        sessionId: sid,
        role: 'user',
        text: 'Hello there',
        isFinal: true,
      ),
    );
    await tester.pump();
    expect(ctrl.liveVoiceTranscript, 'Hello there');
    expect(ctrl.liveVoiceTranscriptIsUser, isTrue);

    shell.gateway.emit(
      LiveVoiceStateEvent(
        sessionId: sid,
        state: 'error',
        detail: 'diag.provider.request_failed (live_ws_connect)',
      ),
    );
    await tester.pump();
    expect(ctrl.liveVoiceError, 'diag.provider.request_failed');
    await tester.pumpAndSettle();
    expect(
      find.textContaining(shell.l10n.tRawKey('diag.provider.request_failed')),
      findsOneWidget,
    );
  });
}

/// The desktop host channel, answering whether the microphone starts.
void _mockHost(WidgetTester tester, {required bool micStarts}) {
  const host = MethodChannel('bistre/desktop_host');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    host,
    (call) async => call.method == 'startMicCapture' ? micStarts : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      host,
      null,
    ),
  );
}
