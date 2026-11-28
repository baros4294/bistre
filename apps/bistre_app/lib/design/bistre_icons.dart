import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'bistre_decorations.dart';
import 'bistre_theme.dart';
import 'hover_hint.dart';
import 'ink_primitives.dart';
import 'press_feedback.dart';

/// Bistre's offline-compiled `.vec` UI icons (`assets/icons/ui/*.vec`).
enum BistreUiIcon {
  sidebar('sidebar'),
  newChat('new_chat'),
  plus('plus'),
  pin('pin'),
  pinFilled('pin_filled'),
  search('search'),
  settings('settings'),
  command('command'),
  send('send'),
  stop('stop'),
  copy('copy'),
  check('check'),
  reply('reply'),
  refresh('refresh'),
  trash('trash'),
  edit('edit'),
  close('close'),
  arrowBack('arrow_back'),
  chevronStart('chevron_start'),
  chevronEnd('chevron_end'),
  chevronDown('chevron_down'),
  chevronUp('chevron_up'),
  assistant('assistant'),
  sliders('sliders'),
  globe('globe'),
  shield('shield'),
  keyboard('keyboard'),
  sun('sun'),
  moon('moon'),
  systemTheme('system_theme'),
  document('document'),
  bubbles('bubbles'),
  key('key'),
  server('server'),
  eye('eye'),
  eyeOff('eye_off'),
  download('download'),
  folder('folder'),
  font('font'),
  exportIcon('export'),
  palette('palette'),
  code('code'),
  chat('chat'),
  think('think'),
  terminal('terminal'),
  branchTree('branch_tree'),
  rewind('rewind'),
  paperclip('paperclip'),
  awake('awake'),
  schedule('schedule'),
  worktree('worktree'),
  mcpPlug('mcp_plug'),
  tableGrid('table_grid'),
  diagram('diagram'),
  memory('memory'),
  bookOpen('book_open'),
  info('info'),
  wrap('wrap'),
  mic('mic'),
  volume('volume'),
  audioLines('audio_lines');

  const BistreUiIcon(this.fileStem);
  final String fileStem;

  String get assetPath => 'assets/icons/ui/$fileStem.vec';
}

/// Renders one of Bistre's bespoke `.vec` UI icons tinted cleanly to the active ink color.
class BistreIcon extends StatelessWidget {
  const BistreIcon(
    this.icon, {
    super.key,
    this.size = 16,
    this.color,
    this.semanticsLabel = '',
  });

  final BistreUiIcon icon;
  final double size;
  final Color? color;
  final String semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return EngravedIcon(
      assetPath: icon.assetPath,
      semanticsLabel: semanticsLabel,
      // Grows with the text size (capped), so icons keep pace with the words beside them.
      size: size * iconScaleOf(context),
      color: color ?? theme.inkSecondary,
    );
  }
}

/// Keyboard-accessible tactile icon button with brass focus ring and subtle hover surface.
class BistreIconButton extends StatefulWidget {
  const BistreIconButton({
    super.key,
    required this.icon,
    required this.semanticsLabel,
    required this.onPressed,
    this.size = 17,
    this.dimension = 34,
    this.color,
    this.active = false,
  });

  final BistreUiIcon icon;
  final String semanticsLabel;
  final VoidCallback? onPressed;
  final double size;
  final double dimension;
  final Color? color;
  final bool active;

  @override
  State<BistreIconButton> createState() => _BistreIconButtonState();
}

class _BistreIconButtonState extends State<BistreIconButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final enabled = widget.onPressed != null;
    final fg =
        widget.color ??
        (widget.active
            ? theme.accentBrass
            : _hovered
            ? theme.inkPrimary
            : theme.inkSecondary);

    // Taps up to the minimum target land on this button without changing layout (DESIGN §7).
    // Every icon button names itself on hover via `HoverHint`.
    // Keeping `SizedBox.square` outside the hover/press wrappers makes the fixed button a
    // relayout boundary so sibling layout changes never re-lay out its subtree.
    return TapTargetExpander(
      minSize: minTapTarget,
      child: SizedBox.square(
        dimension: widget.dimension * iconScaleOf(context),
        child: HoverHint(
          message: widget.semanticsLabel,
          child: PressFeedback(
            enabled: enabled,
            child: Semantics(
              button: true,
              enabled: enabled,
              label: widget.semanticsLabel,
              child: FocusableActionDetector(
                enabled: enabled,
                mouseCursor: enabled
                    ? SystemMouseCursors.click
                    : SystemMouseCursors.basic,
                onShowHoverHighlight: (v) => setState(() => _hovered = v),
                onShowFocusHighlight: (v) => setState(() => _focused = v),
                shortcuts: const <ShortcutActivator, Intent>{
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                },
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      widget.onPressed?.call();
                      return null;
                    },
                  ),
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: enabled
                      ? (_) => setState(() => _pressed = true)
                      : null,
                  onTapUp: enabled
                      ? (_) {
                          setState(() => _pressed = false);
                          widget.onPressed?.call();
                        }
                      : null,
                  onTapCancel: () => setState(() => _pressed = false),
                  child: Opacity(
                    opacity: !enabled
                        ? 0.40
                        : _pressed
                        ? 0.72
                        : 1.0,
                    child: EaseDecoration(
                      decoration: BoxDecoration(
                        color: widget.active
                            ? theme.hoverTint
                            : (_hovered ? theme.hoverTint : null),
                        borderRadius: BorderRadius.circular(8),
                        border: _focused
                            ? Border.all(color: theme.accentBrass, width: 1.6)
                            : null,
                      ),
                      child: Center(
                        child: BistreIcon(
                          widget.icon,
                          size: widget.size,
                          color: fg,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Whether this is a touch-first platform (phone or tablet), where keyboard hints are noise.
bool get isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Smallest tap area for a control: 48 dp on touch screens, 40 px with a pointer.
double get minTapTarget => isTouchPlatform ? 48 : 40;

/// Accepts taps within a [minSize] square centred on its child, while laying out and painting
/// at the child's own size, so small icons get a full tap area without growing their rows.
class TapTargetExpander extends SingleChildRenderObjectWidget {
  const TapTargetExpander({super.key, required this.minSize, super.child});

  final double minSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTapTargetExpander(minSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTapTargetExpander renderObject,
  ) {
    renderObject.minSize = minSize;
  }
}

class _RenderTapTargetExpander extends RenderProxyBox {
  _RenderTapTargetExpander(this.minSize);

  double minSize;

  /// Every expander on screen, so a widened target yields to a nearer control.
  static final Set<_RenderTapTargetExpander> _live = {};

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _live.add(this);
  }

  @override
  void detach() {
    _live.remove(this);
    super.detach();
  }

  Rect _area(Rect box) {
    final extraX = ((minSize - box.width) / 2).clamp(0.0, double.infinity);
    final extraY = ((minSize - box.height) / 2).clamp(0.0, double.infinity);
    return Rect.fromLTRB(
      box.left - extraX,
      box.top - extraY,
      box.right + extraX,
      box.bottom + extraY,
    );
  }

  Rect get _globalBox =>
      MatrixUtils.transformRect(getTransformTo(null), Offset.zero & size);

  /// The row or wrap that lays this control out beside its neighbours.
  RenderObject? get _row {
    RenderObject? node = parent;
    for (var depth = 0; depth < 12 && node != null; depth++) {
      if (node is RenderFlex || node is RenderWrap) return node;
      node = node.parent;
    }
    return null;
  }

  /// Whether a neighbour in the same row holds [global] in its own box, or is nearer to it.
  bool _nearerControlAt(Offset global) {
    final row = _row;
    if (row == null) return false;
    final mine = _distance(_globalBox, global);
    for (final other in _live) {
      if (identical(other, this) || !other.hasSize || other._row != row) {
        continue;
      }
      final box = other._globalBox;
      if (box.contains(global)) return true;
      if (other._area(box).contains(global) && _distance(box, global) < mine) {
        return true;
      }
    }
    return false;
  }

  static double _distance(Rect box, Offset p) =>
      (p -
              Offset(
                p.dx.clamp(box.left, box.right),
                p.dy.clamp(box.top, box.bottom),
              ))
          .distance;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final box = Offset.zero & size;
    if (!_area(box).contains(position)) return false;
    if (!box.contains(position) && _nearerControlAt(localToGlobal(position))) {
      return false;
    }
    // Route the tap to the child's nearest point so its gesture handlers fire.
    final inside = Offset(
      position.dx.clamp(0.0, size.width - 0.01),
      position.dy.clamp(0.0, size.height - 0.01),
    );
    if (hitTestChildren(result, position: inside) || hitTestSelf(inside)) {
      result.add(BoxHitTestEntry(this, inside));
      return true;
    }
    return false;
  }
}

/// Entry describing one offline-compiled AI lab/provider `.vec` mark.
@immutable
class LabIconEntry {
  const LabIconEntry({
    required this.slug,
    required this.displayName,
    this.isMonochromeBrand = false,
  });

  final String slug;
  final String displayName;
  final bool isMonochromeBrand;

  String get assetPath => 'assets/icons/labs/$slug.vec';
}

/// Pure offline registry of 42 pre-compiled `.vec` AI lab icons (zero external references).
class LabIconCatalog {
  const LabIconCatalog._();

  static const List<LabIconEntry> all = <LabIconEntry>[
    LabIconEntry(
      slug: 'openai',
      displayName: 'OpenAI',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'gemini', displayName: 'Gemini'),
    LabIconEntry(slug: 'google', displayName: 'Google'),
    LabIconEntry(slug: 'claude', displayName: 'Claude'),
    LabIconEntry(
      slug: 'anthropic',
      displayName: 'Anthropic',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'deepseek', displayName: 'DeepSeek'),
    LabIconEntry(slug: 'qwen', displayName: 'Qwen'),
    LabIconEntry(slug: 'mistral', displayName: 'Mistral'),
    LabIconEntry(slug: 'meta', displayName: 'Meta'),
    LabIconEntry(
      slug: 'ollama',
      displayName: 'Ollama',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'openrouter', displayName: 'OpenRouter'),
    LabIconEntry(slug: 'xai', displayName: 'xAI', isMonochromeBrand: true),
    LabIconEntry(slug: 'grok', displayName: 'Grok', isMonochromeBrand: true),
    LabIconEntry(slug: 'groq', displayName: 'Groq', isMonochromeBrand: true),
    LabIconEntry(slug: 'cohere', displayName: 'Cohere'),
    LabIconEntry(slug: 'perplexity', displayName: 'Perplexity'),
    LabIconEntry(slug: 'together', displayName: 'Together'),
    LabIconEntry(slug: 'fireworks', displayName: 'Fireworks'),
    LabIconEntry(slug: 'huggingface', displayName: 'Hugging Face'),
    LabIconEntry(slug: 'azureai', displayName: 'Azure AI'),
    LabIconEntry(slug: 'azure', displayName: 'Azure'),
    LabIconEntry(slug: 'bedrock', displayName: 'Bedrock'),
    LabIconEntry(slug: 'vertexai', displayName: 'Vertex AI'),
    LabIconEntry(slug: 'kimi', displayName: 'Kimi'),
    LabIconEntry(
      slug: 'moonshot',
      displayName: 'Moonshot',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'zhipu', displayName: 'Zhipu'),
    LabIconEntry(slug: 'nvidia', displayName: 'NVIDIA'),
    LabIconEntry(slug: 'cloudflare', displayName: 'Cloudflare'),
    LabIconEntry(
      slug: 'github',
      displayName: 'GitHub',
      isMonochromeBrand: true,
    ),
    LabIconEntry(
      slug: 'lmstudio',
      displayName: 'LM Studio',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'vllm', displayName: 'vLLM'),
    LabIconEntry(slug: 'sambanova', displayName: 'SambaNova'),
    LabIconEntry(slug: 'cerebras', displayName: 'Cerebras'),
    LabIconEntry(slug: 'reka', displayName: 'Reka', isMonochromeBrand: true),
    LabIconEntry(slug: 'yi', displayName: 'Yi'),
    LabIconEntry(slug: 'minimax', displayName: 'MiniMax'),
    LabIconEntry(slug: 'siliconcloud', displayName: 'SiliconCloud'),
    LabIconEntry(
      slug: 'vercel',
      displayName: 'Vercel',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'deepinfra', displayName: 'DeepInfra'),
    LabIconEntry(slug: 'novita', displayName: 'Novita'),
    LabIconEntry(
      slug: 'replicate',
      displayName: 'Replicate',
      isMonochromeBrand: true,
    ),
    LabIconEntry(slug: 'hyperbolic', displayName: 'Hyperbolic'),
  ];

  static final Map<String, LabIconEntry> _bySlug = <String, LabIconEntry>{
    for (final e in all) e.slug: e,
  };

  /// Resolves an opaque local icon slug, provider dialect, provider name, or model ID
  /// to a bundled offline `.vec` entry.
  static LabIconEntry? resolve({
    String? iconSlug,
    String? dialect,
    String? providerName,
    String? modelId,
  }) {
    final s = iconSlug?.trim().toLowerCase() ?? '';
    if (s.isNotEmpty && _bySlug.containsKey(s)) {
      return _bySlug[s];
    }

    final probe = '${modelId ?? ''} ${providerName ?? ''} ${dialect ?? ''}'
        .toLowerCase();
    if (probe.contains('claude')) return _bySlug['claude'];
    if (probe.contains('anthropic')) return _bySlug['claude'];
    if (probe.contains('gemini')) return _bySlug['gemini'];
    if (probe.contains('google')) return _bySlug['google'];
    if (probe.contains('deepseek')) return _bySlug['deepseek'];
    if (probe.contains('qwen')) return _bySlug['qwen'];
    if (probe.contains('mistral') || probe.contains('mixtral')) {
      return _bySlug['mistral'];
    }
    if (probe.contains('llama') || probe.contains('meta')) {
      return _bySlug['meta'];
    }
    if (probe.contains('ollama')) return _bySlug['ollama'];
    if (probe.contains('openrouter')) return _bySlug['openrouter'];
    if (probe.contains('grok')) return _bySlug['grok'];
    if (probe.contains('xai') || probe.contains('x.ai')) return _bySlug['xai'];
    if (probe.contains('groq')) return _bySlug['groq'];
    if (probe.contains('cohere') || probe.contains('command-r')) {
      return _bySlug['cohere'];
    }
    if (probe.contains('perplexity') || probe.contains('sonar')) {
      return _bySlug['perplexity'];
    }
    if (probe.contains('together')) return _bySlug['together'];
    if (probe.contains('fireworks')) return _bySlug['fireworks'];
    if (probe.contains('hugging')) return _bySlug['huggingface'];
    if (probe.contains('kimi')) return _bySlug['kimi'];
    if (probe.contains('moonshot')) return _bySlug['moonshot'];
    if (probe.contains('zhipu') || probe.contains('glm')) {
      return _bySlug['zhipu'];
    }
    if (probe.contains('nvidia')) return _bySlug['nvidia'];
    if (probe.contains('bedrock')) return _bySlug['bedrock'];
    if (probe.contains('vertex')) return _bySlug['vertexai'];
    if (probe.contains('azure')) return _bySlug['azureai'];
    if (probe.contains('lmstudio') || probe.contains('lm studio')) {
      return _bySlug['lmstudio'];
    }
    if (probe.contains('vllm')) return _bySlug['vllm'];
    if (probe.contains('openai') ||
        probe.contains('gpt-') ||
        _oSeries.hasMatch(modelId?.toLowerCase() ?? '')) {
      return _bySlug['openai'];
    }
    return null;
  }

  /// An `o1`/`o3`/`o4` model id (optionally after a `vendor/` prefix), never a name that
  /// merely contains those letters ("solo1", "pro3").
  static final RegExp _oSeries = RegExp(r'(?:^|/)o[134](?:$|[-_.])');
}

/// Renders an authentic full-color (or theme-adaptive monochrome brand) AI lab icon,
/// with optional user-provided local `.png`/`.webp` custom image support.
class LabIcon extends StatelessWidget {
  const LabIcon({
    super.key,
    this.iconSlug,
    this.customIconPath,
    this.dialect,
    this.providerName,
    this.modelId,
    this.size = 18,
    this.framed = false,
  });

  final String? iconSlug;
  final String? customIconPath;
  final String? dialect;
  final String? providerName;
  final String? modelId;
  final double size;
  final bool framed;

  /// Whether a custom icon file exists, checked once per path (never disk I/O on every build).
  static final Map<String, bool> _existsCache = <String, bool>{};

  static bool _customIconExists(String path) {
    if (_existsCache.length > 128) _existsCache.clear();
    return _existsCache.putIfAbsent(path, () => File(path).existsSync());
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final customPath = customIconPath?.trim() ?? '';
    Widget mark;

    if (customPath.isNotEmpty && _customIconExists(customPath)) {
      mark = ClipRRect(
        borderRadius: BorderRadius.circular(4),
        // Decoded at the size it is drawn, never the file's full size.
        child: Image.file(
          File(customPath),
          width: size,
          height: size,
          cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              BistreIcon(BistreUiIcon.server, size: size),
        ),
      );
    } else {
      final entry = LabIconCatalog.resolve(
        iconSlug: iconSlug,
        dialect: dialect,
        providerName: providerName,
        modelId: modelId,
      );
      if (entry != null) {
        mark = EngravedIcon(
          assetPath: entry.assetPath,
          semanticsLabel: entry.displayName,
          size: size,
          // Full-color labs keep native brand colors; monochrome brands adapt to active ink.
          color: entry.isMonochromeBrand ? theme.inkPrimary : null,
        );
      } else {
        mark = BistreIcon(
          BistreUiIcon.server,
          size: size,
          color: theme.inkSecondary,
        );
      }
    }

    if (!framed) return mark;

    return SizedBox.square(
      dimension: size + 12,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.borderHairline),
        ),
        child: Center(child: mark),
      ),
    );
  }
}

/// Archival hairline rule tapering delicately toward both ends with a brass diamond center.
class BistreOrnamentalRule extends StatelessWidget {
  const BistreOrnamentalRule({super.key, this.width = 160});

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Center(
      child: SizedBox(
        width: width,
        height: 9,
        child: CustomPaint(
          painter: _OrnamentalRulePainter(
            lineColor: theme.borderHairline,
            accentColor: theme.accentBrass.withValues(alpha: 0.65),
          ),
        ),
      ),
    );
  }
}

class _OrnamentalRulePainter extends CustomPainter {
  const _OrnamentalRulePainter({
    required this.lineColor,
    required this.accentColor,
  });

  final Color lineColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final cx = size.width / 2;
    final leftPaint = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        colors: <Color>[lineColor.withValues(alpha: 0), lineColor],
      ).createShader(Rect.fromLTWH(0, cy - 1, cx - 10, 2));
    canvas.drawLine(Offset(0, cy), Offset(cx - 10, cy), leftPaint);

    final rightPaint = Paint()
      ..strokeWidth = 1
      ..shader = LinearGradient(
        colors: <Color>[lineColor, lineColor.withValues(alpha: 0)],
      ).createShader(Rect.fromLTWH(cx + 10, cy - 1, cx - 10, 2));
    canvas.drawLine(Offset(cx + 10, cy), Offset(size.width, cy), rightPaint);

    final diamond = Path()
      ..moveTo(cx, cy - 3.2)
      ..lineTo(cx + 3.2, cy)
      ..lineTo(cx, cy + 3.2)
      ..lineTo(cx - 3.2, cy)
      ..close();
    canvas.drawPath(diamond, Paint()..color = accentColor);
  }

  @override
  bool shouldRepaint(_OrnamentalRulePainter old) =>
      old.lineColor != lineColor || old.accentColor != accentColor;
}
