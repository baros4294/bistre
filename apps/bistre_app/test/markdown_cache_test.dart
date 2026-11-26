import 'package:bistre_app/features/chat/markdown_folio_view.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a streaming reply leaves one cached copy, not one per frame (U13)', () {
    MarkdownFolioView.debugClearParseCache();
    final paragraph = 'A sentence that keeps the reply going. ' * 20;
    var text = '';
    for (var i = 0; i < 300; i++) {
      text = '$text$paragraph\n\n';
      MarkdownFolioView.debugParse(text);
    }
    expect(MarkdownFolioView.debugParseCacheEntries, lessThanOrEqualTo(2));
    expect(
      MarkdownFolioView.debugParseCacheChars,
      lessThanOrEqualTo(MarkdownFolioView.parseCacheMaxChars),
    );
  });

  test(
    'the parse cache stays within its size even for many large messages (U13)',
    () {
      MarkdownFolioView.debugClearParseCache();
      for (var i = 0; i < 400; i++) {
        MarkdownFolioView.debugParse('message $i\n\n${'x' * 40000}');
      }
      expect(
        MarkdownFolioView.debugParseCacheChars,
        lessThanOrEqualTo(MarkdownFolioView.parseCacheMaxChars),
      );
    },
  );
}
