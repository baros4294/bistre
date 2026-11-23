import 'package:bistre_app/design/bistre_theme.dart';
import 'package:bistre_app/features/chat/code_wrap_scope.dart';
import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:bistre_app/l10n/bistre_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/gallery_harness.dart';

/// Streaming Markdown regressions (Spec 08 "Code Fences"): long fences render as independent
/// line chunks whose finished widgets are reused while the reply grows, and the open-fence
/// parse memo falls back to a full parse as soon as a fence marker arrives.
void main() {
  late BistreLocalizationController l10n;
  late CodeWrapOverrides overrides;

  setUp(() {
    l10n = loadDiskCatalogs();
    overrides = CodeWrapOverrides();
  });
  tearDown(() => overrides.dispose());

  Widget host(String markdown) => BistreLocalizations(
    controller: l10n,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: BistreTheme(
        data: BistreThemeData.dayParchment,
        child: CodeWrapScope(
          wrapByDefault: false,
          overrides: overrides,
          child: SingleChildScrollView(
            child: MarkdownFolioView(markdown: markdown, onCopyCode: (_) {}),
          ),
        ),
      ),
    ),
  );

  Finder codeParagraphs() => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    ),
    matching: find.byType(RichText),
  );

  String codeOf(String body) => '```rust\n$body';

  testWidgets('long fences render as exact line chunks', (tester) async {
    final lines = List<String>.generate(100, (i) => 'let v$i = $i;');
    final code = lines.join('\n');
    await tester.pumpWidget(host('${codeOf(code)}\n```\n'));
    final chunks = tester.widgetList<RichText>(codeParagraphs()).toList();
    expect(chunks, hasLength((100 / kCodeChunkLines).ceil()));
    expect(chunks.map((c) => c.text.toPlainText()).join('\n'), code);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finished chunks are reused while the fence streams', (
    tester,
  ) async {
    final buffer = StringBuffer();
    for (var i = 0; i < kCodeChunkLines + 4; i++) {
      buffer.write('let v$i = $i;\n');
    }
    await tester.pumpWidget(host(codeOf(buffer.toString())));
    final firstBefore = tester.widgetList<RichText>(codeParagraphs()).first;
    final paragraphBefore = tester.renderObject(codeParagraphs().first);

    buffer.write('let grown = 1;\n');
    await tester.pumpWidget(host(codeOf(buffer.toString())));
    final firstAfter = tester.widgetList<RichText>(codeParagraphs()).first;
    expect(identical(firstBefore, firstAfter), isTrue);
    expect(
      identical(paragraphBefore, tester.renderObject(codeParagraphs().first)),
      isTrue,
    );
    expect(
      tester.widgetList<RichText>(codeParagraphs()).last.text.toPlainText(),
      contains('let grown = 1;'),
    );
  });

  testWidgets('a closing fence ends the streaming fast path', (tester) async {
    var md = codeOf('fn a() {}\n');
    await tester.pumpWidget(host(md));
    md = '$md``';
    await tester.pumpWidget(host(md));
    // The closing marker straddles two deltas.
    md = '$md`\nAfter the fence.';
    await tester.pumpWidget(host(md));
    expect(find.text('After the fence.', findRichText: true), findsOneWidget);
    final code = tester
        .widgetList<RichText>(codeParagraphs())
        .map((c) => c.text.toPlainText())
        .join('\n');
    expect(code, 'fn a() {}');
  });
}
