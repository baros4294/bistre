import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/design/ink_primitives.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:bistre_app/l10n/l10n_keys.g.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _l10n = BistreLocalizationController(
  catalogs: const <String, BistreLocaleCatalog>{
    'en': BistreLocaleCatalog(
      locale: 'en',
      direction: TextDirection.ltr,
      messages: <String, String>{},
    ),
  },
);

/// The app's real text-editing shortcuts (Ctrl+V and friends) come from `WidgetsApp`.
Widget _app(Widget child) => WidgetsApp(
  color: const Color(0xFF000000),
  builder: (context, _) => BistreTheme(
    data: BistreThemeData.warmSepia,
    child: BistreLocalizations(
      controller: _l10n,
      child: Overlay(
        initialEntries: <OverlayEntry>[
          OverlayEntry(
            builder: (_) => Center(child: SizedBox(width: 320, child: child)),
          ),
        ],
      ),
    ),
  ),
);

void _mockClipboard(WidgetTester tester, String text) {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => switch (call.method) {
      'Clipboard.getData' => <String, Object?>{'text': text},
      'Clipboard.hasStrings' => <String, Object?>{'value': text.isNotEmpty},
      _ => null,
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

void main() {
  testWidgets('the right-click menu offers Paste when the clipboard has text', (
    tester,
  ) async {
    _mockClipboard(tester, 'from clipboard');
    final ctrl = TextEditingController(text: 'hello');
    final focus = FocusNode();
    await tester.pumpWidget(
      _app(
        QuillInput(
          controller: ctrl,
          focusNode: focus,
          placeholder: 'Message',
          onSubmitted: () {},
        ),
      ),
    );
    await tester.tap(find.byType(EditableText));
    await tester.pump();
    final mouse = await tester.startGesture(
      tester.getCenter(find.byType(EditableText)),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(find.text(_l10n.t(L10nKey.shellSelectionPaste)), findsOneWidget);
    ctrl.dispose();
    focus.dispose();
  });

  testWidgets('Ctrl+V pastes into a field focused by a click', (tester) async {
    _mockClipboard(tester, 'pasted');
    final ctrl = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(
      _app(
        QuillInput(
          controller: ctrl,
          focusNode: focus,
          placeholder: 'Message',
          onSubmitted: () {},
        ),
      ),
    );
    await tester.tap(find.byType(QuillInput));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(ctrl.text, 'pasted');
    ctrl.dispose();
    focus.dispose();
  });

  testWidgets('Enter submits a one-line field', (tester) async {
    final ctrl = TextEditingController();
    final focus = FocusNode();
    var submitted = 0;
    await tester.pumpWidget(
      _app(
        QuillInput(
          controller: ctrl,
          focusNode: focus,
          placeholder: 'Title',
          maxLines: 1,
          submitOnEnter: false,
          onSubmitted: () => submitted++,
        ),
      ),
    );
    await tester.tap(find.byType(QuillInput));
    await tester.pump();
    await tester.enterText(find.byType(EditableText), 'Trip notes');
    // Desktop embedders turn Enter into the field's text-input action.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 1);
    expect(ctrl.text, 'Trip notes', reason: 'no newline in a one-line field');
    ctrl.dispose();
    focus.dispose();
  });

  testWidgets('a text field is named for screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    final ctrl = TextEditingController();
    final focus = FocusNode();
    await tester.pumpWidget(
      _app(
        QuillInput(
          controller: ctrl,
          focusNode: focus,
          placeholder: 'Search chats',
          onSubmitted: () {},
        ),
      ),
    );
    // The field itself carries the name (not just the placeholder text drawn over it).
    final field = tester.getSemantics(find.byType(EditableText));
    expect(field.label, 'Search chats');
    expect(field.getSemanticsData().flagsCollection.isTextField, isTrue);
    semantics.dispose();
    ctrl.dispose();
    focus.dispose();
  });
}
