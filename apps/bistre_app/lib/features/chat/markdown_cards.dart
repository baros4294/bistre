part of 'markdown_folio_view.dart';

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

    // The card is as wide as its table (up to the column), so a narrow table has no
    // empty band beside it; a wide one fills the column and scrolls.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: IntrinsicWidth(child: _card(theme, l10n, colCount)),
    );
  }

  Widget _card(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    int colCount,
  ) {
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
                    // Icon actions like the code card's: the names live in the hover hints
                    // and screen-reader labels, so the header never overflows (phone, 200%).
                    BistreIconButton(
                      icon: _copiedMode == 'csv'
                          ? BistreUiIcon.check
                          : BistreUiIcon.exportIcon,
                      size: 13,
                      dimension: 28,
                      semanticsLabel: _copiedMode == 'csv'
                          ? l10n.t(L10nKey.chatActionCopied)
                          : l10n.t(L10nKey.chatTableCopyCsv),
                      onPressed: () => _copy('csv', _buildCsv()),
                    ),
                    BistreIconButton(
                      icon: _copiedMode == 'md'
                          ? BistreUiIcon.check
                          : BistreUiIcon.copy,
                      size: 13,
                      dimension: 28,
                      semanticsLabel: _copiedMode == 'md'
                          ? l10n.t(L10nKey.chatActionCopied)
                          : l10n.t(L10nKey.chatTableCopyMd),
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
    this.startFolded = false,
  });

  final String language;
  final String code;
  final VoidCallback onCopy;
  final void Function(String code, String language)? onSave;
  final bool startFolded;

  @override
  State<_FencedCodeCard> createState() => _FencedCodeCardState();
}

class _FencedCodeCardState extends State<_FencedCodeCard> {
  bool _copied = false;
  late bool _folded = widget.startFolded;
  bool _previewSvg = false;
  Timer? _copiedTimer;

  /// Completed chunk texts and the widgets built for them. While a fence streams, only the
  /// growing tail chunk is re-highlighted; identical widget instances let Flutter skip rebuild,
  /// layout, and (behind each `RepaintBoundary`) repaint for every finished chunk.
  final List<String> _chunkTexts = <String>[];
  final List<Widget> _chunkWidgets = <Widget>[];
  Object? _chunkStyleKey;
  int _completeChunks = 0;
  int _completeOffset = 0;
  String _completeHead = '';
  String _completeTail = '';
  int _lineCount = 1;

  @override
  void didUpdateWidget(covariant _FencedCodeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The fold setting changed while this block is on screen: apply it now.
    if (oldWidget.startFolded != widget.startFolded) {
      _folded = widget.startFolded;
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  bool _canResumeCompletePrefix(String code) {
    if (_completeChunks == 0 || code.length < _completeOffset) return false;
    if (_completeHead.isNotEmpty && !code.startsWith(_completeHead)) {
      return false;
    }
    if (_completeTail.isNotEmpty &&
        !code.startsWith(
          _completeTail,
          _completeOffset - _completeTail.length,
        )) {
      return false;
    }
    return true;
  }

  List<Widget> _codeChunks(String code, BistreThemeData theme, bool wrap) {
    final styleKey = Object.hash(theme, wrap);
    if (styleKey != _chunkStyleKey) {
      _chunkStyleKey = styleKey;
      _chunkTexts.clear();
      _chunkWidgets.clear();
      _completeChunks = 0;
      _completeOffset = 0;
      _completeHead = '';
      _completeTail = '';
    }
    int keep;
    int offset;
    if (_canResumeCompletePrefix(code)) {
      // O(1) streaming fast path: completed leading chunks are immutable while the fence grows.
      keep = _completeChunks;
      offset = _completeOffset;
    } else {
      keep = 0;
      offset = 0;
      while (keep < _chunkTexts.length) {
        final chunk = _chunkTexts[keep];
        final complete = chunk.endsWith('\n');
        if (!complete || !code.startsWith(chunk, offset)) break;
        offset += chunk.length;
        keep++;
      }
    }
    _chunkTexts.removeRange(keep, _chunkTexts.length);
    _chunkWidgets.removeRange(keep, _chunkWidgets.length);
    var start = offset;
    var lines = 0;
    var totalLines = keep * kCodeChunkLines;
    for (var i = offset; i < code.length; i++) {
      if (code.codeUnitAt(i) != 0x0A) continue;
      lines++;
      if (lines == kCodeChunkLines) {
        _addChunk(code.substring(start, i + 1), theme, wrap);
        start = i + 1;
        totalLines += kCodeChunkLines;
        lines = 0;
      }
    }
    _completeChunks = _chunkTexts.length;
    _completeOffset = start;
    if (_completeOffset > 0) {
      final headLen = math.min(32, _completeOffset);
      _completeHead = code.substring(0, headLen);
      final tailLen = math.min(32, _completeOffset);
      _completeTail = code.substring(
        _completeOffset - tailLen,
        _completeOffset,
      );
    } else {
      _completeHead = '';
      _completeTail = '';
    }
    if (start < code.length) {
      final tail = code.substring(start);
      _addChunk(tail, theme, wrap);
      // Count visible non-trailing-newline lines in O(tail.length).
      var trimmedEnd = tail.length;
      while (trimmedEnd > 0 && tail.codeUnitAt(trimmedEnd - 1) <= 0x20) {
        trimmedEnd--;
      }
      if (trimmedEnd > 0) {
        var tailNewlines = 0;
        for (var i = 0; i < trimmedEnd; i++) {
          if (tail.codeUnitAt(i) == 0x0A) tailNewlines++;
        }
        totalLines += tailNewlines + 1;
      }
    }
    _lineCount = totalLines > 0 ? totalLines : 1;
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
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final codeSurface = BistreSyntaxPalette.forId(
      theme.syntaxThemeId,
      isDark: theme.isDark,
    ).background;
    final headerSurface = theme.bgSurface;
    final head = widget.code.length > 64
        ? widget.code.substring(0, 64)
        : widget.code;
    final fenceKey = Object.hash(widget.language, head);
    final wrap = CodeWrapScope.wrapFor(context, fenceKey);
    final overrides = CodeWrapScope.maybeOf(context)?.notifier;
    final chunks = _codeChunks(widget.code, theme, wrap);
    final langLabel = l10n.t(L10nKey.chatCodeHeader, <String, Object?>{
      'language': widget.language.isEmpty
          ? l10n.t(L10nKey.modeCode)
          : widget.language,
      'count': _lineCount,
    });
    final isSvg =
        widget.language.trim().toLowerCase() == 'svg' ||
        head.trimLeft().toLowerCase().startsWith('<svg');
    // Chunk rows paint without their newline; copying puts it back.
    final codeText = LineSelection(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: chunks,
      ),
    );

    // Source code is always left-to-right even inside RTL Arabic conversations.
    // Right-click menu exposes the same actions as the code card header.
    return ContextMenuRegion(
      entries: <ContextMenuEntry>[
        ContextMenuEntry(
          label: l10n.t(L10nKey.chatCodeCopy),
          icon: BistreUiIcon.copy,
          onSelected: _handleCopy,
        ),
        if (overrides != null)
          ContextMenuEntry(
            label: wrap
                ? l10n.t(L10nKey.chatCodeNoWrap)
                : l10n.t(L10nKey.chatCodeWrap),
            icon: BistreUiIcon.wrap,
            onSelected: () => overrides.set(fenceKey, !wrap),
          ),
        ContextMenuEntry(
          label: _folded
              ? l10n.t(L10nKey.chatCodeUnfold)
              : l10n.t(L10nKey.chatCodeFold),
          icon: _folded ? BistreUiIcon.chevronDown : BistreUiIcon.chevronUp,
          onSelected: () => setState(() => _folded = !_folded),
        ),
        if (widget.onSave != null)
          ContextMenuEntry(
            label: l10n.t(L10nKey.chatCodeSave),
            icon: BistreUiIcon.download,
            onSelected: () => widget.onSave!(widget.code, widget.language),
          ),
      ],
      child: Directionality(
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
                SelectionContainer.disabled(
                  child: ColoredBox(
                    color: headerSurface,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        5,
                        8,
                        5,
                      ),
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
                          // Equal-weight icon actions; RepaintBoundary isolates buttons from
                          // streaming line-count updates on every delta frame (Spec 11).
                          RepaintBoundary(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isSvg) ...[
                                  InkChip(
                                    label: _previewSvg
                                        ? l10n.t(L10nKey.chatSvgSource)
                                        : l10n.t(L10nKey.chatSvgPreview),
                                    selected: _previewSvg,
                                    onSelected: () => setState(
                                      () => _previewSvg = !_previewSvg,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                if (overrides != null)
                                  BistreIconButton(
                                    icon: BistreUiIcon.wrap,
                                    size: 13,
                                    dimension: 26,
                                    active: wrap,
                                    semanticsLabel: wrap
                                        ? l10n.t(L10nKey.chatCodeNoWrap)
                                        : l10n.t(L10nKey.chatCodeWrap),
                                    onPressed: () =>
                                        overrides.set(fenceKey, !wrap),
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
                                  onPressed: () =>
                                      setState(() => _folded = !_folded),
                                ),
                                if (widget.onSave != null)
                                  BistreIconButton(
                                    icon: BistreUiIcon.download,
                                    size: 13,
                                    dimension: 26,
                                    semanticsLabel: l10n.t(
                                      L10nKey.chatCodeSave,
                                    ),
                                    onPressed: () => widget.onSave!(
                                      widget.code,
                                      widget.language,
                                    ),
                                  ),
                                BistreIconButton(
                                  icon: _copied
                                      ? BistreUiIcon.check
                                      : BistreUiIcon.copy,
                                  size: 13,
                                  dimension: 26,
                                  color: _copied
                                      ? theme.statusOk
                                      : theme.inkSecondary,
                                  semanticsLabel: _copied
                                      ? l10n.t(L10nKey.chatActionCopied)
                                      : l10n.t(L10nKey.chatCodeCopy),
                                  onPressed: _handleCopy,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                DisclosureReveal(
                  open: !_folded,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const FolioDivider(),
                      if (isSvg && _previewSvg)
                        Padding(
                          padding: const EdgeInsetsDirectional.all(14),
                          child: SizedBox(
                            height: 220,
                            child: CustomPaint(
                              painter: SafeSvgPreviewPainter(
                                svgSource: widget.code,
                                fallbackStroke: theme.inkPrimary,
                                fallbackFill: theme.accentBrass,
                              ),
                              size: const Size(double.infinity, 220),
                            ),
                          ),
                        )
                      else if (wrap)
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
      ),
    );
  }
}

/// Lines per independently built, laid-out, and painted code-fence chunk (Spec 08). While a fence
/// streams, only the growing tail chunk is re-shaped each frame, so this bounds per-frame text
/// layout: 8 lines cut it from ~4.0 to ~0.85 ms per slow frame in the profile trace (Spec 11).
const int kCodeChunkLines = 8;

TextSpan _highlightCode(String source, BistreThemeData theme) =>
    highlightCodeSpans(source, theme);

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
  static final RegExp _kLeadingCurrency = RegExp(r'^\d[\d.,]*\s');
  static final RegExp _kMathOperator = RegExp(r'[\\^_=+\-*/<>()]');

  /// Guards inline `$...$` against plain currency prices like `$10 to $20` while keeping
  /// genuine TeX math (`$x^2 + 1$`, `$\alpha$`, `$2^n$`).
  static bool _isInlineMathCandidate(String text, Match match, String raw) {
    if (!raw.startsWith(r'$') || !raw.endsWith(r'$') || raw.length < 3) {
      return false;
    }
    final inner = raw.substring(1, raw.length - 1);
    if (inner.trim().isEmpty) return false;
    if (inner.startsWith(' ') ||
        inner.endsWith(' ') ||
        inner.startsWith('\t') ||
        inner.endsWith('\t')) {
      return false;
    }
    if (match.end < text.length) {
      final next = text.codeUnitAt(match.end);
      if (next >= 0x30 && next <= 0x39) return false;
    }
    if (_kLeadingCurrency.hasMatch(inner) && !_kMathOperator.hasMatch(inner)) {
      return false;
    }
    return true;
  }

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
      } else if (_isInlineMathCandidate(text, match, raw) &&
          _MdDisplay.rendersMath(context)) {
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
      } else {
        // Math with math rendering off: shown exactly as written.
        spans.add(TextSpan(text: raw));
      }
      cursor = match.end;
    }

    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: baseStyle, children: spans));
  }
}

/// Display math exactly as the model wrote it (math rendering off).
String _typedMath(String latex) => '\$\$$latex\$\$';

/// Display settings shared by every block of one [MarkdownFolioView].
class _MdDisplay extends InheritedWidget {
  const _MdDisplay({required this.renderMath, required super.child});

  final bool renderMath;

  static bool rendersMath(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MdDisplay>()?.renderMath ??
      true;

  @override
  bool updateShouldNotify(_MdDisplay oldWidget) =>
      renderMath != oldWidget.renderMath;
}
