import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

String _chapterNumberLabel(int index, String title) => '$index. $title';
String _wordCountLabel(String text) {
  final words = text
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .length;
  return '$words words';
}

/// Long-Form Fiction Manuscript Canvas inside `Write` mode:
/// - Left Chapter & Scene tree (`New chapter`, `New scene`)
/// - Scene Outline & Beats panel with 1-click `Write prose from beats`
/// - Distraction-free Sepia prose editor with live word count
/// - Inline Rewrite Laser Tools bar (`Rewrite | Expand | Shorten | Polish`).
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
  final TextEditingController _beatsCtrl = TextEditingController();
  final FocusNode _beatsFocus = FocusNode();
  final TextEditingController _proseCtrl = TextEditingController();
  final FocusNode _proseFocus = FocusNode();

  bool _addingChapter = false;
  bool _addingScene = false;
  String _syncedSceneId = '';

  @override
  void dispose() {
    _newChapterCtrl.dispose();
    _newChapterFocus.dispose();
    _newSceneCtrl.dispose();
    _newSceneFocus.dispose();
    _beatsCtrl.dispose();
    _beatsFocus.dispose();
    _proseCtrl.dispose();
    _proseFocus.dispose();
    super.dispose();
  }

  void _syncActiveScene(EngineStoryScene? scene) {
    final id = scene?.id ?? '';
    if (id == _syncedSceneId) return;
    _syncedSceneId = id;
    _beatsCtrl.text = scene?.beatsText ?? '';
    _proseCtrl.text = scene?.proseText ?? '';
  }

  void _laserRewrite(
    FolioController ctrl,
    BistreLocalizationController l10n,
    L10nKey request,
  ) {
    final excerpt = _selectedOrFullProse().trim();
    unawaited(
      ctrl.runLaserRewrite(
        excerpt: excerpt,
        request: l10n.t(request, <String, Object?>{'excerpt': excerpt}),
      ),
    );
  }

  String _selectedOrFullProse() {
    final sel = _proseCtrl.selection;
    final text = _proseCtrl.text;
    if (sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= text.length) {
      return text.substring(sel.start, sel.end);
    }
    return text;
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final activeChapter = ctrl.activeChapter;
    final activeScene = ctrl.activeScene;
    _syncActiveScene(activeScene);

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
          return SingleChildScrollView(
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
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 224,
              child: ColoredBox(
                color: theme.bgSurface.withValues(alpha: 0.5),
                child: SingleChildScrollView(
                  padding: const EdgeInsetsDirectional.all(12),
                  child: chapterList,
                ),
              ),
            ),
            const FolioDivider(vertical: true),
            Expanded(
              child: SingleChildScrollView(
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
            GestureDetector(
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

  Widget _buildEditorPane(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    FolioController ctrl,
    EngineStoryChapter? activeChapter,
    EngineStoryScene? activeScene,
  ) {
    if (activeChapter == null || activeScene == null) {
      return FolioSurface(
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
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: InkText(activeScene.title, role: InkTextRole.titleMedium),
            ),
            InkText(
              _wordCountLabel(_proseCtrl.text),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            ),
            const SizedBox(width: 8),
            EngravedButton(
              label: l10n.t(L10nKey.threadSave),
              compact: true,
              onPressed: () => unawaited(
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
            ),
          ],
        ),
        const SizedBox(height: 12),

        // --- Scene Outline & Beats -> Prose ---
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
              const SizedBox(height: 8),
              QuillInput(
                controller: _beatsCtrl,
                focusNode: _beatsFocus,
                placeholder: l10n.t(L10nKey.storySceneBeats),
                maxLines: 4,
                submitOnEnter: false,
                onSubmitted: () {},
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // --- Inline Rewrite Laser Tools (Rewrite | Expand | Shorten | Polish) ---
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            InkChip(
              label: l10n.t(L10nKey.storyLaserRewrite),
              selected: false,
              onSelected: () =>
                  _laserRewrite(ctrl, l10n, L10nKey.storyRequestRewrite),
            ),
            InkChip(
              label: l10n.t(L10nKey.storyLaserExpand),
              selected: false,
              onSelected: () =>
                  _laserRewrite(ctrl, l10n, L10nKey.storyRequestExpand),
            ),
            InkChip(
              label: l10n.t(L10nKey.storyLaserShorten),
              selected: false,
              onSelected: () =>
                  _laserRewrite(ctrl, l10n, L10nKey.storyRequestShorten),
            ),
            InkChip(
              label: l10n.t(L10nKey.storyLaserPolish),
              selected: false,
              onSelected: () =>
                  _laserRewrite(ctrl, l10n, L10nKey.storyRequestPolish),
            ),
          ],
        ),
        const SizedBox(height: 10),

        // --- Distraction-free Sepia Prose Canvas ---
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
