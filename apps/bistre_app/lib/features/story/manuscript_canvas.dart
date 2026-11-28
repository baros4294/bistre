import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/press_feedback.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

String _chapterNumberLabel(int index, String title) => '$index. $title';
int _wordCount(String text) =>
    text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

/// The rewrite tools on the selected text (or the whole scene) and the mode core runs.
const List<(L10nKey, String)> _kRewriteTools = <(L10nKey, String)>[
  (L10nKey.storyLaserRewrite, 'rewrite'),
  (L10nKey.storyLaserExpand, 'expand'),
  (L10nKey.storyLaserShorten, 'shorten'),
  (L10nKey.storyLaserPolish, 'polish'),
];

/// The writing tool running in this canvas; one at a time.
enum _Tool { rewrite, plan, summary }

/// Long-form manuscript canvas inside Write mode:
/// - the chapter and scene tree (New chapter, New scene);
/// - the chapter summary later chapters are checked against, with Write summary;
/// - the scene's beats with Plan scene and Write prose from beats;
/// - the prose editor with its word count and the rewrite tools (Rewrite, Expand, Shorten,
///   Polish), which replace the selected text (or the whole scene) in place, unsaved.
class ManuscriptCanvas extends StatefulWidget {
  const ManuscriptCanvas({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ManuscriptCanvas> createState() => _ManuscriptCanvasState();
}

class _ManuscriptCanvasState extends State<ManuscriptCanvas> {
  final TextEditingController _newChapterCtrl = TextEditingController();
  final FocusNode _newChapterFocus = FocusNode();
  final TextEditingController _newSceneCtrl = TextEditingController();
  final FocusNode _newSceneFocus = FocusNode();
  final TextEditingController _summaryCtrl = TextEditingController();
  final FocusNode _summaryFocus = FocusNode();
  final TextEditingController _beatsCtrl = TextEditingController();
  final FocusNode _beatsFocus = FocusNode();
  final TextEditingController _proseCtrl = TextEditingController();
  final FocusNode _proseFocus = FocusNode();

  bool _addingChapter = false;
  bool _addingScene = false;
  String _syncedSceneId = '';
  String _syncedChapterId = '';
  _Tool? _running;

  /// What the last Write summary found that earlier chapters contradict.
  List<String> _contradictions = const <String>[];

  @override
  void dispose() {
    _newChapterCtrl.dispose();
    _newChapterFocus.dispose();
    _newSceneCtrl.dispose();
    _newSceneFocus.dispose();
    _summaryCtrl.dispose();
    _summaryFocus.dispose();
    _beatsCtrl.dispose();
    _beatsFocus.dispose();
    _proseCtrl.dispose();
    _proseFocus.dispose();
    super.dispose();
  }

  void _syncActive(EngineStoryChapter? chapter, EngineStoryScene? scene) {
    final chapterId = chapter?.id ?? '';
    if (chapterId != _syncedChapterId) {
      _syncedChapterId = chapterId;
      _summaryCtrl.text = chapter?.eraSummary ?? '';
      _contradictions = const <String>[];
    }
    final id = scene?.id ?? '';
    if (id == _syncedSceneId) return;
    _syncedSceneId = id;
    _beatsCtrl.text = scene?.beatsText ?? '';
    _proseCtrl.text = scene?.proseText ?? '';
  }

  /// Runs one writing tool; the others wait until it is done.
  Future<T?> _run<T>(_Tool tool, Future<T?> Function() call) async {
    setState(() => _running = tool);
    final out = await call();
    if (mounted) setState(() => _running = null);
    return out;
  }

  /// Replaces the selected prose (or all of it) with the rewrite of [mode]. The prose is
  /// left as it is when it changed while the rewrite ran.
  Future<void> _rewrite(FolioController ctrl, String mode) async {
    final text = _proseCtrl.text;
    final sel = _proseCtrl.selection;
    final onSelection =
        sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= text.length;
    final start = onSelection ? sel.start : 0;
    final end = onSelection ? sel.end : text.length;
    final excerpt = text.substring(start, end);
    if (excerpt.trim().isEmpty) return;
    final sceneId = _syncedSceneId;
    final out = await _run(
      _Tool.rewrite,
      () => ctrl.rewritePassage(
        mode: mode,
        excerpt: excerpt,
        context: onSelection ? text : '',
      ),
    );
    if (out == null || out.isEmpty || !mounted || sceneId != _syncedSceneId) {
      return;
    }
    final now = _proseCtrl.value;
    if (now.composing.isValid ||
        end > now.text.length ||
        now.text.substring(start, end) != excerpt) {
      ctrl.showToast(L10nKey.storyRewriteStale);
      return;
    }
    final next = now.text.replaceRange(start, end, out);
    setState(() {
      _proseCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + out.length,
        ),
      );
    });
  }

  /// Adds a writing brief for the scene after its beats.
  Future<void> _planScene(FolioController ctrl, EngineStoryScene scene) async {
    final sceneId = scene.id;
    final brief = await _run(
      _Tool.plan,
      () => ctrl.planScene(title: scene.title, beats: _beatsCtrl.text),
    );
    if (brief == null || brief.isEmpty || !mounted) return;
    if (sceneId != _syncedSceneId || _beatsCtrl.value.composing.isValid) {
      ctrl.showToast(L10nKey.storyRewriteStale);
      return;
    }
    final beats = _beatsCtrl.text.trimRight();
    setState(() {
      _beatsCtrl.text = beats.isEmpty ? brief : '$beats\n\n$brief';
    });
  }

  /// Fills the chapter summary from its saved scenes and lists what earlier chapters
  /// contradict.
  Future<void> _writeSummary(
    FolioController ctrl,
    EngineStoryChapter chapter,
  ) async {
    final summary = await _run(
      _Tool.summary,
      () => ctrl.summarizeChapter(chapter.id),
    );
    if (summary == null || !mounted || chapter.id != _syncedChapterId) return;
    if (_summaryCtrl.value.composing.isValid) {
      ctrl.showToast(L10nKey.storyRewriteStale);
      return;
    }
    setState(() {
      _summaryCtrl.text = summary.eraSummary;
      _contradictions = summary.contradictions;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final activeChapter = ctrl.activeChapter;
    final activeScene = ctrl.activeScene;
    _syncActive(activeChapter, activeScene);

    return LayoutBuilder(
      builder: (context, constraints) {
        final showSidebar = constraints.maxWidth >= 620;
        final chapterList = _buildOutlineColumn(
          theme,
          l10n,
          ctrl,
          activeChapter,
          activeScene,
        );
        final editorPane = _buildEditorPane(
          theme,
          l10n,
          ctrl,
          activeChapter,
          activeScene,
        );

        if (!showSidebar) {
          return SmoothScrollable(
            builder: (_, scroll) => SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsetsDirectional.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  chapterList,
                  const SizedBox(height: 16),
                  const FolioDivider(),
                  const SizedBox(height: 16),
                  editorPane,
                ],
              ),
            ),
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 224,
              child: ColoredBox(
                color: theme.bgSurface.withValues(alpha: 0.5),
                child: SmoothScrollable(
                  builder: (_, scroll) => SingleChildScrollView(
                    controller: scroll,
                    padding: const EdgeInsetsDirectional.all(12),
                    child: chapterList,
                  ),
                ),
              ),
            ),
            const FolioDivider(vertical: true),
            Expanded(
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  padding: const EdgeInsetsDirectional.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: theme.typography.readingWidthPx,
                      ),
                      child: editorPane,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildOutlineColumn(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineStoryChapter? activeChapter,
    EngineStoryScene? activeScene,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            BistreIcon(
              BistreUiIcon.bookOpen,
              size: 14,
              color: theme.accentBrass,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: InkText(
                l10n.t(L10nKey.storyViewManuscript),
                role: InkTextRole.labelStrong,
                color: theme.inkPrimary,
              ),
            ),
            BistreIconButton(
              icon: BistreUiIcon.plus,
              size: 13,
              dimension: 26,
              semanticsLabel: l10n.t(L10nKey.storyAddChapter),
              onPressed: () => setState(() => _addingChapter = !_addingChapter),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_addingChapter) ...[
          QuillInput(
            controller: _newChapterCtrl,
            focusNode: _newChapterFocus,
            placeholder: l10n.t(L10nKey.storyAddChapter),
            maxLines: 1,
            submitOnEnter: false,
            onSubmitted: () {
              unawaited(ctrl.addStoryChapter(_newChapterCtrl.text));
              _newChapterCtrl.clear();
              setState(() => _addingChapter = false);
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              EngravedButton(
                label: l10n.t(L10nKey.threadSave),
                primary: true,
                compact: true,
                onPressed: () {
                  unawaited(ctrl.addStoryChapter(_newChapterCtrl.text));
                  _newChapterCtrl.clear();
                  setState(() => _addingChapter = false);
                },
              ),
              const SizedBox(width: 6),
              EngravedButton(
                label: l10n.t(L10nKey.threadCancel),
                compact: true,
                onPressed: () => setState(() => _addingChapter = false),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        if (ctrl.storyChapters.isEmpty)
          EngravedButton(
            label: l10n.t(L10nKey.storyAddChapter),
            compact: true,
            onPressed: () => setState(() => _addingChapter = true),
          )
        else
          for (final ch in ctrl.storyChapters) ...[
            PressFeedback(
              pressScale: kRowPressScale,
              hoverScale: 1,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => ctrl.selectChapter(ch.id),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: activeChapter?.id == ch.id
                        ? theme.bgElevated
                        : theme.bgSurface.withValues(alpha: 0.0),
                    borderRadius: BorderRadius.circular(8),
                    border: activeChapter?.id == ch.id
                        ? Border.all(color: theme.borderHairline)
                        : null,
                  ),
                  child: Padding(
                    padding: const EdgeInsetsDirectional.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    child: InkText(
                      _chapterNumberLabel(ch.orderIndex, ch.title),
                      role: InkTextRole.labelStrong,
                      color: activeChapter?.id == ch.id
                          ? theme.inkPrimary
                          : theme.inkSecondary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
            if (activeChapter?.id == ch.id) ...[
              for (final sc in ctrl.scenesForChapter(ch.id))
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 14,
                    top: 3,
                    bottom: 2,
                  ),
                  child: PressFeedback(
                    pressScale: kRowPressScale,
                    hoverScale: 1,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => ctrl.selectScene(sc.id),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: activeScene?.id == sc.id
                              ? theme.accentBrass.withValues(alpha: 0.14)
                              : theme.bgSurface.withValues(alpha: 0.0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsetsDirectional.symmetric(
                            horizontal: 8,
                            vertical: 5,
                          ),
                          child: InkText(
                            sc.title,
                            role: InkTextRole.captionMeta,
                            color: activeScene?.id == sc.id
                                ? theme.inkPrimary
                                : theme.inkMuted,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 14, top: 6),
                child: _addingScene
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          QuillInput(
                            controller: _newSceneCtrl,
                            focusNode: _newSceneFocus,
                            placeholder: l10n.t(L10nKey.storyAddScene),
                            maxLines: 1,
                            submitOnEnter: false,
                            onSubmitted: () {
                              unawaited(
                                ctrl.addStoryScene(ch.id, _newSceneCtrl.text),
                              );
                              _newSceneCtrl.clear();
                              setState(() => _addingScene = false);
                            },
                          ),
                          const SizedBox(height: 4),
                          EngravedButton(
                            label: l10n.t(L10nKey.threadSave),
                            compact: true,
                            onPressed: () {
                              unawaited(
                                ctrl.addStoryScene(ch.id, _newSceneCtrl.text),
                              );
                              _newSceneCtrl.clear();
                              setState(() => _addingScene = false);
                            },
                          ),
                        ],
                      )
                    : EngravedButton(
                        label: l10n.t(L10nKey.storyAddScene),
                        compact: true,
                        onPressed: () => setState(() => _addingScene = true),
                      ),
              ),
            ],
            const SizedBox(height: 4),
          ],
      ],
    );
  }

  Widget _buildChapterSummary(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineStoryChapter chapter,
  ) {
    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 12,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              BistreIcon(
                BistreUiIcon.bookOpen,
                size: 14,
                color: theme.accentBrass,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: InkText(
                  l10n.t(L10nKey.storyChapterSummary),
                  role: InkTextRole.labelStrong,
                  color: theme.inkPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          InkText(
            l10n.t(L10nKey.storyChapterSummaryHint),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
          const SizedBox(height: 8),
          QuillInput(
            controller: _summaryCtrl,
            focusNode: _summaryFocus,
            placeholder: l10n.t(L10nKey.storyChapterSummary),
            maxLines: 4,
            submitOnEnter: false,
            onSubmitted: () {},
          ),
          if (_contradictions.isNotEmpty) ...[
            const SizedBox(height: 8),
            InkText(
              l10n.t(L10nKey.storyContradictionsTitle),
              role: InkTextRole.labelStrong,
              color: theme.statusWarn,
            ),
            for (final c in _contradictions)
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 4),
                child: InkText(
                  c,
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
              ),
          ],
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: _summaryCtrl,
            builder: (context, _) {
              final dirty = _summaryCtrl.text.trim() != chapter.eraSummary;
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.storyWriteSummary),
                    compact: true,
                    onPressed: _running != null
                        ? null
                        : () => unawaited(_writeSummary(ctrl, chapter)),
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.threadSave),
                    compact: true,
                    onPressed: !dirty
                        ? null
                        : () => unawaited(
                            ctrl.saveStoryChapter(
                              EngineStoryChapter(
                                id: chapter.id,
                                threadId: chapter.threadId,
                                orderIndex: chapter.orderIndex,
                                title: chapter.title,
                                summary: chapter.summary,
                                eraSummary: _summaryCtrl.text.trim(),
                                createdAtMs: chapter.createdAtMs,
                              ),
                            ),
                          ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEditorPane(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineStoryChapter? activeChapter,
    EngineStoryScene? activeScene,
  ) {
    if (activeChapter == null || activeScene == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (activeChapter != null) ...[
            _buildChapterSummary(theme, l10n, ctrl, activeChapter),
            const SizedBox(height: 12),
          ],
          FolioSurface(
            tone: FolioTone.elevated,
            borderRadius: 12,
            padding: const EdgeInsetsDirectional.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkText(
                  l10n.t(L10nKey.storyViewManuscript),
                  role: InkTextRole.titleMedium,
                ),
                const SizedBox(height: 6),
                InkText(
                  l10n.t(L10nKey.storySceneBeats),
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
                const SizedBox(height: 12),
                EngravedButton(
                  label: activeChapter == null
                      ? l10n.t(L10nKey.storyAddChapter)
                      : l10n.t(L10nKey.storyAddScene),
                  primary: true,
                  compact: true,
                  onPressed: () => setState(() {
                    if (activeChapter == null) {
                      _addingChapter = true;
                    } else {
                      _addingScene = true;
                    }
                  }),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final idle = _running == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildChapterSummary(theme, l10n, ctrl, activeChapter),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: InkText(activeScene.title, role: InkTextRole.titleMedium),
            ),
            InkText(
              l10n.t(L10nKey.storyWordCount, <String, Object?>{
                'count': _wordCount(_proseCtrl.text),
              }),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                _beatsCtrl,
                _proseCtrl,
              ]),
              builder: (context, _) {
                final dirty =
                    _beatsCtrl.text != activeScene.beatsText ||
                    _proseCtrl.text != activeScene.proseText;
                return EngravedButton(
                  label: l10n.t(L10nKey.threadSave),
                  semanticsLabel: dirty
                      ? l10n.t(L10nKey.storySaveUnsaved)
                      : l10n.t(L10nKey.threadSave),
                  compact: true,
                  leading: dirty
                      ? SizedBox.square(
                          dimension: 7,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.accentBrass,
                              shape: BoxShape.circle,
                            ),
                          ),
                        )
                      : null,
                  onPressed: !dirty
                      ? null
                      : () => unawaited(
                          ctrl.saveStoryScene(
                            EngineStoryScene(
                              id: activeScene.id,
                              chapterId: activeScene.chapterId,
                              orderIndex: activeScene.orderIndex,
                              title: activeScene.title,
                              beatsText: _beatsCtrl.text,
                              proseText: _proseCtrl.text,
                              povCharacterId: activeScene.povCharacterId,
                            ),
                          ),
                        ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Scene beats: a writing brief, then prose written from them.
        FolioSurface(
          tone: FolioTone.elevated,
          borderRadius: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  BistreIcon(
                    BistreUiIcon.assistant,
                    size: 14,
                    color: theme.accentBrass,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: InkText(
                      l10n.t(L10nKey.storySceneBeats),
                      role: InkTextRole.labelStrong,
                      color: theme.inkPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              QuillInput(
                controller: _beatsCtrl,
                focusNode: _beatsFocus,
                placeholder: l10n.t(L10nKey.storySceneBeats),
                maxLines: 4,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  EngravedButton(
                    label: l10n.t(L10nKey.storyPlanScene),
                    compact: true,
                    onPressed: idle
                        ? () => unawaited(_planScene(ctrl, activeScene))
                        : null,
                  ),
                  EngravedButton(
                    label: l10n.t(L10nKey.storyGenerateProse),
                    primary: true,
                    compact: true,
                    onPressed: () => unawaited(
                      ctrl.generateProseFromBeats(
                        EngineStoryScene(
                          id: activeScene.id,
                          chapterId: activeScene.chapterId,
                          orderIndex: activeScene.orderIndex,
                          title: activeScene.title,
                          beatsText: _beatsCtrl.text,
                          proseText: _proseCtrl.text,
                        ),
                        request: l10n.t(
                          L10nKey.storyRequestProseFromBeats,
                          <String, Object?>{
                            'title': activeScene.title,
                            'beats': _beatsCtrl.text.trim(),
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Rewrite tools: on the selected text, or the whole scene.
        ListenableBuilder(
          listenable: _proseCtrl,
          builder: (context, _) {
            final sel = _proseCtrl.selection;
            final onSelection = sel.isValid && !sel.isCollapsed;
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                InkText(
                  l10n.t(
                    onSelection
                        ? L10nKey.storyLaserScopeSelection
                        : L10nKey.storyLaserScopeScene,
                  ),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                ),
                for (final (label, mode) in _kRewriteTools)
                  EngravedButton(
                    label: l10n.t(label),
                    compact: true,
                    onPressed: !idle || _proseCtrl.text.trim().isEmpty
                        ? null
                        : () => unawaited(_rewrite(ctrl, mode)),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),

        FolioSurface(
          tone: FolioTone.elevated,
          borderRadius: 12,
          padding: const EdgeInsetsDirectional.all(14),
          child: QuillInput(
            controller: _proseCtrl,
            focusNode: _proseFocus,
            placeholder: l10n.t(L10nKey.storyViewManuscript),
            maxLines: 14,
            submitOnEnter: false,
            onSubmitted: () {},
            onChanged: (_) => setState(() {}),
          ),
        ),
      ],
    );
  }
}
