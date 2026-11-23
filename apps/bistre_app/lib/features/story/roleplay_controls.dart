import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

const String _kMinPLabel = 'min_p';
const String _kTopKLabel = 'top_k';
const String _kRepPenLabel = 'rep_pen';
const String _kDryLabel = 'DRY';
const String _kXtcLabel = 'XTC';
const String _kBannedLabel = 'banned_phrases (comma-separated)';

/// Clean, compact Roleplay & Writing Studio toolbar shown ONLY when `activeThreadMode == 'write'`:
/// - `[Chat | Manuscript]` segmented view toggle
/// - Turn-0 Alternate Greeting `< Opening 1 / N >` switcher when character has greetings
/// - `Continue` and `Draft my reply` (`Impersonate`) quick actions
/// - Group Scene character pills + `Highlight dialogue & actions` toggle
/// - Collapsible `Creative samplers & phrase bans` drawer (`min_p`, `top_k`, `DRY`, `XTC`, banned phrases).
class RoleplayControlsBar extends StatefulWidget {
  const RoleplayControlsBar({super.key, required this.controller});

  final FolioController controller;

  @override
  State<RoleplayControlsBar> createState() => _RoleplayControlsBarState();
}

class _RoleplayControlsBarState extends State<RoleplayControlsBar> {
  bool _samplersExpanded = false;
  final TextEditingController _minPCtrl = TextEditingController();
  final FocusNode _minPFocus = FocusNode();
  final TextEditingController _topKCtrl = TextEditingController();
  final FocusNode _topKFocus = FocusNode();
  final TextEditingController _repCtrl = TextEditingController();
  final FocusNode _repFocus = FocusNode();
  final TextEditingController _dryCtrl = TextEditingController();
  final FocusNode _dryFocus = FocusNode();
  final TextEditingController _xtcCtrl = TextEditingController();
  final FocusNode _xtcFocus = FocusNode();
  final TextEditingController _bannedCtrl = TextEditingController();
  final FocusNode _bannedFocus = FocusNode();
  String _syncedThreadId = '';

  @override
  void dispose() {
    _minPCtrl.dispose();
    _minPFocus.dispose();
    _topKCtrl.dispose();
    _topKFocus.dispose();
    _repCtrl.dispose();
    _repFocus.dispose();
    _dryCtrl.dispose();
    _dryFocus.dispose();
    _xtcCtrl.dispose();
    _xtcFocus.dispose();
    _bannedCtrl.dispose();
    _bannedFocus.dispose();
    super.dispose();
  }

  void _syncSamplers(FolioController ctrl) {
    final tid = ctrl.activeThread?.id ?? '';
    if (tid == _syncedThreadId) return;
    _syncedThreadId = tid;
    final s = ctrl.storyState.samplers;
    _minPCtrl.text = s.minPMilli != null
        ? (s.minPMilli! / 1000).toString()
        : '';
    _topKCtrl.text = s.topK?.toString() ?? '';
    _repCtrl.text = s.repetitionPenaltyMilli != null
        ? (s.repetitionPenaltyMilli! / 1000).toString()
        : '';
    _dryCtrl.text = s.dryMultiplierMilli != null
        ? (s.dryMultiplierMilli! / 1000).toString()
        : '';
    _xtcCtrl.text = s.xtcProbabilityMilli != null
        ? (s.xtcProbabilityMilli! / 1000).toString()
        : '';
    _bannedCtrl.text = s.bannedPhrases.join(', ');
  }

  int? _parseMilli(String raw) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null) return null;
    return (parsed * 1000).round().clamp(0, 10000);
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    _syncSamplers(ctrl);

    final state = ctrl.storyState;
    final primaryChar = ctrl.activeThreadCharacters.firstOrNull;
    final greetings = primaryChar?.allGreetings ?? const <String>[];
    final showAltGreetings =
        !ctrl.manuscriptViewActive &&
        ctrl.visibleBranchNodes.isEmpty &&
        greetings.isNotEmpty;

    return ColoredBox(
      color: theme.bgSurface.withValues(alpha: 0.72),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: BistreSpacing.s16,
              vertical: 6,
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Chat vs Manuscript view toggle
                InkChip(
                  label: l10n.t(L10nKey.storyViewChat),
                  selected: !ctrl.manuscriptViewActive,
                  onSelected: () => ctrl.toggleManuscriptView(false),
                ),
                InkChip(
                  label: l10n.t(L10nKey.storyViewManuscript),
                  selected: ctrl.manuscriptViewActive,
                  onSelected: () => ctrl.toggleManuscriptView(true),
                ),
                if (!ctrl.manuscriptViewActive) ...[
                  EngravedButton(
                    label: l10n.t(L10nKey.storyActionContinue),
                    compact: true,
                    onPressed: ctrl.isStreaming
                        ? null
                        : () => unawaited(
                            ctrl.triggerStoryContinue(
                              request: l10n.t(L10nKey.storyRequestContinue),
                            ),
                          ),
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.storyActionImpersonate),
                    compact: true,
                    onPressed: ctrl.isStreaming
                        ? null
                        : () => unawaited(
                            ctrl.triggerStoryImpersonate(
                              request: l10n.t(
                                L10nKey.storyRequestImpersonate,
                                <String, Object?>{
                                  'name':
                                      ctrl.activePersonaName ??
                                      l10n.t(L10nKey.storyDefaultPersonaName),
                                },
                              ),
                            ),
                          ),
                  ),
                ],
                // Active cast badges (group scene support)
                for (final c in ctrl.activeThreadCharacters)
                  WaxSealBadge(label: c.name),
                InkChip(
                  label: l10n.t(L10nKey.storyDialogueStyling),
                  selected: state.dialogueStyling,
                  onSelected: () => unawaited(
                    ctrl.saveStoryThreadState(
                      state.copyWith(dialogueStyling: !state.dialogueStyling),
                    ),
                  ),
                ),
                InkChip(
                  label: l10n.t(L10nKey.storySamplersTitle),
                  selected: _samplersExpanded,
                  onSelected: () =>
                      setState(() => _samplersExpanded = !_samplersExpanded),
                ),
                InkChip(
                  label: l10n.t(L10nKey.studioTabStory),
                  selected:
                      ctrl.studioPaneOpen && ctrl.studioTab == StudioTab.story,
                  onSelected: () => ctrl.setStudioTab(StudioTab.story),
                ),
                InkChip(
                  label: l10n.t(L10nKey.studioTabPrompt),
                  selected:
                      ctrl.studioPaneOpen && ctrl.studioTab == StudioTab.prompt,
                  onSelected: () => ctrl.setStudioTab(StudioTab.prompt),
                ),
              ],
            ),
          ),
          if (showAltGreetings)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 8),
              child: FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                padding: const EdgeInsetsDirectional.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        BistreIconButton(
                          icon: BistreUiIcon.chevronStart,
                          size: 13,
                          dimension: 24,
                          semanticsLabel: l10n.t(L10nKey.chatBranchPrev),
                          onPressed: greetings.length > 1
                              ? () => ctrl.cycleAltGreeting(-1)
                              : null,
                        ),
                        const SizedBox(width: 6),
                        InkText(
                          l10n.t(L10nKey.storyAltGreeting, <String, Object?>{
                            'current':
                                (ctrl.activeGreetingIndex % greetings.length) +
                                1,
                            'total': greetings.length,
                          }),
                          role: InkTextRole.labelStrong,
                          color: theme.accentBrass,
                        ),
                        const SizedBox(width: 6),
                        BistreIconButton(
                          icon: BistreUiIcon.chevronEnd,
                          size: 13,
                          dimension: 24,
                          semanticsLabel: l10n.t(L10nKey.chatBranchNext),
                          onPressed: greetings.length > 1
                              ? () => ctrl.cycleAltGreeting(1)
                              : null,
                        ),
                        const Spacer(),
                        EngravedButton(
                          label: l10n.t(L10nKey.storyActionContinue),
                          primary: true,
                          compact: true,
                          onPressed: () =>
                              unawaited(ctrl.applyActiveGreetingToThread()),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    InkText(
                      greetings[ctrl.activeGreetingIndex % greetings.length],
                      role: InkTextRole.bodyCompact,
                      color: theme.inkSecondary,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          if (_samplersExpanded)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 10),
              child: FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 10,
                padding: const EdgeInsetsDirectional.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _SamplerField(
                          label: _kMinPLabel,
                          controller: _minPCtrl,
                          focusNode: _minPFocus,
                        ),
                        _SamplerField(
                          label: _kTopKLabel,
                          controller: _topKCtrl,
                          focusNode: _topKFocus,
                        ),
                        _SamplerField(
                          label: _kRepPenLabel,
                          controller: _repCtrl,
                          focusNode: _repFocus,
                        ),
                        _SamplerField(
                          label: _kDryLabel,
                          controller: _dryCtrl,
                          focusNode: _dryFocus,
                        ),
                        _SamplerField(
                          label: _kXtcLabel,
                          controller: _xtcCtrl,
                          focusNode: _xtcFocus,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: QuillInput(
                            controller: _bannedCtrl,
                            focusNode: _bannedFocus,
                            placeholder: _kBannedLabel,
                            maxLines: 1,
                            submitOnEnter: false,
                            onSubmitted: () {},
                          ),
                        ),
                        const SizedBox(width: 8),
                        EngravedButton(
                          label: l10n.t(L10nKey.threadSave),
                          primary: true,
                          compact: true,
                          onPressed: () {
                            final banned = _bannedCtrl.text
                                .split(',')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList(growable: false);
                            unawaited(
                              ctrl.saveStoryThreadState(
                                state.copyWith(
                                  samplers: EngineCreativeSamplers(
                                    minPMilli: _parseMilli(_minPCtrl.text),
                                    topK: int.tryParse(_topKCtrl.text.trim()),
                                    repetitionPenaltyMilli: _parseMilli(
                                      _repCtrl.text,
                                    ),
                                    dryMultiplierMilli: _parseMilli(
                                      _dryCtrl.text,
                                    ),
                                    xtcProbabilityMilli: _parseMilli(
                                      _xtcCtrl.text,
                                    ),
                                    bannedPhrases: banned,
                                  ),
                                ),
                              ),
                            );
                            setState(() => _samplersExpanded = false);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const FolioDivider(),
        ],
      ),
    );
  }
}

class _SamplerField extends StatelessWidget {
  const _SamplerField({
    required this.label,
    required this.controller,
    required this.focusNode,
  });

  final String label;
  final TextEditingController controller;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return SizedBox(
      width: 96,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkText(label, role: InkTextRole.captionMeta, color: theme.inkMuted),
          const SizedBox(height: 2),
          QuillInput(
            controller: controller,
            focusNode: focusNode,
            placeholder: label,
            maxLines: 1,
            submitOnEnter: false,
            onSubmitted: () {},
          ),
        ],
      ),
    );
  }
}
