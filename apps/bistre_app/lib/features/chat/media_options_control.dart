import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/popover_placement.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// The picture and video format sent with a request. Core sends each value only to a model
/// whose catalog entry lists it; null leaves that setting to the provider.
@immutable
class MediaOptions {
  const MediaOptions({this.aspectRatio, this.resolution, this.durationS});

  factory MediaOptions.fromJson(Map<String, Object?> json) => MediaOptions(
    aspectRatio: json['aspect_ratio'] is String
        ? json['aspect_ratio']! as String
        : null,
    resolution: json['resolution'] is String
        ? json['resolution']! as String
        : null,
    durationS: json['duration_s'] is int ? json['duration_s']! as int : null,
  );

  /// The settings key core reads (`media_gen::MEDIA_OPTIONS_KEY`).
  static const String kvKey = 'settings.media_options';

  final String? aspectRatio;
  final String? resolution;
  final int? durationS;

  bool get isEmpty =>
      aspectRatio == null && resolution == null && durationS == null;

  Map<String, Object?> toJson() => <String, Object?>{
    'aspect_ratio': ?aspectRatio,
    'resolution': ?resolution,
    'duration_s': ?durationS,
  };

  /// The values [info] lists; the rest show as Default, as core sends them.
  MediaOptions forModel(EngineModelCatalogInfo info) => MediaOptions(
    aspectRatio: info.aspectRatios.contains(aspectRatio) ? aspectRatio : null,
    resolution: info.resolutions.contains(resolution) ? resolution : null,
    durationS: info.durationsS.contains(durationS) ? durationS : null,
  );
}

/// Width over height of a catalog shape (`16:9`, `9:19.5`); null when it is not one.
double? aspectOf(String shape) {
  final parts = shape.split(':');
  if (parts.length != 2) return null;
  final w = double.tryParse(parts[0]);
  final h = double.tryParse(parts[1]);
  if (w == null || h == null || w <= 0 || h <= 0) return null;
  return w / h;
}

/// Composer chip `Format: 16:9 · 2K` that opens the choices the active model lists, beside
/// the Thinking chip when the model also thinks.
class MediaOptionsControl extends StatefulWidget {
  const MediaOptionsControl({
    super.key,
    required this.info,
    required this.value,
    required this.onChanged,
    this.reduceMotionOverride = false,
    this.compact = false,
  });

  final EngineModelCatalogInfo info;
  final MediaOptions value;
  final ValueChanged<MediaOptions> onChanged;
  final bool reduceMotionOverride;

  /// Narrow windows and large text show only the chosen values; screen readers still get
  /// the full `Format: …`.
  final bool compact;

  @override
  State<MediaOptionsControl> createState() => _MediaOptionsControlState();
}

class _MediaOptionsControlState extends State<MediaOptionsControl> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();

  String _summary(BistreLocalizationController l10n) {
    final v = widget.value.forModel(widget.info);
    final parts = <String>[
      ?v.aspectRatio,
      ?v.resolution,
      if (v.durationS case final d?)
        l10n.t(L10nKey.chatMediaSeconds, <String, Object?>{'seconds': '$d'}),
    ];
    return parts.isEmpty ? l10n.t(L10nKey.chatMediaDefault) : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final summary = _summary(l10n);
    final full = l10n.t(L10nKey.chatMediaChip, <String, Object?>{
      'value': summary,
    });
    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        child: HoverHint(
          message: l10n.t(L10nKey.chatMediaHint),
          child: EngravedButton(
            label: widget.compact ? summary : full,
            semanticsLabel: widget.compact ? full : null,
            compact: true,
            leading: BistreIcon(
              BistreUiIcon.sliders,
              size: 13,
              color: theme.inkSecondary,
            ),
            onPressed: _popover.toggle,
          ),
        ),
      ),
    );
  }

  Widget _group<T>(
    BistreLocalizationController l10n,
    L10nKey title,
    List<T> choices,
    T? chosen,
    String Function(T) label,
    MediaOptions Function(T?) pick, {
    Widget? Function(T)? leading,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      InkText(l10n.t(title), role: InkTextRole.labelStrong),
      const SizedBox(height: BistreSpacing.s4),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          InkChip(
            label: l10n.t(L10nKey.chatMediaDefault),
            selected: chosen == null,
            onSelected: () => widget.onChanged(pick(null)),
          ),
          for (final c in choices)
            InkChip(
              label: label(c),
              leading: leading?.call(c),
              selected: c == chosen,
              onSelected: () => widget.onChanged(pick(c)),
            ),
        ],
      ),
      const SizedBox(height: BistreSpacing.s12),
    ],
  );

  Widget _buildPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final width = PopoverPlacement.popoverWidthFor(context, 340);
    final shift = PopoverPlacement.popoverShiftFor(
      this.context,
      width: width,
      alignStart: true,
    );
    final info = widget.info;
    final v = widget.value.forModel(info);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _popover.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.topStart.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          offset: Offset(shift, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            reduceMotionOverride: widget.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: width,
                maxWidth: width,
                // Long choice lists scroll inside the popover instead of leaving the window.
                maxHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 12),
                borderRadius: 12,
                boxShadow: theme.floatingShadow,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (info.aspectRatios.isNotEmpty)
                        _group<String>(
                          l10n,
                          L10nKey.chatMediaShape,
                          info.aspectRatios,
                          v.aspectRatio,
                          (c) => c,
                          (c) => MediaOptions(
                            aspectRatio: c,
                            resolution: widget.value.resolution,
                            durationS: widget.value.durationS,
                          ),
                          leading: (c) => switch (aspectOf(c)) {
                            final r? => _ShapeGlyph(aspect: r),
                            null => null,
                          },
                        ),
                      if (info.resolutions.isNotEmpty)
                        _group<String>(
                          l10n,
                          L10nKey.chatMediaSize,
                          info.resolutions,
                          v.resolution,
                          (c) => c,
                          (c) => MediaOptions(
                            aspectRatio: widget.value.aspectRatio,
                            resolution: c,
                            durationS: widget.value.durationS,
                          ),
                        ),
                      if (info.durationsS.isNotEmpty)
                        _group<int>(
                          l10n,
                          L10nKey.chatMediaLength,
                          info.durationsS,
                          v.durationS,
                          (c) => l10n.t(
                            L10nKey.chatMediaSeconds,
                            <String, Object?>{'seconds': '$c'},
                          ),
                          (c) => MediaOptions(
                            aspectRatio: widget.value.aspectRatio,
                            resolution: widget.value.resolution,
                            durationS: c,
                          ),
                        ),
                      InkText(
                        l10n.t(L10nKey.chatMediaHint),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A frame drawn at the shape's true proportions inside a 16 px square, so `9:16` reads as
/// tall and `21:9` as wide before the numbers are read.
class _ShapeGlyph extends StatelessWidget {
  const _ShapeGlyph({required this.aspect});

  /// Width over height.
  final double aspect;

  static const double _box = 16;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final w = aspect >= 1 ? _box : (_box * aspect).clamp(3.0, _box);
    final h = aspect >= 1 ? (_box / aspect).clamp(3.0, _box) : _box;
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: _box,
        child: Center(
          child: SizedBox(
            width: w,
            height: h,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: theme.inkSecondary, width: 1.2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
