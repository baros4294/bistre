import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/shell/model_picker_popover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Gemini providers show the storage badge (core id google_gemini)', () {
    const gemini = EngineProvider(
      id: 'g',
      name: 'Gemini',
      dialect: 'google_gemini',
      baseUrl: 'https://example.invalid',
      defaultModel: 'm',
      keyHint: '',
      hasApiKey: true,
      isEnabled: true,
      isBuiltin: false,
      useServerStateCache: false,
      createdAtMs: 0,
      updatedAtMs: 0,
    );
    expect(providerMayStoreReplies(gemini), isTrue);
  });
}
