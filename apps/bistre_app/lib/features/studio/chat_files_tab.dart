import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../chat/folio_message_feed.dart' show attachmentIconFor, middleEllipsis;
import '../shell/folio_controller.dart';

/// Which files the Files tab shows.
enum ChatFileFilter { all, sent, made, edited }

/// Studio > Files: every file of the open chat (the ones you sent, the ones replies and
/// tools made, and the workspace files the agent edited), newest first, filtered by kind.
/// A sent or made file opens its preview and can be found in the chat; an edited file
/// keeps its hashes, Comment in chat, and Rewind. Web pages stay in Sources.
class ChatFilesTab extends StatefulWidget {
  const ChatFilesTab({super.key, required this.controller});

  final FolioController controller;

  @override
  State<ChatFilesTab> createState() => _ChatFilesTabState();
}

class _ChatFilesTabState extends State<ChatFilesTab> {
  ChatFileFilter _filter = ChatFileFilter.all;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.refreshChatFiles());
  }

  /// The first 8 characters of the file's hash before and after the edit.
  static String _hashPair(EngineCheckpoint cp) {
    String short(String hash) => hash.length <= 8 ? hash : hash.substring(0, 8);
    return '${short(cp.preHashBlake3)} -> ${short(cp.postHashBlake3)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final files = ctrl.chatFiles;
    final shown = <EngineChatFile>[
      for (final f in files)
        if (switch (_filter) {
          ChatFileFilter.all => true,
          ChatFileFilter.sent => f.fromUser,
          ChatFileFilter.made => !f.fromUser,
          ChatFileFilter.edited => false,
        })
          f,
    ];
    final edits =
        _filter == ChatFileFilter.all || _filter == ChatFileFilter.edited
        ? ctrl.checkpoints
        : const <EngineCheckpoint>[];
    final empty = shown.isEmpty && edits.isEmpty;

    return SmoothScrollable(
      builder: (_, scroll) => SingleChildScrollView(
        controller: scroll,
        padding: const EdgeInsetsDirectional.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            BistreSegmentedControl<ChatFileFilter>(
              selected: _filter,
              onSelected: (v) => setState(() => _filter = v),
              options: <BistreSegmentedOption<ChatFileFilter>>[
                BistreSegmentedOption(
                  value: ChatFileFilter.all,
                  label: l10n.t(L10nKey.studioFilesAll),
                ),
                BistreSegmentedOption(
                  value: ChatFileFilter.sent,
                  label: l10n.t(L10nKey.studioFilesSent),
                ),
                BistreSegmentedOption(
                  value: ChatFileFilter.made,
                  label: l10n.t(L10nKey.studioFilesMade),
                ),
                BistreSegmentedOption(
                  value: ChatFileFilter.edited,
                  label: l10n.t(L10nKey.studioFilesEdited),
                ),
              ],
            ),
            const SizedBox(height: BistreSpacing.s12),
            if (empty)
              FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.all(14),
                child: InkText(
                  l10n.t(
                    _filter == ChatFileFilter.all
                        ? L10nKey.studioFilesEmpty
                        : L10nKey.studioFilesNoneOfKind,
                  ),
                  role: InkTextRole.bodyCompact,
                  color: theme.inkSecondary,
                ),
              ),
            for (final f in shown) ...[
              _ChatFileRow(
                file: f,
                onOpen: () => ctrl.openSentAttachment(f.attachment),
                onShowInChat: () {
                  final threadId = ctrl.activeThread?.id;
                  if (threadId != null) {
                    unawaited(ctrl.revealNode(threadId, f.nodeId));
                  }
                },
              ),
              const SizedBox(height: BistreSpacing.s8),
            ],
            for (final cp in edits) ...[
              FolioSurface(
                tone: FolioTone.elevated,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        BistreIcon(
                          BistreUiIcon.edit,
                          size: 13,
                          color: theme.accentBrass,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: InkText(
                            cp.filePath,
                            role: InkTextRole.labelStrong,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    InkText(
                      _hashPair(cp),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        EngravedButton(
                          label: l10n.t(L10nKey.studioCommentAdd),
                          compact: true,
                          onPressed: () => ctrl.attachInlineFileComment(
                            cp.filePath,
                            'L1-L20',
                          ),
                        ),
                        EngravedButton(
                          label: l10n.t(L10nKey.toolRewind),
                          compact: true,
                          leading: BistreIcon(
                            BistreUiIcon.rewind,
                            size: 12,
                            color: theme.inkSecondary,
                          ),
                          onPressed: () =>
                              unawaited(ctrl.rewindCheckpoint(cp.id)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: BistreSpacing.s8),
            ],
          ],
        ),
      ),
    );
  }
}

/// One sent or made file: its type, name, size and kind, Open, and Show in chat.
class _ChatFileRow extends StatelessWidget {
  const _ChatFileRow({
    required this.file,
    required this.onOpen,
    required this.onShowInChat,
  });

  final EngineChatFile file;
  final VoidCallback onOpen;
  final VoidCallback onShowInChat;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return FolioSurface(
      tone: FolioTone.elevated,
      borderRadius: 8,
      padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 4, 6),
      child: Row(
        children: [
          BistreIcon(
            attachmentIconFor(file.mimeType, file.name),
            size: 14,
            color: theme.accentBrass,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                InkText(
                  middleEllipsis(file.name, max: 40),
                  role: InkTextRole.labelStrong,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                InkText(
                  l10n.joinMeta(<String>[
                    l10n.t(
                      file.fromUser
                          ? L10nKey.studioFilesSent
                          : L10nKey.studioFilesMade,
                    ),
                    if (file.sizeBytes > 0) l10n.fileSize(file.sizeBytes),
                  ]),
                  role: InkTextRole.captionMeta,
                  color: theme.inkMuted,
                ),
              ],
            ),
          ),
          BistreIconButton(
            icon: BistreUiIcon.eye,
            size: 13,
            semanticsLabel: l10n.t(L10nKey.studioFilesOpen, <String, Object?>{
              'name': file.name,
            }),
            onPressed: onOpen,
          ),
          BistreIconButton(
            icon: BistreUiIcon.chat,
            size: 13,
            semanticsLabel: l10n.t(L10nKey.studioFilesShowInChat),
            onPressed: onShowInChat,
          ),
        ],
      ),
    );
  }
}
