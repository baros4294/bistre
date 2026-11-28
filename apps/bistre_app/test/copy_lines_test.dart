import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/shell_harness.dart';

/// Copying selected reply text keeps the line breaks between paragraphs, list items and
/// code rows; long code paints in separate rows that must not run together.
void main() {
  testWidgets('copied text keeps its line breaks', (tester) async {
    final code = [for (var i = 1; i <= 10; i++) 'line $i'].join('\n');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(800, 900)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: BistreLocalizations(
            controller: loadShellCatalogs(),
            child: BistreTheme(
              data: BistreThemeData.warmSepia,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => SelectableRegion(
                      selectionControls: emptyTextSelectionControls,
                      child: MarkdownFolioView(
                        markdown:
                            'First paragraph\n\nSecond paragraph\n\n```\n$code\n```',
                        onCopyCode: (_) {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final inside = tester.element(find.byType(MarkdownFolioView));
    Actions.invoke(
      inside,
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();
    Actions.invoke(inside, CopySelectionTextIntent.copy);
    await tester.pump();
    expect(copied, contains('First paragraph\nSecond paragraph'));
    expect(
      copied,
      contains('line 8\nline 9'),
      reason: 'rows 8 and 9 paint apart',
    );
    expect(
      copied,
      isNot(contains('lines)')),
      reason: 'code card header line must not be copied with selected text',
    );
  });
}
