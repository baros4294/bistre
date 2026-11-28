import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/label_control_layout.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// The compact inline notice above the composer: a status dot, one plain sentence, the one
/// fix it needs, and dismiss; announced to screen readers. It shows the last error, or else a
/// reply a restart cut off, which stays on its chat until it is tried again or closed. The fix
/// sits beside the sentence and drops below it when both do not fit (phone, large text).
class ComposerNotice extends StatelessWidget {
  const ComposerNotice({super.key, required this.controller});

  final FolioController controller;

  /// Whether there is anything to show.
  static bool shows(FolioController ctrl) =>
      ctrl.lastDiagnosticKey != null || ctrl.interruptedRun != null;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = controller;
    final interrupted = ctrl.lastDiagnosticKey == null
        ? ctrl.interruptedRun
        : null;
    final diag = ctrl.lastDiagnosticKey ?? interrupted?.errorKey;
    if (diag == null) return const SizedBox.shrink();
    final needsContinue = diag == 'diag.provider.reply_truncated';
    final providerReason = ctrl.lastDiagnosticReason;
    final fix = _fixFor(diag, interrupted != null, ctrl, l10n);

    return FolioFadeSlide(
      beginOffset: const Offset(0, 0.12),
      reduceMotionOverride: ctrl.reduceMotionOverride,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.bgElevated,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: theme.borderHairline),
          boxShadow: theme.cardShadow,
        ),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            BistreSpacing.s12,
            8,
            8,
            8,
          ),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // A cut-off reply is a notice, not a failure.
                    color: needsContinue || interrupted != null
                        ? theme.statusWarn
                        : theme.statusErr,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: BistreSpacing.s8),
              Expanded(
                child: LabelControlLayout(
                  gap: BistreSpacing.s8,
                  label: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkText(
                          l10n.tRawKey(diag),
                          role: InkTextRole.bodyCompact,
                        ),
                        // The provider's own reason, as it said it.
                        if (providerReason != null)
                          InkText(
                            l10n.t(
                              L10nKey.chatDiagProviderReason,
                              <String, Object?>{'reason': providerReason},
                            ),
                            role: InkTextRole.captionMeta,
                            color: theme.inkSecondary,
                          ),
                      ],
                    ),
                  ),
                  control: fix ?? const SizedBox.shrink(),
                ),
              ),
              const SizedBox(width: 4),
              BistreIconButton(
                icon: BistreUiIcon.close,
                size: 13,
                dimension: 26,
                semanticsLabel: l10n.t(L10nKey.shellDismiss),
                onPressed: interrupted != null
                    ? ctrl.dismissInterruptedRun
                    : ctrl.clearDiagnostic,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fixable notices jump straight to the fix.
  static Widget? _fixFor(
    String diag,
    bool interrupted,
    FolioController ctrl,
    BistreLocalizationController l10n,
  ) {
    EngravedButton button(L10nKey label, VoidCallback onPressed) =>
        EngravedButton(
          label: l10n.t(label),
          compact: true,
          onPressed: onPressed,
        );
    if (interrupted) {
      return button(
        L10nKey.chatActionRegenerate,
        () => unawaited(ctrl.retryInterruptedRun()),
      );
    }
    return switch (diag) {
      'diag.provider.not_configured' ||
      'diag.provider.pinned_unavailable' ||
      'diag.provider.model_required' ||
      'diag.provider.auth_failed' ||
      'diag.provider.quota_exhausted' => button(
        L10nKey.settingsTabProviders,
        ctrl.openSettings,
      ),
      'diag.provider.context_overflow' => button(L10nKey.chatFixShorten, () {
        ctrl.clearDiagnostic();
        unawaited(ctrl.compactActiveThread());
      }),
      'diag.hooks.approval_required' => button(
        L10nKey.chatFixReviewHooks,
        () => ctrl.openSettings(SettingsTab.agent),
      ),
      'diag.provider.reply_truncated' => button(L10nKey.chatFixContinue, () {
        ctrl.clearDiagnostic();
        unawaited(ctrl.submitPassage(l10n.t(L10nKey.chatFixContinueMessage)));
      }),
      'diag.wallet.price_unknown' => button(
        L10nKey.chatFixAllowUnpricedOnce,
        () => unawaited(ctrl.allowUnpricedOnceAndRetry()),
      ),
      'diag.wallet.ceiling_exceeded' => button(
        L10nKey.chatFixSpendingLimit,
        () => ctrl.openSettings(SettingsTab.trust),
      ),
      _ => null,
    };
  }
}
