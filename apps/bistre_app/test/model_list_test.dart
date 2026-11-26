import 'package:bistre_app/bridge/bistre_engine.dart';
import 'package:bistre_app/features/settings/model_picker_field.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'every model a provider lists can be picked, not only the first 60 (P24)',
    () {
      final models = <EngineProviderModel>[
        for (var i = 0; i < 150; i++)
          EngineProviderModel(id: 'model-$i', displayName: 'Model $i'),
      ];
      final all = modelPickerMatches(models, const <String>{}, '');
      expect(all.length, 150);
      expect(all.last.id, 'model-149');
      final filtered = modelPickerMatches(models, const <String>{
        'model-14',
      }, 'model-14');
      expect(filtered.map((m) => m.id), isNot(contains('model-14')));
      expect(filtered.length, 10, reason: 'model-140 .. model-149');
    },
  );
}
