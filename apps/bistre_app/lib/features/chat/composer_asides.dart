import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'markdown_folio_view.dart';

/// Tallest side answer above the composer before it scrolls, at 100% text.
const double kSideAnswerMaxHeight = 280;

/// What sits above the composer beside the chat: the chat's goal (`/goal`), and the side
/// question (`/btw`) with its answer. Neither is a message of the chat.
class ComposerAsides extends StatelessWidget {
  const ComposerAsides({super.key, required this.controller});

  final FolioController controller;

  /// Whether there is anything to show.
  static bool shows(FolioController ctrl) =>
      ctrl.threadGoal != null || ctrl.sideQuestion.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final ctrl = controller;
    final goal = ctrl.threadGoal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (goal != null)
          _GoalStrip(
            objective: goal.objective,
            completed: goal.completed,
            summary: goal.summary,
            onClear: () => unawaited(ctrl.setThreadGoal('')),
          ),
        if (goal != null && ctrl.sideQuestion.isNotEmpty)
          const SizedBox(height: BistreSpacing.s8),
        if (ctrl.sideQuestion.isNotEmpty) _SideAnswerCard(controller: ctrl),
      ],
    );
  }
}

class _GoalStrip extends StatelessWidget {
  const _GoalStrip({
    required this.objective,
    required this.completed,
    required this.summary,
    required this.onClear,
  });

  final String objective;
  final bool completed;
  final String summary;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return FolioSurface(
      borderRadius: 11,
      padding: const EdgeInsetsDirectional.fromSTEB(BistreSpacing.s12, 6, 6, 6),
      child: Row(
        children: [
          BistreIcon(
            completed ? BistreUiIcon.check : BistreUiIcon.think,
            size: 13,
            color: completed ? theme.statusOk : theme.accentBrass,
          ),
          const SizedBox(width: BistreSpacing.s8),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkText(
                    l10n.t(
                      completed
                          ? L10nKey.composerGoalDone
                          : L10nKey.composerGoalOpen,
                      <String, Object?>{'goal': objective},
                    ),
                    role: InkTextRole.bodyCompact,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (completed && summary.isNotEmpty)
                    InkText(
                      summary,
                      role: InkTextRole.captionMeta,
                      color: theme.inkSecondary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ),
          BistreIconButton(
            icon: BistreUiIcon.close,
            size: 13,
            dimension: 28,
            semanticsLabel: l10n.t(L10nKey.composerGoalClear),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class _SideAnswerCard extends StatelessWidget {
  const _SideAnswerCard({required this.controller});

  final FolioController controller;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = controller;
    final answer = ctrl.sideAnswer;
    final maxHeight = MediaQuery.textScalerOf(context)
        .scale(kSideAnswerMaxHeight);
    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 11,
      boxShadow: theme.cardShadow,
      padding: const EdgeInsetsDirectional.fromSTEB(
        BistreSpacing.s12,
        8,
        6,
        10,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              BistreIcon(BistreUiIcon.chat, size: 13, color: theme.accentBrass),
              const SizedBox(width: BistreSpacing.s8),
              Expanded(
                child: InkText(
                  l10n.t(L10nKey.composerSideTitle),
                  role: InkTextRole.labelStrong,
                ),
              ),
              if (answer != null)
                BistreIconButton(
                  icon: BistreUiIcon.copy,
                  size: 13,
                  dimension: 28,
                  semanticsLabel: l10n.t(L10nKey.chatActionCopy),
                  onPressed: () => unawaited(ctrl.copyText(answer)),
                ),
              BistreIconButton(
                icon: BistreUiIcon.close,
                size: 13,
                dimension: 28,
                semanticsLabel: l10n.t(L10nKey.shellDismiss),
                onPressed: ctrl.dismissSideQuestion,
              ),
            ],
          ),
          InkText(
            ctrl.sideQuestion,
            role: InkTextRole.captionMeta,
            color: theme.inkSecondary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: BistreSpacing.s8),
          Semantics(
            liveRegion: true,
            child: answer == null
                ? InkText(
                    l10n.t(L10nKey.composerSideAnswering),
                    role: InkTextRole.bodyCompact,
                    color: theme.inkMuted,
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: SmoothScrollable(
                      builder: (_, scroll) => SingleChildScrollView(
                        controller: scroll,
                        child: MarkdownFolioView(
                          markdown: answer,
                          onCopyCode: (code) => unawaited(ctrl.copyText(code)),
                          renderMath: ctrl.uiPrefs.renderMathFormulas,
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
