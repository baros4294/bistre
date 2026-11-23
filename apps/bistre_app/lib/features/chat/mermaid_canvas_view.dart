import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Pure-Dart Mermaid vector diagram parser & `CustomPainter` renderer (zero WebView/JS).
/// Supports `flowchart`/`graph` (TD/LR), `sequenceDiagram`, `stateDiagram`, and `erDiagram`
/// rendered directly in Bistre's Sepia Day / Night theme palette.
class MermaidCanvasView extends StatefulWidget {
  const MermaidCanvasView({
    super.key,
    required this.source,
    required this.onCopySource,
  });

  final String source;
  final ValueChanged<String> onCopySource;

  @override
  State<MermaidCanvasView> createState() => _MermaidCanvasViewState();
}

class _MermaidCanvasViewState extends State<MermaidCanvasView> {
  bool _copied = false;
  bool _showSource = false;

  void _copy() {
    widget.onCopySource(widget.source);
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  static String _formatDiagramHeader(
    BistreLocalizationController l10n,
    _ParsedDiagram diagram,
  ) =>
      '${l10n.t(L10nKey.chatMermaidDiagramTitle)} · ${l10n.t(diagram.kindLabelKey)}';

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final diagram = _parseMermaid(widget.source);
    final canvasSize = diagram.computeCanvasSize();
    final headerText = _formatDiagramHeader(l10n, diagram);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ClipRRect(
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
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 6),
                  child: Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.diagram,
                        size: 13,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: InkText(
                          headerText,
                          role: InkTextRole.captionMeta,
                          color: theme.inkSecondary,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.code,
                        size: 13,
                        dimension: 26,
                        active: _showSource,
                        semanticsLabel: l10n.t(L10nKey.modeCode),
                        onPressed: () =>
                            setState(() => _showSource = !_showSource),
                      ),
                      const SizedBox(width: 2),
                      BistreIconButton(
                        icon: _copied ? BistreUiIcon.check : BistreUiIcon.copy,
                        size: 13,
                        dimension: 26,
                        color: _copied ? theme.statusOk : theme.inkMuted,
                        semanticsLabel: l10n.t(L10nKey.chatMermaidCopySource),
                        onPressed: _copy,
                      ),
                    ],
                  ),
                ),
              ),
              const FolioDivider(),
              if (_showSource || diagram.nodes.isEmpty)
                Padding(
                  padding: const EdgeInsetsDirectional.all(12),
                  child: InkText(
                    widget.source.trim(),
                    role: InkTextRole.codeBlock,
                    color: theme.inkSecondary,
                  ),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsetsDirectional.all(14),
                  child: SizedBox(
                    width: canvasSize.width,
                    height: canvasSize.height,
                    child: CustomPaint(
                      painter: _MermaidPainter(diagram: diagram, theme: theme),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiagramNode {
  const _DiagramNode({required this.id, required this.label});
  final String id;
  final String label;
}

class _DiagramEdge {
  const _DiagramEdge({
    required this.from,
    required this.to,
    this.label = '',
    this.dashed = false,
  });
  final String from;
  final String to;
  final String label;
  final bool dashed;
}

class _ParsedDiagram {
  const _ParsedDiagram({
    required this.kind,
    required this.horizontal,
    required this.nodes,
    required this.edges,
  });

  final String kind;
  final bool horizontal;
  final List<_DiagramNode> nodes;
  final List<_DiagramEdge> edges;

  L10nKey get kindLabelKey => switch (kind) {
    'sequence' => L10nKey.chatMermaidKindSequence,
    'state' => L10nKey.chatMermaidKindState,
    'er' => L10nKey.chatMermaidKindEr,
    _ =>
      horizontal
          ? L10nKey.chatMermaidKindFlowchartLr
          : L10nKey.chatMermaidKindFlowchartTd,
  };

  Size computeCanvasSize() {
    if (nodes.isEmpty) return const Size(320, 120);
    if (kind == 'sequence') {
      final w = math.max(360.0, nodes.length * 148.0 + 40.0);
      final h = math.max(180.0, edges.length * 54.0 + 96.0);
      return Size(w, h);
    }
    if (horizontal) {
      final cols = math.max(1, nodes.length);
      return Size(math.max(360.0, cols * 164.0 + 36.0), 170.0);
    }
    final rows = math.max(1, (nodes.length + 1) ~/ 2);
    return Size(
      math.max(420.0, 2 * 210.0),
      math.max(180.0, rows * 96.0 + 40.0),
    );
  }
}

_ParsedDiagram _parseMermaid(String raw) {
  final lines = raw
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('%%'))
      .toList(growable: false);
  if (lines.isEmpty) {
    return const _ParsedDiagram(
      kind: 'flowchart',
      horizontal: false,
      nodes: <_DiagramNode>[],
      edges: <_DiagramEdge>[],
    );
  }

  final header = lines.first.toLowerCase();
  final isSeq = header.startsWith('sequencediagram');
  final isState = header.startsWith('statediagram');
  final isEr = header.startsWith('erdiagram');
  final horizontal = header.contains(' lr') || header.contains(' rl') || isEr;
  final kind = isSeq
      ? 'sequence'
      : isState
      ? 'state'
      : isEr
      ? 'er'
      : 'flowchart';

  final nodeMap = <String, _DiagramNode>{};
  final edges = <_DiagramEdge>[];

  String registerNode(String rawToken) {
    final cleaned = rawToken.trim();
    final bracket = RegExp(
      r'^([A-Za-z0-9_.-]+)\s*(?:\[\"?([^\]]+)\"?\]|\(\"?([^\)]+)\"?\)|\{\"?([^\}]+)\"?\})?',
    ).firstMatch(cleaned);
    if (bracket != null) {
      final id = bracket.group(1)!;
      final lbl =
          (bracket.group(2) ?? bracket.group(3) ?? bracket.group(4) ?? id)
              .replaceAll('"', '')
              .trim();
      nodeMap.putIfAbsent(id, () => _DiagramNode(id: id, label: lbl));
      return id;
    }
    nodeMap.putIfAbsent(
      cleaned,
      () => _DiagramNode(id: cleaned, label: cleaned),
    );
    return cleaned;
  }

  for (var idx = 1; idx < lines.length; idx++) {
    final line = lines[idx];
    if (isSeq) {
      final pMatch = RegExp(
        r'^(?:participant|actor)\s+([A-Za-z0-9_.-]+)(?:\s+as\s+(.+))?$',
      ).firstMatch(line);
      if (pMatch != null) {
        final id = pMatch.group(1)!;
        final label = (pMatch.group(2) ?? id).trim();
        nodeMap[id] = _DiagramNode(id: id, label: label);
        continue;
      }
      final msgMatch = RegExp(
        r'^([A-Za-z0-9_.-]+)\s*(->>|-->>|->|-->)\s*([A-Za-z0-9_.-]+)\s*:\s*(.*)$',
      ).firstMatch(line);
      if (msgMatch != null) {
        final from = registerNode(msgMatch.group(1)!);
        final arrow = msgMatch.group(2)!;
        final to = registerNode(msgMatch.group(3)!);
        final label = msgMatch.group(4)!.trim();
        edges.add(
          _DiagramEdge(
            from: from,
            to: to,
            label: label,
            dashed: arrow.startsWith('--'),
          ),
        );
      }
      continue;
    }

    final edgeMatch = RegExp(
      r'^(.+?)\s*(-->|\-\.\->|===|-->\|([^|]+)\||--\s*([^-]+)\s*-->|\|\|--o\{|\|\|--\|\|)\s*(.+)$',
    ).firstMatch(line);
    if (edgeMatch != null) {
      final fromId = registerNode(edgeMatch.group(1)!);
      final arrow = edgeMatch.group(2)!;
      final label = (edgeMatch.group(3) ?? edgeMatch.group(4) ?? '').trim();
      var rhs = edgeMatch.group(5)!.trim();
      var finalLabel = label;
      if (rhs.startsWith('|')) {
        final pipeEnd = rhs.indexOf('|', 1);
        if (pipeEnd > 1) {
          finalLabel = rhs.substring(1, pipeEnd).trim();
          rhs = rhs.substring(pipeEnd + 1).trim();
        }
      }
      final toId = registerNode(rhs);
      edges.add(
        _DiagramEdge(
          from: fromId,
          to: toId,
          label: finalLabel,
          dashed: arrow.contains('.'),
        ),
      );
    }
  }

  return _ParsedDiagram(
    kind: kind,
    horizontal: horizontal,
    nodes: nodeMap.values.toList(growable: false),
    edges: edges,
  );
}

class _MermaidPainter extends CustomPainter {
  const _MermaidPainter({required this.diagram, required this.theme});

  final _ParsedDiagram diagram;
  final BistreThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    if (diagram.kind == 'sequence') {
      _paintSequence(canvas, size);
    } else {
      _paintGraph(canvas, size);
    }
  }

  void _paintSequence(Canvas canvas, Size size) {
    final boxFill = Paint()..color = theme.bgSurface;
    final boxStroke = Paint()
      ..color = theme.accentBrass
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final linePaint = Paint()
      ..color = theme.borderHairline
      ..strokeWidth = 1.2;
    final arrowPaint = Paint()
      ..color = theme.accentWax
      ..strokeWidth = 1.6;

    final centersX = <String, double>{};
    for (var i = 0; i < diagram.nodes.length; i++) {
      final node = diagram.nodes[i];
      final cx = 74.0 + i * 148.0;
      centersX[node.id] = cx;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, 24), width: 122, height: 34),
        const Radius.circular(8),
      );
      canvas.drawRRect(rect, boxFill);
      canvas.drawRRect(rect, boxStroke);
      _drawCenteredText(
        canvas,
        node.label,
        Offset(cx, 24),
        112,
        theme.inkPrimary,
      );
      canvas.drawLine(Offset(cx, 41), Offset(cx, size.height - 16), linePaint);
    }

    for (var i = 0; i < diagram.edges.length; i++) {
      final edge = diagram.edges[i];
      final x1 = centersX[edge.from];
      final x2 = centersX[edge.to];
      if (x1 == null || x2 == null) continue;
      final y = 76.0 + i * 50.0;
      canvas.drawLine(Offset(x1, y), Offset(x2, y), arrowPaint);
      _drawArrowhead(canvas, Offset(x1, y), Offset(x2, y), arrowPaint);
      if (edge.label.isNotEmpty) {
        _drawCenteredText(
          canvas,
          edge.label,
          Offset((x1 + x2) / 2, y - 13),
          (x2 - x1).abs().clamp(90.0, 220.0),
          theme.inkSecondary,
          fontSize: 11.5,
        );
      }
    }
  }

  void _paintGraph(Canvas canvas, Size size) {
    final boxFill = Paint()..color = theme.bgSurface;
    final boxStroke = Paint()
      ..color = theme.accentBrass
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final edgePaint = Paint()
      ..color = theme.inkMuted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final rects = <String, Rect>{};
    for (var i = 0; i < diagram.nodes.length; i++) {
      final node = diagram.nodes[i];
      final Rect rect;
      if (diagram.horizontal) {
        final cx = 82.0 + i * 164.0;
        rect = Rect.fromCenter(
          center: Offset(cx, size.height / 2),
          width: 132,
          height: 46,
        );
      } else {
        final col = i % 2;
        final row = i ~/ 2;
        final cx = col == 0 ? 115.0 : 305.0;
        final cy = 44.0 + row * 94.0;
        rect = Rect.fromCenter(center: Offset(cx, cy), width: 152, height: 46);
      }
      rects[node.id] = rect;
    }

    for (final edge in diagram.edges) {
      final fromR = rects[edge.from];
      final toR = rects[edge.to];
      if (fromR == null || toR == null) continue;
      final start = Offset(fromR.center.dx, fromR.center.dy);
      final end = Offset(toR.center.dx, toR.center.dy);
      final clippedStart = _clipToRectEdge(fromR, end);
      final clippedEnd = _clipToRectEdge(toR, start);
      canvas.drawLine(clippedStart, clippedEnd, edgePaint);
      _drawArrowhead(canvas, clippedStart, clippedEnd, edgePaint);
      if (edge.label.isNotEmpty) {
        final mid = Offset(
          (clippedStart.dx + clippedEnd.dx) / 2,
          (clippedStart.dy + clippedEnd.dy) / 2 - 10,
        );
        _drawCenteredText(
          canvas,
          edge.label,
          mid,
          120,
          theme.accentBrass,
          fontSize: 11,
        );
      }
    }

    for (final node in diagram.nodes) {
      final rect = rects[node.id]!;
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(9));
      canvas.drawRRect(rrect, boxFill);
      canvas.drawRRect(rrect, boxStroke);
      _drawCenteredText(
        canvas,
        node.label,
        rect.center,
        rect.width - 14,
        theme.inkPrimary,
      );
    }
  }

  Offset _clipToRectEdge(Rect rect, Offset target) {
    final dx = target.dx - rect.center.dx;
    final dy = target.dy - rect.center.dy;
    if (dx == 0 && dy == 0) return rect.center;
    final scaleX = dx != 0 ? (rect.width / 2) / dx.abs() : double.infinity;
    final scaleY = dy != 0 ? (rect.height / 2) / dy.abs() : double.infinity;
    final s = math.min(scaleX, scaleY);
    return Offset(rect.center.dx + dx * s, rect.center.dy + dy * s);
  }

  void _drawArrowhead(Canvas canvas, Offset from, Offset to, Paint paint) {
    final angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    const len = 8.0;
    const spread = 0.45;
    final p1 = Offset(
      to.dx - len * math.cos(angle - spread),
      to.dy - len * math.sin(angle - spread),
    );
    final p2 = Offset(
      to.dx - len * math.cos(angle + spread),
      to.dy - len * math.sin(angle + spread),
    );
    canvas.drawLine(to, p1, paint);
    canvas.drawLine(to, p2, paint);
  }

  void _drawCenteredText(
    Canvas canvas,
    String text,
    Offset center,
    double maxWidth,
    Color color, {
    double fontSize = 12.5,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: theme.typography.proseFontFamily,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
      textAlign: TextAlign.center,
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _MermaidPainter oldDelegate) =>
      oldDelegate.diagram != diagram || oldDelegate.theme != theme;
}
