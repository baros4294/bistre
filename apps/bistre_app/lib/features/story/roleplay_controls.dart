import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Write-mode toolbar, shown only when `activeThreadMode == 'write'`. One kind of
/// control per place:
/// - a `[Chat | Manuscript]` switch;
/// - `Continue` and `Draft my reply` as buttons (chat view);
/// - who is in the scene, as plain text;
/// - one options button opening the dialogue highlight switch and the sampler fields.
/// The Story Bible and Prompt live in Studio's tabs only. A first-turn `< Opening 1 / N >`
/// switcher shows when the character has alternate greetings.
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
                BistreSegmentedControl<bool>(
                  options: <BistreSegmentedOption<bool>>[
                    BistreSegmentedOption<bool>(
                      value: false,
                      label: l10n.t(L10nKey.storyViewChat),
                    ),
                    BistreSegmentedOption<bool>(
                      value: true,
                      label: l10n.t(L10nKey.storyViewManuscript),
                    ),
                  ],
                  selected: ctrl.manuscriptViewActive,
                  onSelected: ctrl.toggleManuscriptView,
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
                        : () => unawaited(ctrl.draftReplyIntoComposer()),
                  ),
                ],
                BistreIconButton(
                  icon: BistreUiIcon.sliders,
                  size: 14,
                  dimension: 32,
                  active: _samplersExpanded,
                  semanticsLabel: l10n.t(L10nKey.storySamplersTitle),
                  onPressed: () =>
                      setState(() => _samplersExpanded = !_samplersExpanded),
                ),
                if (ctrl.activeThreadCharacters.isNotEmpty)
                  InkText(
                    l10n.t(L10nKey.storyCastLine, <String, Object?>{
                      'names': ctrl.activeThreadCharacters
                          .map((c) => l10n.isolate(c.name))
                          .join(l10n.t(L10nKey.storyCastSeparator)),
                    }),
                    role: InkTextRole.captionMeta,
                    color: theme.inkMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                    BistreSettingRow(
                      label: l10n.t(L10nKey.storyDialogueStyling),
                      trailing: BistreSwitch(
                        value: state.dialogueStyling,
                        semanticsLabel: l10n.t(L10nKey.storyDialogueStyling),
                        reduceMotionOverride: ctrl.reduceMotionOverride,
                        onChanged: (on) => unawaited(
                          ctrl.saveStoryThreadState(
                            state.copyWith(dialogueStyling: on),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _SamplerField(
                          label: l10n.t(L10nKey.storySamplerMinP),
                          controller: _minPCtrl,
                          focusNode: _minPFocus,
                        ),
                        _SamplerField(
                          label: l10n.t(L10nKey.storySamplerTopK),
                          controller: _topKCtrl,
                          focusNode: _topKFocus,
                        ),
                        _SamplerField(
                          label: l10n.t(L10nKey.storySamplerRepetition),
                          controller: _repCtrl,
                          focusNode: _repFocus,
                        ),
                        _SamplerField(
                          label: l10n.t(L10nKey.storySamplerDry),
                          controller: _dryCtrl,
                          focusNode: _dryFocus,
                        ),
                        _SamplerField(
                          label: l10n.t(L10nKey.storySamplerXtc),
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
                            placeholder: l10n.t(L10nKey.storySamplerBanned),
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
    final l10n = BistreLocalizations.of(context);
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkText(label, role: InkTextRole.captionMeta, color: theme.inkMuted),
          const SizedBox(height: 2),
          QuillInput(
            controller: controller,
            focusNode: focusNode,
            placeholder: l10n.t(L10nKey.settingsAssistantsParamsDefault),
            maxLines: 1,
            submitOnEnter: false,
            onSubmitted: () {},
          ),
        ],
      ),
    );
  }
}
