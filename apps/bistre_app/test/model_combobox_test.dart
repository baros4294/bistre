import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/settings/model_picker_field.dart';
import 'package:bistre_app/features/shell/folio_controller.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

Future<(TextEditingController, List<String>)> _pump(WidgetTester tester) async {
  final l10n = loadDiskCatalogs();
  final controller = FolioController(
    gateway: GalleryGateway(connected: true),
    defaultThreadTitle: 'New chat',
  );
  addTearDown(controller.dispose);
  await controller.bootstrap('/tmp/bistre_test');
  final text = TextEditingController();
  final focus = FocusNode();
  addTearDown(text.dispose);
  addTearDown(focus.dispose);
  final picked = <String>[];
  await tester.pumpWidget(
    WidgetsApp(
      color: const Color(0xFF000000),
      builder: (context, _) => BistreLocalizations(
        controller: l10n,
        child: BistreTheme(
          data: BistreThemeData.resolve(isDark: false),
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: 360,
                    child: ModelPickerField(
                      controller: controller,
                      providerId: 'openai',
                      textController: text,
                      focusNode: focus,
                      placeholder: 'Model',
                      onSelectedModel: picked.add,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (text, picked);
}

void main() {
  testWidgets(
    'one field: focusing lists models, typing filters, arrows + Enter pick (A-W 6)',
    (tester) async {
      final (text, picked) = await _pump(tester);
      expect(
        find.byType(EditableText),
        findsOneWidget,
        reason: 'no second filter box',
      );
      await tester.tap(find.byType(EditableText));
      await tester.pumpAndSettle();
      expect(
        find.text('gpt-4.1-mini'),
        findsOneWidget,
        reason: 'models load on open',
      );

      await tester.enterText(find.byType(EditableText), 'mini');
      await tester.pumpAndSettle();
      expect(find.text('gpt-4.1'), findsNothing);
      expect(find.text('o4-mini'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['o4-mini'], reason: 'the second match was highlighted');
      expect(text.text, 'o4-mini');
      expect(
        find.text('gpt-4.1-mini'),
        findsNothing,
        reason: 'the list closes',
      );
    },
  );

  testWidgets('Enter keeps a typed custom model id (A-W 6)', (tester) async {
    final (text, picked) = await _pump(tester);
    await tester.tap(find.byType(EditableText));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'my-local-model');
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(picked, ['my-local-model']);
    expect(text.text, 'my-local-model');
  });

  testWidgets('Esc closes the list without picking (A-W 6)', (tester) async {
    final (_, picked) = await _pump(tester);
    await tester.tap(find.byType(EditableText));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('gpt-4.1-mini'), findsNothing);
    expect(picked, isEmpty);
  });
}
