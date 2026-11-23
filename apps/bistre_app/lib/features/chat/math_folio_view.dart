import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/math_font_gate.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Pure-Dart TeX math formula renderer backed by Bistre's bundled offline `NotoSansMath` font.
/// Zero WebView, zero third-party packages, zero Material/Cupertino dependencies.
/// Supports display `$$...$$` and inline `$...$`: fractions (`\frac`), superscripts (`^`),
/// subscripts (`_`), square roots (`\sqrt`), Greek symbols, operators, and matrices.
class MathFolioView extends StatefulWidget {
  const MathFolioView({
    super.key,
    required this.latex,
    required this.onCopyLatex,
    this.displayMode = true,
  });

  final String latex;
  final ValueChanged<String> onCopyLatex;
  final bool displayMode;

  /// Converts TeX symbol commands into crisp Unicode glyphs rendered in `NotoSansMath`.
  static String renderInlineUnicode(String tex) => _substituteSymbols(tex);

  @override
  State<MathFolioView> createState() => _MathFolioViewState();
}

class _MathFolioViewState extends State<MathFolioView> {
  bool _copied = false;

  void _copy() {
    widget.onCopyLatex(widget.latex);
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(MathFontGate.ensureLoaded());
    MathFontGate.ready.addListener(_onFontReady);
  }

  @override
  void dispose() {
    MathFontGate.ready.removeListener(_onFontReady);
    super.dispose();
  }

  void _onFontReady() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final baseSize = theme.typography.baseFontSizePx;
    final mathStyle = TextStyle(
      fontFamily: MathFontGate.family,
      fontSize: widget.displayMode ? baseSize * 1.18 : baseSize * 1.02,
      height: 1.35,
      color: theme.inkPrimary,
    );

    final rendered = Directionality(
      textDirection: TextDirection.ltr,
      child: _MathExprWidget(
        nodes: _parseMathNodes(widget.latex.trim()),
        style: mathStyle,
        hairlineColor: theme.inkSecondary,
      ),
    );

    if (!widget.displayMode) {
      return rendered;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.isDark
            ? theme.bgCanvas
            : theme.bgSurface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.borderHairline),
      ),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Padding(
                  padding: const EdgeInsetsDirectional.symmetric(vertical: 4),
                  child: rendered,
                ),
              ),
            ),
            const SizedBox(width: 8),
            BistreIconButton(
              icon: _copied ? BistreUiIcon.check : BistreUiIcon.copy,
              size: 13,
              dimension: 28,
              color: _copied ? theme.statusOk : theme.inkMuted,
              semanticsLabel: l10n.t(L10nKey.chatMathCopyLatex),
              onPressed: _copy,
            ),
          ],
        ),
      ),
    );
  }
}

sealed class _MathNode {
  const _MathNode();
}

final class _MathText extends _MathNode {
  const _MathText(this.text);
  final String text;
}

final class _MathFrac extends _MathNode {
  const _MathFrac(this.num, this.den);
  final List<_MathNode> num;
  final List<_MathNode> den;
}

final class _MathSqrt extends _MathNode {
  const _MathSqrt(this.body);
  final List<_MathNode> body;
}

final class _MathScript extends _MathNode {
  const _MathScript({required this.base, this.sup, this.sub});
  final _MathNode base;
  final List<_MathNode>? sup;
  final List<_MathNode>? sub;
}

final class _MathMatrix extends _MathNode {
  const _MathMatrix(this.rows);
  final List<List<List<_MathNode>>> rows;
}

class _MathExprWidget extends StatelessWidget {
  const _MathExprWidget({
    required this.nodes,
    required this.style,
    required this.hairlineColor,
  });

  final List<_MathNode> nodes;
  final TextStyle style;
  final Color hairlineColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [for (final n in nodes) _buildNode(n)],
    );
  }

  static const String _radicalGlyph = '√';
  static const String _openBracketGlyph = '[';
  static const String _closeBracketGlyph = ']';

  Widget _buildNode(_MathNode node) {
    final fontSize = style.fontSize ?? 16.0;
    return switch (node) {
      _MathText(:final text) => Text.rich(TextSpan(text: text, style: style)),
      _MathFrac(:final num, :final den) => Padding(
        padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
        child: IntrinsicWidth(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MathExprWidget(
                nodes: num,
                style: style.copyWith(fontSize: fontSize * 0.84),
                hairlineColor: hairlineColor,
              ),
              Container(
                margin: const EdgeInsetsDirectional.symmetric(vertical: 2),
                height: 1.2,
                color: hairlineColor,
              ),
              _MathExprWidget(
                nodes: den,
                style: style.copyWith(fontSize: fontSize * 0.84),
                hairlineColor: hairlineColor,
              ),
            ],
          ),
        ),
      ),
      _MathSqrt(:final body) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              text: _radicalGlyph,
              style: style.copyWith(fontSize: fontSize * 1.08),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: hairlineColor, width: 1.1)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(2, 1, 3, 0),
              child: _MathExprWidget(
                nodes: body,
                style: style.copyWith(fontSize: fontSize * 0.94),
                hairlineColor: hairlineColor,
              ),
            ),
          ),
        ],
      ),
      _MathScript(:final base, :final sup, :final sub) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNode(base),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sup != null)
                Transform.translate(
                  offset: Offset(0, -fontSize * 0.18),
                  child: _MathExprWidget(
                    nodes: sup,
                    style: style.copyWith(fontSize: fontSize * 0.68),
                    hairlineColor: hairlineColor,
                  ),
                ),
              if (sub != null)
                Transform.translate(
                  offset: Offset(0, fontSize * 0.14),
                  child: _MathExprWidget(
                    nodes: sub,
                    style: style.copyWith(fontSize: fontSize * 0.68),
                    hairlineColor: hairlineColor,
                  ),
                ),
            ],
          ),
        ],
      ),
      _MathMatrix(:final rows) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              text: _openBracketGlyph,
              style: style.copyWith(fontSize: fontSize * 1.45),
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsetsDirectional.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var c = 0; c < row.length; c++) ...[
                          if (c > 0) const SizedBox(width: 12),
                          _MathExprWidget(
                            nodes: row[c],
                            style: style.copyWith(fontSize: fontSize * 0.92),
                            hairlineColor: hairlineColor,
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Text.rich(
            TextSpan(
              text: _closeBracketGlyph,
              style: style.copyWith(fontSize: fontSize * 1.45),
            ),
          ),
        ],
      ),
    };
  }
}

List<_MathNode> _parseMathNodes(String input) {
  final nodes = <_MathNode>[];
  var i = 0;
  final buf = StringBuffer();

  void flushText() {
    if (buf.isNotEmpty) {
      nodes.add(_MathText(_substituteSymbols(buf.toString())));
      buf.clear();
    }
  }

  (String, int) readGroup(int start) {
    var pos = start;
    while (pos < input.length && input[pos] == ' ') {
      pos++;
    }
    if (pos >= input.length) return ('', pos);
    if (input[pos] != '{') {
      if (input[pos] == r'\') {
        final end = _readCommandEnd(input, pos);
        return (input.substring(pos, end), end);
      }
      return (input[pos], pos + 1);
    }
    var depth = 0;
    final bodyStart = pos + 1;
    while (pos < input.length) {
      if (input[pos] == '{') depth++;
      if (input[pos] == '}') {
        depth--;
        if (depth == 0) {
          return (input.substring(bodyStart, pos), pos + 1);
        }
      }
      pos++;
    }
    return (input.substring(bodyStart), input.length);
  }

  while (i < input.length) {
    if (input.startsWith(r'\begin{pmatrix}', i) ||
        input.startsWith(r'\begin{bmatrix}', i) ||
        input.startsWith(r'\begin{matrix}', i)) {
      flushText();
      final envEnd = input.indexOf('}', i);
      final envName = input.substring(i + 7, envEnd);
      final closeTag = '\\end{$envName}';
      final closeIdx = input.indexOf(closeTag, envEnd + 1);
      if (closeIdx > envEnd) {
        final body = input.substring(envEnd + 1, closeIdx);
        final rows = body
            .split(r'\\')
            .where((r) => r.trim().isNotEmpty)
            .map(
              (row) => row
                  .split('&')
                  .map((cell) => _parseMathNodes(cell.trim()))
                  .toList(growable: false),
            )
            .toList(growable: false);
        nodes.add(_MathMatrix(rows));
        i = closeIdx + closeTag.length;
        continue;
      }
    }

    if (input.startsWith(r'\frac', i)) {
      flushText();
      final (numStr, p1) = readGroup(i + 5);
      final (denStr, p2) = readGroup(p1);
      nodes.add(_MathFrac(_parseMathNodes(numStr), _parseMathNodes(denStr)));
      i = p2;
      continue;
    }

    if (input.startsWith(r'\sqrt', i)) {
      flushText();
      final (radStr, p1) = readGroup(i + 5);
      nodes.add(_MathSqrt(_parseMathNodes(radStr)));
      i = p1;
      continue;
    }

    if (input[i] == '^' || input[i] == '_') {
      _MathNode base;
      if (buf.isNotEmpty) {
        final raw = buf.toString();
        buf.clear();
        if (raw.length > 1) {
          nodes.add(
            _MathText(_substituteSymbols(raw.substring(0, raw.length - 1))),
          );
          base = _MathText(_substituteSymbols(raw[raw.length - 1]));
        } else {
          base = _MathText(_substituteSymbols(raw));
        }
      } else if (nodes.isNotEmpty) {
        base = nodes.removeLast();
      } else {
        base = const _MathText('');
      }

      List<_MathNode>? sup;
      List<_MathNode>? sub;
      while (i < input.length && (input[i] == '^' || input[i] == '_')) {
        final isSup = input[i] == '^';
        final (grp, nextPos) = readGroup(i + 1);
        if (isSup) {
          sup = _parseMathNodes(grp);
        } else {
          sub = _parseMathNodes(grp);
        }
        i = nextPos;
      }
      nodes.add(_MathScript(base: base, sup: sup, sub: sub));
      continue;
    }

    if (input[i] == r'\') {
      final cmdEnd = _readCommandEnd(input, i);
      final cmd = input.substring(i, cmdEnd);
      if (cmd == r'\left' || cmd == r'\right') {
        i = cmdEnd;
        continue;
      }
      if (cmd == r'\text' || cmd == r'\mathrm' || cmd == r'\mathbf') {
        final (grp, nextPos) = readGroup(cmdEnd);
        buf.write(grp);
        i = nextPos;
        continue;
      }
      buf.write(_mathSymbols[cmd] ?? cmd.substring(1));
      i = cmdEnd;
      continue;
    }

    if (input[i] == '{' || input[i] == '}') {
      i++;
      continue;
    }

    buf.write(input[i]);
    i++;
  }

  flushText();
  return nodes;
}

int _readCommandEnd(String s, int start) {
  var pos = start + 1;
  while (pos < s.length && RegExp(r'[A-Za-z]').hasMatch(s[pos])) {
    pos++;
  }
  return pos == start + 1 && pos < s.length ? pos + 1 : pos;
}

String _substituteSymbols(String input) {
  var out = input.replaceAllMapped(
    RegExp(r'\\(?:text|mathrm)\{([^}]*)\}'),
    (m) => ' ${m.group(1) ?? ''}',
  );
  for (final entry in _mathSymbols.entries) {
    if (out.contains(entry.key)) {
      out = out.replaceAll(entry.key, entry.value);
    }
  }
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const Map<String, String> _mathSymbols = <String, String>{
  r'\alpha': 'α',
  r'\beta': 'β',
  r'\gamma': 'γ',
  r'\delta': 'δ',
  r'\epsilon': 'ε',
  r'\varepsilon': 'ε',
  r'\zeta': 'ζ',
  r'\eta': 'η',
  r'\theta': 'θ',
  r'\lambda': 'λ',
  r'\mu': 'μ',
  r'\nu': 'ν',
  r'\xi': 'ξ',
  r'\pi': 'π',
  r'\rho': 'ρ',
  r'\sigma': 'σ',
  r'\tau': 'τ',
  r'\phi': 'φ',
  r'\varphi': 'φ',
  r'\chi': 'χ',
  r'\psi': 'ψ',
  r'\omega': 'ω',
  r'\Gamma': 'Γ',
  r'\Delta': 'Δ',
  r'\Theta': 'Θ',
  r'\Lambda': 'Λ',
  r'\Pi': 'Π',
  r'\Sigma': 'Σ',
  r'\Phi': 'Φ',
  r'\Psi': 'Ψ',
  r'\Omega': 'Ω',
  r'\sum': '∑',
  r'\prod': '∏',
  r'\int': '∫',
  r'\oint': '∮',
  r'\partial': '∂',
  r'\nabla': '∇',
  r'\infty': '∞',
  r'\pm': '±',
  r'\mp': '∓',
  r'\times': '×',
  r'\cdot': '·',
  r'\div': '÷',
  r'\leq': '≤',
  r'\le': '≤',
  r'\geq': '≥',
  r'\ge': '≥',
  r'\neq': '≠',
  r'\ne': '≠',
  r'\approx': '≈',
  r'\equiv': '≡',
  r'\sim': '∼',
  r'\propto': '∝',
  r'\to': '→',
  r'\rightarrow': '→',
  r'\leftarrow': '←',
  r'\Rightarrow': '⇒',
  r'\Leftarrow': '⇐',
  r'\iff': '⇔',
  r'\in': '∈',
  r'\notin': '∉',
  r'\subset': '⊂',
  r'\subseteq': '⊆',
  r'\cup': '∪',
  r'\cap': '∩',
  r'\forall': '∀',
  r'\exists': '∃',
  r'\mathbb{R}': 'ℝ',
  r'\mathbb{N}': 'ℕ',
  r'\mathbb{Z}': 'ℤ',
  r'\mathbb{C}': 'ℂ',
  r'\quad': '  ',
  r'\,': ' ',
};
