import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Quiet info button shown in place of a price when a reply's model has no published rate
/// (`cost_known: false`). It opens a small breakdown popover instead of printing noisy
/// "cost unavailable" text on every reply (`docs/design/DESIGN.md` §8, Spec 08 §3).
class CostUnavailableButton extends StatefulWidget {
  const CostUnavailableButton({super.key, required this.usage});

  final NodeUsageMeta usage;

  @override
  State<CostUnavailableButton> createState() => _CostUnavailableButtonState();
}

class _CostUnavailableButtonState extends State<CostUnavailableButton> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return FolioOverlay(
      controller: _popover,
      overlayBuilder: (ctx) => _buildPopover(ctx, theme, l10n),
      child: CompositedTransformTarget(
        link: _link,
        child: BistreIconButton(
          icon: BistreUiIcon.info,
          size: 12,
          dimension: 22,
          color: theme.inkMuted,
          semanticsLabel: l10n.t(L10nKey.chatCostUnavailableTitle),
          onPressed: _popover.toggle,
        ),
      ),
    );
  }

  Widget _buildPopover(
    BuildContext context,
    BistreThemeData theme,
    BistreLocalizationController l10n,
  ) {
    final dir = Directionality.of(context);
    final usage = widget.usage;
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
          offset: const Offset(0, -6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 280),
            child: FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 10,
              boxShadow: theme.floatingShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkText(
                    l10n.t(L10nKey.chatCostUnavailableTitle),
                    role: InkTextRole.labelStrong,
                  ),
                  const SizedBox(height: 4),
                  InkText(
                    l10n.t(L10nKey.chatCostUnavailableBody),
                    role: InkTextRole.bodyCompact,
                    color: theme.inkSecondary,
                  ),
                  if (usage.modelId.isNotEmpty || usage.hasTokens) ...[
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.joinMeta(<String>[
                        if (usage.modelId.isNotEmpty) usage.modelId,
                        if (usage.hasTokens)
                          l10n.t(L10nKey.chatTokensMeta, <String, Object?>{
                            'input': usage.inputTokens,
                            'output': usage.outputTokens,
                          }),
                      ]),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
