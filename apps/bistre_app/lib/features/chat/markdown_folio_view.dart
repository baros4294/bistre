import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/math_font_gate.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import 'code_wrap_scope.dart';
import 'content_direction.dart';
import 'math_folio_view.dart';
import 'mermaid_canvas_view.dart';

/// Pure `package:flutter/widgets.dart` editorial Markdown, GFM Table, TeX Math,
/// Mermaid Vector Diagram, and framed code renderer.
class MarkdownFolioView extends StatelessWidget {
  const MarkdownFolioView({
    super.key,
    required this.markdown,
    required this.onCopyCode,
    this.onSaveCode,
    this.editorialDialogueStyling = false,
  });

  final String markdown;
  final ValueChanged<String> onCopyCode;

  /// Saves a code block to a file (`code`, `language`); hidden when null.
  final void Function(String code, String language)? onSaveCode;
  final bool editorialDialogueStyling;

  @override
  Widget build(BuildContext context) {
    // A message reads in its own direction, not the app's (see [contentDirection]).
    final direction = contentDirection(markdown);
    Widget blocks(BuildContext context) => direction == null
        ? _buildBlocks(context)
        : Directionality(
            textDirection: direction,
            child: Builder(builder: _buildBlocks),
          );
    if (!markdown.contains(r'$')) return blocks(context);
    // Inline math: load the math face on demand and repaint once it is registered.
    unawaited(MathFontGate.ensureLoaded());
    return ValueListenableBuilder<bool>(
      valueListenable: MathFontGate.ready,
      builder: (context, _, _) => blocks(context),
    );
  }

  Widget _buildBlocks(BuildContext context) {
    final theme = BistreTheme.of(context);
    final blocks = _parseBlocksStreaming(markdown);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0)
            SizedBox(
              height: blocks[i] is _MdCodeBlock || blocks[i - 1] is _MdCodeBlock
                  ? BistreSpacing.s12
                  : BistreSpacing.s8,
            ),
          _buildBlock(context, theme, blocks[i]),
        ],
      ],
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
              ),
      _MdMathBlock() => MathFolioView(
        latex: block.latex,
        onCopyLatex: onCopyCode,
      ),
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
  static final Map<String, List<_MdBlock>> _parsedBlocks =
      <String, List<_MdBlock>>{};
  static const int _kParsedCacheEntries = 256;

  static final RegExp _tableRulePattern = RegExp(r'^:?-{2,}:?$');
  static final RegExp _headingPattern = RegExp(r'^(#{1,3})\s+(.*)$');
  static final RegExp _bulletPattern = RegExp(r'^[-*]\s+(.*)$');
  static final RegExp _numberedPattern = RegExp(r'^(\d+\.)\s+(.*)$');
  static final RegExp _listStartPattern = RegExp(r'^([-*]|\d+\.)\s+');

  static List<_MdBlock> _parseBlocksStreaming(String source) {
    for (var i = 0; i < _openFenceMemos.length; i++) {
      final memo = _openFenceMemos[i];
      if (identical(memo.source, source)) return memo.blocks;
      if (source.length <= memo.source.length ||
          !source.startsWith(memo.source)) {
        continue;
      }
      // A closing fence may straddle the previous end, so rescan its last two characters.
      final rescanFrom = math.max(memo.codeStart, memo.source.length - 2);
      if (source.contains('```', rescanFrom) ||
          source.contains('\r', memo.source.length)) {
        _openFenceMemos.removeAt(i);
        break;
      }
      final open = memo.blocks.last as _MdCodeBlock;
      final blocks = <_MdBlock>[
        ...memo.blocks.sublist(0, memo.blocks.length - 1),
        _MdCodeBlock(
          language: open.language,
          code: source.substring(memo.codeStart),
        ),
      ];
      _openFenceMemos[i] = _OpenFenceMemo(source, blocks, memo.codeStart);
      return blocks;
    }
    final cached = _parsedBlocks.remove(source);
    if (cached != null) {
      // Re-insert to mark it most recently used.
      _parsedBlocks[source] = cached;
      return cached;
    }
    final blocks = _parseBlocks(source);
    _parsedBlocks[source] = blocks;
    if (_parsedBlocks.length > _kParsedCacheEntries) {
      _parsedBlocks.remove(_parsedBlocks.keys.first);
    }
    final codeStart = _openFenceCodeStart(source, blocks);
    if (codeStart >= 0) {
      if (_openFenceMemos.length >= 4) _openFenceMemos.removeAt(0);
      _openFenceMemos.add(_OpenFenceMemo(source, blocks, codeStart));
    }
    return blocks;
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

/// One reply streaming inside an unterminated code fence (see `_parseBlocksStreaming`).
final class _OpenFenceMemo {
  const _OpenFenceMemo(this.source, this.blocks, this.codeStart);
  final String source;
  final List<_MdBlock> blocks;
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

class _GfmTableCard extends StatefulWidget {
  const _GfmTableCard({
    required this.headers,
    required this.alignments,
    required this.rows,
    required this.rawMarkdown,
    required this.onCopy,
  });

  final List<String> headers;
  final List<TextAlign> alignments;
  final List<List<String>> rows;
  final String rawMarkdown;
  final ValueChanged<String> onCopy;

  @override
  State<_GfmTableCard> createState() => _GfmTableCardState();
}

class _GfmTableCardState extends State<_GfmTableCard> {
  String _copiedMode = '';

  String _buildCsv() {
    String escape(String cell) {
      if (cell.contains(',') || cell.contains('"') || cell.contains('\n')) {
        return '"${cell.replaceAll('"', '""')}"';
      }
      return cell;
    }

    final buf = StringBuffer()..writeln(widget.headers.map(escape).join(','));
    for (final row in widget.rows) {
      buf.writeln(row.map(escape).join(','));
    }
    return buf.toString().trimRight();
  }

  void _copy(String mode, String text) {
    widget.onCopy(text);
    setState(() => _copiedMode = mode);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copiedMode = '');
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final colCount = widget.headers.length;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.isDark ? theme.bgCanvas : theme.bgElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.borderHairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: theme.bgSurface,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 5, 8, 5),
                child: Row(
                  children: [
                    BistreIcon(
                      BistreUiIcon.tableGrid,
                      size: 13,
                      color: theme.accentBrass,
                    ),
                    const Spacer(),
                    EngravedButton(
                      label: _copiedMode == 'csv'
                          ? l10n.t(L10nKey.chatActionCopied)
                          : l10n.t(L10nKey.chatTableCopyCsv),
                      compact: true,
                      onPressed: () => _copy('csv', _buildCsv()),
                    ),
                    const SizedBox(width: 6),
                    EngravedButton(
                      label: _copiedMode == 'md'
                          ? l10n.t(L10nKey.chatActionCopied)
                          : l10n.t(L10nKey.chatTableCopyMd),
                      compact: true,
                      onPressed: () => _copy('md', widget.rawMarkdown),
                    ),
                  ],
                ),
              ),
            ),
            const FolioDivider(),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                defaultColumnWidth: const IntrinsicColumnWidth(),
                border: TableBorder.symmetric(
                  inside: BorderSide(
                    color: theme.borderHairline.withValues(alpha: 0.65),
                  ),
                ),
                children: [
                  TableRow(
                    decoration: BoxDecoration(
                      color: theme.bgSurface.withValues(alpha: 0.60),
                    ),
                    children: [
                      for (var c = 0; c < colCount; c++)
                        Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          child: InkText(
                            widget.headers[c],
                            role: InkTextRole.labelStrong,
                            color: theme.inkPrimary,
                            textAlign: c < widget.alignments.length
                                ? widget.alignments[c]
                                : TextAlign.start,
                          ),
                        ),
                    ],
                  ),
                  for (var r = 0; r < widget.rows.length; r++)
                    TableRow(
                      decoration: r.isOdd
                          ? BoxDecoration(
                              color: theme.bgSurface.withValues(alpha: 0.25),
                            )
                          : null,
                      children: [
                        for (var c = 0; c < colCount; c++)
                          Padding(
                            padding: const EdgeInsetsDirectional.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            child: InkText(
                              c < widget.rows[r].length
                                  ? widget.rows[r][c]
                                  : '',
                              role: InkTextRole.bodyCompact,
                              color: theme.inkPrimary,
                              textAlign: c < widget.alignments.length
                                  ? widget.alignments[c]
                                  : TextAlign.start,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FencedCodeCard extends StatefulWidget {
  const _FencedCodeCard({
    required this.language,
    required this.code,
    required this.onCopy,
    this.onSave,
  });

  final String language;
  final String code;
  final VoidCallback onCopy;
  final void Function(String code, String language)? onSave;

  @override
  State<_FencedCodeCard> createState() => _FencedCodeCardState();
}

class _FencedCodeCardState extends State<_FencedCodeCard> {
  bool _copied = false;
  bool _folded = false;

  /// Completed chunk texts and the widgets built for them. While a fence streams, only the
  /// growing tail chunk is re-highlighted; identical widget instances let Flutter skip rebuild,
  /// layout, and (behind each `RepaintBoundary`) repaint for every finished chunk.
  final List<String> _chunkTexts = <String>[];
  final List<Widget> _chunkWidgets = <Widget>[];
  Object? _chunkStyleKey;

  List<Widget> _codeChunks(String code, BistreThemeData theme, bool wrap) {
    final styleKey = Object.hash(theme, wrap);
    if (styleKey != _chunkStyleKey) {
      _chunkStyleKey = styleKey;
      _chunkTexts.clear();
      _chunkWidgets.clear();
    }
    // Keep the leading chunks that still match the code (streaming only appends).
    var keep = 0;
    var offset = 0;
    while (keep < _chunkTexts.length) {
      final chunk = _chunkTexts[keep];
      final complete = chunk.endsWith('\n');
      if (!complete || !code.startsWith(chunk, offset)) break;
      offset += chunk.length;
      keep++;
    }
    _chunkTexts.removeRange(keep, _chunkTexts.length);
    _chunkWidgets.removeRange(keep, _chunkWidgets.length);
    var start = offset;
    var lines = 0;
    for (var i = offset; i < code.length; i++) {
      if (code.codeUnitAt(i) != 0x0A) continue;
      lines++;
      if (lines == kCodeChunkLines) {
        _addChunk(code.substring(start, i + 1), theme, wrap);
        start = i + 1;
        lines = 0;
      }
    }
    if (start < code.length) _addChunk(code.substring(start), theme, wrap);
    return _chunkWidgets;
  }

  void _addChunk(String text, BistreThemeData theme, bool wrap) {
    // A chunk ends with its newline; strip it from the painted text so chunk rows join exactly.
    final painted = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    _chunkTexts.add(text);
    _chunkWidgets.add(
      RepaintBoundary(
        child: Text.rich(
          _highlightCode(painted, theme),
          textDirection: TextDirection.ltr,
          softWrap: wrap,
        ),
      ),
    );
  }

  void _handleCopy() {
    widget.onCopy();
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final codeSurface = theme.isDark ? theme.bgCanvas : theme.bgElevated;
    final headerSurface = theme.bgSurface;
    // `kotlin (2 lines)` (Parchment v2.6.0 code card header).
    final langLabel = l10n.t(L10nKey.chatCodeHeader, <String, Object?>{
      'language': widget.language.isEmpty
          ? l10n.t(L10nKey.modeCode)
          : widget.language,
      'count': '\n'.allMatches(widget.code.trimRight()).length + 1,
    });
    // Stable per-fence key (language + opening text) so the toggle survives streaming growth
    // and list virtualization.
    final head = widget.code.length > 64
        ? widget.code.substring(0, 64)
        : widget.code;
    final fenceKey = Object.hash(widget.language, head);
    final wrap = CodeWrapScope.wrapFor(context, fenceKey);
    final overrides = CodeWrapScope.maybeOf(context)?.notifier;
    final codeText = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: _codeChunks(widget.code, theme, wrap),
    );

    // Source code is always left-to-right even inside RTL Arabic conversations.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: codeSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.borderHairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: headerSurface,
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 5, 8, 5),
                  child: Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.code,
                        size: 13,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: InkText(
                          langLabel,
                          role: InkTextRole.captionMeta,
                          color: theme.inkSecondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // Parchment v2.6.0: wrap, fold, download, and copy as equal icon buttons.
                      if (overrides != null)
                        BistreIconButton(
                          icon: BistreUiIcon.wrap,
                          size: 13,
                          dimension: 26,
                          active: wrap,
                          semanticsLabel: wrap
                              ? l10n.t(L10nKey.chatCodeNoWrap)
                              : l10n.t(L10nKey.chatCodeWrap),
                          onPressed: () => overrides.set(fenceKey, !wrap),
                        ),
                      BistreIconButton(
                        icon: _folded
                            ? BistreUiIcon.chevronDown
                            : BistreUiIcon.chevronUp,
                        size: 13,
                        dimension: 26,
                        semanticsLabel: _folded
                            ? l10n.t(L10nKey.chatCodeUnfold)
                            : l10n.t(L10nKey.chatCodeFold),
                        onPressed: () => setState(() => _folded = !_folded),
                      ),
                      if (widget.onSave != null)
                        BistreIconButton(
                          icon: BistreUiIcon.download,
                          size: 13,
                          dimension: 26,
                          semanticsLabel: l10n.t(L10nKey.chatCodeSave),
                          onPressed: () =>
                              widget.onSave!(widget.code, widget.language),
                        ),
                      BistreIconButton(
                        icon: _copied ? BistreUiIcon.check : BistreUiIcon.copy,
                        size: 13,
                        dimension: 26,
                        color: _copied ? theme.statusOk : theme.inkSecondary,
                        semanticsLabel: _copied
                            ? l10n.t(L10nKey.chatActionCopied)
                            : l10n.t(L10nKey.chatCodeCopy),
                        onPressed: _handleCopy,
                      ),
                    ],
                  ),
                ),
              ),
              DisclosureReveal(
                open: !_folded,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const FolioDivider(),
                    if (wrap)
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          14,
                          12,
                          18,
                          12,
                        ),
                        child: codeText,
                      )
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsetsDirectional.fromSTEB(
                          14,
                          12,
                          18,
                          12,
                        ),
                        child: codeText,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lines per independently built, laid-out, and painted code-fence chunk (Spec 08). While a fence
/// streams, only the growing tail chunk is re-shaped each frame, so this bounds per-frame text
/// layout: 8 lines cut it from ~4.0 to ~0.85 ms per slow frame in the profile trace (Spec 11).
const int kCodeChunkLines = 8;

/// Zero-dependency Sepia token syntax highlighter using strictly WCAG-verified theme tokens.
/// Preserves every source character verbatim so text selection and `toPlainText()` stay exact.
TextSpan _highlightCode(String source, BistreThemeData theme) {
  final base = BistreTypography.codeBlock(
    theme.inkPrimary,
    config: theme.typography,
  );
  final commentStyle = base.copyWith(
    color: theme.inkMuted,
    fontStyle: FontStyle.italic,
  );
  final stringStyle = base.copyWith(color: theme.statusOk);
  final keywordStyle = base.copyWith(
    color: theme.accentWax,
    fontWeight: FontWeight.w500,
  );
  final typeOrNumberStyle = base.copyWith(color: theme.accentBrass);

  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final match in _codeTokenPattern.allMatches(source)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: source.substring(cursor, match.start)));
    }
    final tok = match.group(0)!;
    if (tok.startsWith('//') || tok.startsWith('/*') || tok.startsWith('#')) {
      spans.add(TextSpan(text: tok, style: commentStyle));
    } else if (tok.startsWith('"') ||
        tok.startsWith("'") ||
        tok.startsWith('`')) {
      spans.add(TextSpan(text: tok, style: stringStyle));
    } else if (_codeKeywords.contains(tok)) {
      spans.add(TextSpan(text: tok, style: keywordStyle));
    } else if (_isTypeOrNumber(tok)) {
      spans.add(TextSpan(text: tok, style: typeOrNumberStyle));
    } else {
      spans.add(TextSpan(text: tok));
    }
    cursor = match.end;
  }

  if (cursor < source.length) {
    spans.add(TextSpan(text: source.substring(cursor)));
  }

  return TextSpan(style: base, children: spans);
}

final RegExp _codeTokenPattern = RegExp(
  r'//[^\n]*|/\*[\s\S]*?\*/|#[^\n]*|"(?:\\.|[^"\\])*"|'
  r"'(?:\\.|[^'\\])*'"
  r'|\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b|\b[A-Za-z_][A-Za-z0-9_]*\b',
);

const Set<String> _codeKeywords = <String>{
  'pub',
  'fn',
  'let',
  'mut',
  'const',
  'static',
  'struct',
  'enum',
  'impl',
  'trait',
  'match',
  'if',
  'else',
  'for',
  'while',
  'loop',
  'return',
  'async',
  'await',
  'use',
  'mod',
  'where',
  'class',
  'final',
  'void',
  'var',
  'import',
  'export',
  'from',
  'def',
  'function',
  'type',
  'interface',
  'true',
  'false',
  'null',
  'None',
  'self',
  'this',
  'super',
  'PRAGMA',
  'SELECT',
  'FROM',
  'WHERE',
  'INSERT',
  'UPDATE',
  'DELETE',
};

bool _isTypeOrNumber(String token) {
  if (token.isEmpty) return false;
  final first = token.codeUnitAt(0);
  if (first >= 48 && first <= 57) return true;
  if (first >= 65 && first <= 90) return true;
  return token == 'i32' ||
      token == 'i64' ||
      token == 'u32' ||
      token == 'u64' ||
      token == 'usize' ||
      token == 'bool' ||
      token == 'str';
}

class _InlineRichText extends StatelessWidget {
  const _InlineRichText({
    required this.text,
    required this.baseStyle,
    this.editorialDialogueStyling = false,
  });

  final String text;
  final TextStyle baseStyle;
  final bool editorialDialogueStyling;

  static final RegExp _tokenPattern = RegExp(
    r'(`[^`]+`|\$[^$\n]+\$|\*\*[^*]+\*\*|\*[^*]+\*|"[^"\n]+")',
  );

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final spans = <InlineSpan>[];
    var cursor = 0;

    for (final match in _tokenPattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final raw = match.group(0)!;
      if (raw.startsWith('`') && raw.endsWith('`') && raw.length >= 2) {
        final inlineCodeSize = (theme.typography.baseFontSizePx - 2.0).clamp(
          11.0,
          22.0,
        );
        spans.add(
          TextSpan(
            text: raw.substring(1, raw.length - 1),
            style:
                BistreTypography.codeBlock(
                  theme.accentBrass,
                  config: theme.typography,
                ).copyWith(
                  backgroundColor: theme.bgSurface,
                  fontSize: inlineCodeSize,
                ),
          ),
        );
      } else if (raw.startsWith(r'$') &&
          raw.endsWith(r'$') &&
          raw.length >= 3) {
        final renderedMath = MathFolioView.renderInlineUnicode(
          raw.substring(1, raw.length - 1),
        );
        spans.add(
          TextSpan(
            text: renderedMath,
            style: baseStyle.copyWith(
              fontFamily: MathFontGate.family,
              color: theme.inkPrimary,
            ),
          ),
        );
      } else if (raw.startsWith('**') &&
          raw.endsWith('**') &&
          raw.length >= 4) {
        spans.add(
          TextSpan(
            text: raw.substring(2, raw.length - 2),
            style: baseStyle.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else if (raw.startsWith('*') && raw.endsWith('*') && raw.length >= 2) {
        spans.add(
          TextSpan(
            text: raw.substring(1, raw.length - 1),
            style: baseStyle.copyWith(
              fontStyle: FontStyle.italic,
              color: editorialDialogueStyling
                  ? theme.inkSecondary
                  : baseStyle.color,
            ),
          ),
        );
      } else if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
        spans.add(
          TextSpan(
            text: raw,
            style: editorialDialogueStyling
                ? baseStyle.copyWith(
                    color: theme.accentBrass,
                    fontWeight: FontWeight.w500,
                  )
                : baseStyle,
          ),
        );
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}
