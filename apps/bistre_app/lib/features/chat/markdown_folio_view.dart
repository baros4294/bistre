import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/context_menu.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/line_selection.dart';
import '../../design/math_font_gate.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'code_syntax_highlighter.dart';
import 'code_wrap_scope.dart';
import 'content_direction.dart';
import 'math_folio_view.dart';
import 'mermaid_canvas_view.dart';
import 'svg_preview_painter.dart';

export 'code_syntax_highlighter.dart' show highlightCodeSpans;

part 'markdown_cards.dart';

/// Pure `package:flutter/widgets.dart` editorial Markdown, GFM Table, TeX Math,
/// Mermaid Vector Diagram, and framed code renderer.
class MarkdownFolioView extends StatelessWidget {
  const MarkdownFolioView({
    super.key,
    required this.markdown,
    required this.onCopyCode,
    this.onSaveCode,
    this.editorialDialogueStyling = false,
    this.renderMath = true,
    this.foldCodeBlocks = false,
  });

  final String markdown;
  final ValueChanged<String> onCopyCode;

  /// Saves a code block to a file (`code`, `language`); hidden when null.
  final void Function(String code, String language)? onSaveCode;
  final bool editorialDialogueStyling;

  /// Settings > Appearance: off shows `$…$` and `$$…$$` exactly as written.
  final bool renderMath;

  /// Settings > Appearance: code blocks start folded.
  final bool foldCodeBlocks;

  @override
  Widget build(BuildContext context) {
    final parsed = _parseBlocksStreaming(markdown);
    // A message reads in its own direction, not the app's (see [contentDirection]).
    final direction = parsed.direction;
    Widget blocks(BuildContext context) => _MdDisplay(
      renderMath: renderMath,
      child: direction == null
          ? _buildBlocks(context, parsed.blocks)
          : Directionality(
              textDirection: direction,
              child: Builder(
                builder: (ctx) => _buildBlocks(ctx, parsed.blocks),
              ),
            ),
    );
    if (!parsed.hasMath || !renderMath) return blocks(context);
    // Inline math: load the math face on demand and repaint once it is registered.
    unawaited(MathFontGate.ensureLoaded());
    return ValueListenableBuilder<bool>(
      valueListenable: MathFontGate.ready,
      builder: (context, _, _) => blocks(context),
    );
  }

  Widget _buildBlocks(BuildContext context, List<_MdBlock> blocks) {
    final theme = BistreTheme.of(context);

    return LineSelection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0)
              SizedBox(
                height:
                    blocks[i] is _MdCodeBlock || blocks[i - 1] is _MdCodeBlock
                    ? BistreSpacing.s12
                    : BistreSpacing.s8,
              ),
            _buildBlock(context, theme, blocks[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildBlock(
    BuildContext context,
    BistreThemeData theme,
    _MdBlock block,
  ) {
    final typo = theme.typography;
    return switch (block) {
      _MdHeading() => Padding(
        padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s4),
        child: InkText(
          block.text,
          role: block.level <= 2
              ? InkTextRole.titleMedium
              : InkTextRole.labelStrong,
          color: theme.inkPrimary,
        ),
      ),
      _MdQuote() => DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgSurface.withValues(alpha: theme.isDark ? 0.45 : 0.55),
          borderRadius: const BorderRadiusDirectional.only(
            topEnd: Radius.circular(8),
            bottomEnd: Radius.circular(8),
          ),
          border: BorderDirectional(
            start: BorderSide(color: theme.accentBrass, width: 2.5),
          ),
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            BistreSpacing.s12,
            8,
            BistreSpacing.s12,
            8,
          ),
          child: _InlineRichText(
            text: block.text,
            baseStyle: BistreTypography.bodyCompact(
              theme.inkSecondary,
              config: typo,
            ).copyWith(fontStyle: FontStyle.italic),
          ),
        ),
      ),
      _MdListItem() => Padding(
        padding: const EdgeInsetsDirectional.only(start: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: InkText(
                block.marker,
                role: InkTextRole.labelStrong,
                color: theme.accentBrass,
              ),
            ),
            Expanded(
              child: _InlineRichText(
                text: block.text,
                baseStyle: BistreTypography.bodyProse(
                  theme.inkPrimary,
                  config: typo,
                ),
              ),
            ),
          ],
        ),
      ),
      _MdCodeBlock() =>
        block.language.toLowerCase() == 'mermaid'
            ? MermaidCanvasView(source: block.code, onCopySource: onCopyCode)
            : _FencedCodeCard(
                language: block.language,
                code: block.code,
                onCopy: () => onCopyCode(block.code),
                onSave: onSaveCode,
                startFolded: foldCodeBlocks,
              ),
      _MdMathBlock() =>
        renderMath
            ? MathFolioView(latex: block.latex, onCopyLatex: onCopyCode)
            : InkText(_typedMath(block.latex), color: theme.inkPrimary),
      _MdTable() => _GfmTableCard(
        headers: block.headers,
        alignments: block.alignments,
        rows: block.rows,
        rawMarkdown: block.rawMarkdown,
        onCopy: onCopyCode,
      ),
      _MdParagraph() => _InlineRichText(
        text: block.text,
        baseStyle: BistreTypography.bodyProse(theme.inkPrimary, config: typo),
        editorialDialogueStyling: editorialDialogueStyling,
      ),
    };
  }

  static bool _isTableSeparatorLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.contains('|') || !trimmed.contains('-')) return false;
    final cells = _splitTableRow(trimmed);
    if (cells.isEmpty) return false;
    return cells.every(_tableRulePattern.hasMatch);
  }

  static List<String> _splitTableRow(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s.split('|').map((c) => c.trim()).toList(growable: false);
  }

  static List<TextAlign> _parseTableAlignments(String sepLine) {
    return _splitTableRow(sepLine)
        .map((c) {
          final start = c.startsWith(':');
          final end = c.endsWith(':');
          if (start && end) return TextAlign.center;
          if (end) return TextAlign.end;
          return TextAlign.start;
        })
        .toList(growable: false);
  }

  /// Up to four replies streaming inside an unterminated code fence. While a reply only grows
  /// and no new fence marker or `\r` arrives, the fence's code is simply the rest of the message,
  /// so the block list is extended without re-splitting the whole message on every delta.
  static final List<_OpenFenceMemo> _openFenceMemos = <_OpenFenceMemo>[];

  /// Parsed blocks of recent messages, keyed by their exact text (LRU, bounded). Committed
  /// messages are parsed once, not on every rebuild, hover, or scroll back into view.
  static final Map<String, _ParsedDoc> _parsedBlocks = <String, _ParsedDoc>{};
  static const int _kParsedCacheEntries = 256;

  /// The cache is also bounded by the text it holds (a streaming reply used to leave
  /// one near-copy per frame, up to 256 of them).
  static const int parseCacheMaxChars = 4 * 1024 * 1024;
  static int _parsedChars = 0;

  /// Test hooks: parse [source] as the view does, and inspect the cache.
  @visibleForTesting
  static void debugParse(String source) => _parseBlocksStreaming(source);
  @visibleForTesting
  static int get debugParseCacheEntries => _parsedBlocks.length;
  @visibleForTesting
  static int get debugParseCacheChars => _parsedChars;
  @visibleForTesting
  static void debugClearParseCache() {
    _parsedBlocks.clear();
    _openFenceMemos.clear();
    _parsedChars = 0;
  }

  static void _evictParsed(String key) {
    if (_parsedBlocks.remove(key) != null) _parsedChars -= key.length;
  }

  static final RegExp _tableRulePattern = RegExp(r'^:?-{2,}:?$');
  static final RegExp _headingPattern = RegExp(r'^(#{1,3})\s+(.*)$');
  static final RegExp _bulletPattern = RegExp(r'^[-*]\s+(.*)$');
  static final RegExp _numberedPattern = RegExp(r'^(\d+\.)\s+(.*)$');
  static final RegExp _listStartPattern = RegExp(r'^([-*]|\d+\.)\s+');

  /// Constant-time prefix probe for monotonically growing streams (checks head, midpoint, and
  /// boundary tail instead of scanning 80+ KB every delta frame).
  static bool _matchesPrefixFast(String longer, String prefix) {
    final n = prefix.length;
    if (longer.length < n) return false;
    if (n <= 96) return longer.startsWith(prefix);
    const sample = 32;
    if (!longer.startsWith(prefix.substring(0, sample))) return false;
    final mid = n >> 1;
    if (!longer.startsWith(prefix.substring(mid, mid + sample), mid)) {
      return false;
    }
    return longer.startsWith(prefix.substring(n - sample), n - sample);
  }

  static _ParsedDoc _parseBlocksStreaming(String source) {
    for (var i = 0; i < _openFenceMemos.length; i++) {
      final memo = _openFenceMemos[i];
      if (identical(memo.source, source)) return memo.doc;
      if (source.length <= memo.source.length ||
          !_matchesPrefixFast(source, memo.source)) {
        continue;
      }
      // A closing fence may straddle the previous end, so rescan its last two characters.
      final rescanFrom = math.max(memo.codeStart, memo.source.length - 2);
      if (source.contains('```', rescanFrom) ||
          source.contains('\r', memo.source.length)) {
        _openFenceMemos.removeAt(i);
        break;
      }
      final open = memo.doc.blocks.last as _MdCodeBlock;
      final blocks = <_MdBlock>[
        ...memo.doc.blocks.sublist(0, memo.doc.blocks.length - 1),
        _MdCodeBlock(
          language: open.language,
          code: source.substring(memo.codeStart),
        ),
      ];
      final hasMath =
          memo.doc.hasMath || source.contains(r'$', memo.source.length);
      final doc = _ParsedDoc(blocks, memo.doc.direction, hasMath);
      _openFenceMemos[i] = _OpenFenceMemo(source, doc, memo.codeStart);
      return doc;
    }
    final cached = _parsedBlocks.remove(source);
    if (cached != null) {
      // Re-insert to mark it most recently used (the size is unchanged).
      _parsedBlocks[source] = cached;
      return cached;
    }
    final blocks = _parseBlocks(source);
    final doc = _ParsedDoc(
      blocks,
      contentDirection(source),
      source.contains(r'$'),
    );
    // A growing reply replaces its previous frame instead of adding a near-copy.
    if (_parsedBlocks.isNotEmpty) {
      final newest = _parsedBlocks.keys.last;
      if (newest.length < source.length && _matchesPrefixFast(source, newest)) {
        _evictParsed(newest);
      }
    }
    _parsedBlocks[source] = doc;
    _parsedChars += source.length;
    while (_parsedBlocks.length > 1 &&
        (_parsedBlocks.length > _kParsedCacheEntries ||
            _parsedChars > parseCacheMaxChars)) {
      _evictParsed(_parsedBlocks.keys.first);
    }
    final codeStart = _openFenceCodeStart(source, blocks);
    if (codeStart >= 0) {
      if (_openFenceMemos.length >= 4) _openFenceMemos.removeAt(0);
      _openFenceMemos.add(_OpenFenceMemo(source, doc, codeStart));
    }
    return doc;
  }

  /// Offset where the code of a trailing, still-open fence starts, or `-1`. The memo is only
  /// trusted when the fast path reproduces exactly what the full parser produced.
  static int _openFenceCodeStart(String source, List<_MdBlock> blocks) {
    final last = blocks.isEmpty ? null : blocks.last;
    if (last is! _MdCodeBlock) return -1;
    final marker = source.lastIndexOf('```');
    if (marker < 0) return -1;
    final lineStart = source.lastIndexOf('\n', marker) + 1;
    if (source.substring(lineStart, marker).trim().isNotEmpty) return -1;
    final lineEnd = source.indexOf('\n', marker);
    if (lineEnd < 0) return -1;
    final codeStart = lineEnd + 1;
    return source.substring(codeStart) == last.code ? codeStart : -1;
  }

  static List<_MdBlock> _parseBlocks(String source) {
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final blocks = <_MdBlock>[];
    var i = 0;

    while (i < lines.length) {
      final line = lines[i];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        i++;
        continue;
      }

      if (trimmed.startsWith(r'$$')) {
        if (trimmed.length > 4 && trimmed.endsWith(r'$$')) {
          blocks.add(
            _MdMathBlock(
              latex: trimmed.substring(2, trimmed.length - 2).trim(),
            ),
          );
          i++;
          continue;
        }
        final mathLines = <String>[];
        final firstRest = trimmed.substring(2).trim();
        if (firstRest.isNotEmpty) mathLines.add(firstRest);
        i++;
        while (i < lines.length && !lines[i].trim().endsWith(r'$$')) {
          mathLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) {
          final tail = lines[i].trim();
          final beforeClose = tail.substring(0, tail.length - 2).trim();
          if (beforeClose.isNotEmpty) mathLines.add(beforeClose);
          i++;
        }
        blocks.add(_MdMathBlock(latex: mathLines.join('\n').trim()));
        continue;
      }

      if (trimmed.startsWith('```')) {
        final lang = trimmed.substring(3).trim();
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++;
        blocks.add(_MdCodeBlock(language: lang, code: codeLines.join('\n')));
        continue;
      }

      // GFM pipe table: header line followed by separator line (`| --- | --- |`).
      if (trimmed.contains('|') &&
          i + 1 < lines.length &&
          _isTableSeparatorLine(lines[i + 1])) {
        final rawTableLines = <String>[lines[i], lines[i + 1]];
        final headers = _splitTableRow(lines[i]);
        final alignments = _parseTableAlignments(lines[i + 1]);
        final rows = <List<String>>[];
        i += 2;
        while (i < lines.length &&
            lines[i].trim().isNotEmpty &&
            lines[i].contains('|')) {
          rawTableLines.add(lines[i]);
          rows.add(_splitTableRow(lines[i]));
          i++;
        }
        blocks.add(
          _MdTable(
            headers: headers,
            alignments: alignments,
            rows: rows,
            rawMarkdown: rawTableLines.join('\n'),
          ),
        );
        continue;
      }

      final headingMatch = _headingPattern.firstMatch(trimmed);
      if (headingMatch != null) {
        blocks.add(
          _MdHeading(
            level: headingMatch.group(1)!.length,
            text: headingMatch.group(2)!.trim(),
          ),
        );
        i++;
        continue;
      }

      if (trimmed.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quoteLines.add(lines[i].trim().substring(1).trim());
          i++;
        }
        blocks.add(_MdQuote(text: quoteLines.join(' ')));
        continue;
      }

      final bulletMatch = _bulletPattern.firstMatch(trimmed);
      if (bulletMatch != null) {
        blocks.add(_MdListItem(marker: '•', text: bulletMatch.group(1)!));
        i++;
        continue;
      }

      final numMatch = _numberedPattern.firstMatch(trimmed);
      if (numMatch != null) {
        blocks.add(
          _MdListItem(marker: numMatch.group(1)!, text: numMatch.group(2)!),
        );
        i++;
        continue;
      }

      final paraLines = <String>[trimmed];
      i++;
      while (i < lines.length) {
        final next = lines[i].trim();
        if (next.isEmpty ||
            next.startsWith('```') ||
            next.startsWith(r'$$') ||
            next.startsWith('#') ||
            next.startsWith('>') ||
            (next.contains('|') &&
                i + 1 < lines.length &&
                _isTableSeparatorLine(lines[i + 1])) ||
            _listStartPattern.hasMatch(next)) {
          break;
        }
        paraLines.add(next);
        i++;
      }
      blocks.add(_MdParagraph(text: paraLines.join(' ')));
    }

    return blocks;
  }
}

final class _ParsedDoc {
  const _ParsedDoc(this.blocks, this.direction, this.hasMath);
  final List<_MdBlock> blocks;
  final TextDirection? direction;
  final bool hasMath;
}

/// One reply streaming inside an unterminated code fence (see `_parseBlocksStreaming`).
final class _OpenFenceMemo {
  const _OpenFenceMemo(this.source, this.doc, this.codeStart);
  final String source;
  final _ParsedDoc doc;
  final int codeStart;
}

sealed class _MdBlock {
  const _MdBlock();
}

final class _MdHeading extends _MdBlock {
  const _MdHeading({required this.level, required this.text});
  final int level;
  final String text;
}

final class _MdQuote extends _MdBlock {
  const _MdQuote({required this.text});
  final String text;
}

final class _MdListItem extends _MdBlock {
  const _MdListItem({required this.marker, required this.text});
  final String marker;
  final String text;
}

final class _MdCodeBlock extends _MdBlock {
  const _MdCodeBlock({required this.language, required this.code});
  final String language;
  final String code;
}

final class _MdMathBlock extends _MdBlock {
  const _MdMathBlock({required this.latex});
  final String latex;
}

final class _MdTable extends _MdBlock {
  const _MdTable({
    required this.headers,
    required this.alignments,
    required this.rows,
    required this.rawMarkdown,
  });
  final List<String> headers;
  final List<TextAlign> alignments;
  final List<List<String>> rows;
  final String rawMarkdown;
}

final class _MdParagraph extends _MdBlock {
  const _MdParagraph({required this.text});
  final String text;
}
