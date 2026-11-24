import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Modal listing all pinned messages in the active conversation.
class PinnedRepliesModal extends StatelessWidget {
  const PinnedRepliesModal({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final FolioController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final pinned = controller.pinnedNodes;
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width * 0.92).clamp(280.0, 560.0);

    return FolioModalBackdrop(
      onDismiss: onClose,
      reduceMotionOverride: controller.reduceMotionOverride,
      child: FocusScope(
        autofocus: true,
        child: GestureDetector(
          onTap: () {},
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW,
              maxHeight: media.height * 0.76,
            ),
            child: FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 12,
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              boxShadow: theme.floatingShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.pin,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: BistreSpacing.s8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.chatPinnedTitle, <String, Object?>{
                            'count': pinned.length,
                          }),
                          role: InkTextRole.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 15,
                        semanticsLabel: l10n.t(L10nKey.threadCancel),
                        onPressed: onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: BistreSpacing.s12),
                  const FolioDivider(),
                  const SizedBox(height: BistreSpacing.s12),
                  if (pinned.isEmpty)
                    Padding(
                      padding: const EdgeInsetsDirectional.symmetric(
                        vertical: BistreSpacing.s24,
                      ),
                      child: Center(
                        child: InkText(
                          l10n.t(L10nKey.chatPinnedEmpty),
                          role: InkTextRole.bodyCompact,
                          color: theme.inkMuted,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: SmoothScrollable(
                        builder: (_, scroll) => ListView.separated(
                          controller: scroll,
                          shrinkWrap: true,
                          itemCount: pinned.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: BistreSpacing.s8),
                          itemBuilder: (_, index) {
                            final node = pinned[index];
                            final roleLabel = node.role == 'user'
                                ? l10n.t(L10nKey.shellRoleUser)
                                : l10n.t(L10nKey.shellRoleAssistant);
                            return FolioSurface(
                              borderRadius: 10,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: InkText(
                                          roleLabel,
                                          role: InkTextRole.labelStrong,
                                          color: theme.accentBrass,
                                        ),
                                      ),
                                      EngravedButton(
                                        label: l10n.t(L10nKey.chatActionCopy),
                                        compact: true,
                                        onPressed: () => unawaited(
                                          controller.copyText(node.content),
                                        ),
                                      ),
                                      const SizedBox(width: BistreSpacing.s4),
                                      EngravedButton(
                                        label: l10n.t(L10nKey.chatUnpinReply),
                                        compact: true,
                                        onPressed: () => unawaited(
                                          controller.togglePinNode(node.id),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: BistreSpacing.s4),
                                  InkText(
                                    node.content.trim(),
                                    role: InkTextRole.bodyCompact,
                                    maxLines: 4,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Private per-chat notes modal stored locally in `kv_meta` and never sent to any model.
class ChatNotesModal extends StatefulWidget {
  const ChatNotesModal({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final FolioController controller;
  final VoidCallback onClose;

  @override
  State<ChatNotesModal> createState() => _ChatNotesModalState();
}

class _ChatNotesModalState extends State<ChatNotesModal> {
  final TextEditingController _notesCtrl = TextEditingController();
  final FocusNode _notesFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _notesCtrl.text = widget.controller.activeChatNotes;
  }

  @override
  void dispose() {
    unawaited(widget.controller.saveActiveChatNotes(_notesCtrl.text));
    _notesCtrl.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width * 0.92).clamp(280.0, 560.0);

    return FolioModalBackdrop(
      onDismiss: widget.onClose,
      reduceMotionOverride: widget.controller.reduceMotionOverride,
      child: FocusScope(
        autofocus: true,
        child: GestureDetector(
          onTap: () {},
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW,
              maxHeight: media.height * 0.72,
            ),
            child: FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 12,
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              boxShadow: theme.floatingShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.document,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: BistreSpacing.s8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.chatNotesTitle),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 15,
                        semanticsLabel: l10n.t(L10nKey.threadCancel),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: BistreSpacing.s12),
                  QuillInput(
                    controller: _notesCtrl,
                    focusNode: _notesFocus,
                    placeholder: l10n.t(L10nKey.chatNotesPlaceholder),
                    maxLines: 10,
                    submitOnEnter: false,
                    onSubmitted: () {},
                    onChanged: (v) =>
                        unawaited(widget.controller.saveActiveChatNotes(v)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal displaying extracted web source citations and collapsible raw turn metadata JSON.
class TurnDetailsModal extends StatefulWidget {
  const TurnDetailsModal({
    super.key,
    required this.node,
    required this.controller,
    required this.onClose,
  });

  final EngineNode node;
  final FolioController controller;
  final VoidCallback onClose;

  @override
  State<TurnDetailsModal> createState() => _TurnDetailsModalState();
}

class _TurnDetailsModalState extends State<TurnDetailsModal> {
  bool _showRaw = true;

  static final RegExp _urlPattern = RegExp(
    r'https?://[^\s\)\]>"]+',
    caseSensitive: false,
  );

  List<String> _extractUrls() {
    final found = <String>{};
    for (final m in _urlPattern.allMatches(widget.node.content)) {
      final raw = m.group(0)?.replaceAll(RegExp(r'[.,;:]+$'), '') ?? '';
      if (raw.isNotEmpty) found.add(raw);
    }
    return found.toList(growable: false);
  }

  String _prettyMeta() {
    final raw = widget.node.providerMetaJson?.trim() ?? '';
    if (raw.isEmpty) return '{}';
    try {
      const encoder = JsonEncoder.withIndent('  ');
      return encoder.convert(jsonDecode(raw));
    } on FormatException {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final urls = _extractUrls();
    final pretty = _prettyMeta();
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width * 0.92).clamp(280.0, 620.0);

    return FolioModalBackdrop(
      onDismiss: widget.onClose,
      reduceMotionOverride: widget.controller.reduceMotionOverride,
      child: FocusScope(
        autofocus: true,
        child: GestureDetector(
          onTap: () {},
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW,
              maxHeight: media.height * 0.78,
            ),
            child: FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 12,
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              boxShadow: theme.floatingShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.info,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: BistreSpacing.s8),
                      Expanded(
                        child: InkText(
                          l10n.t(L10nKey.chatTurnDetails),
                          role: InkTextRole.titleMedium,
                        ),
                      ),
                      EngravedButton(
                        label: l10n.t(L10nKey.chatActionCopy),
                        compact: true,
                        onPressed: () =>
                            unawaited(widget.controller.copyText(pretty)),
                      ),
                      const SizedBox(width: BistreSpacing.s4),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 15,
                        semanticsLabel: l10n.t(L10nKey.threadCancel),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: BistreSpacing.s12),
                  const FolioDivider(),
                  const SizedBox(height: BistreSpacing.s12),
                  Flexible(
                    child: SmoothScrollable(
                      builder: (_, scroll) => SingleChildScrollView(
                        controller: scroll,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (urls.isNotEmpty) ...[
                              InkText(
                                l10n.t(
                                  L10nKey.chatTurnSources,
                                  <String, Object?>{'count': urls.length},
                                ),
                                role: InkTextRole.labelStrong,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(height: BistreSpacing.s8),
                              for (final url in urls) ...[
                                FolioSurface(
                                  borderRadius: 8,
                                  padding:
                                      const EdgeInsetsDirectional.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                  child: Row(
                                    children: [
                                      BistreIcon(
                                        BistreUiIcon.globe,
                                        size: 13,
                                        color: theme.accentBrass,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: InkText(
                                          url,
                                          role: InkTextRole.captionMeta,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      BistreIconButton(
                                        icon: BistreUiIcon.copy,
                                        size: 13,
                                        dimension: 28,
                                        semanticsLabel: l10n.t(
                                          L10nKey.chatActionCopy,
                                        ),
                                        onPressed: () => unawaited(
                                          widget.controller.copyText(url),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: BistreSpacing.s4),
                              ],
                              const SizedBox(height: BistreSpacing.s12),
                            ],
                            Row(
                              children: [
                                Expanded(
                                  child: InkText(
                                    l10n.t(L10nKey.chatTurnRawMetadata),
                                    role: InkTextRole.labelStrong,
                                  ),
                                ),
                                BistreIconButton(
                                  icon: _showRaw
                                      ? BistreUiIcon.chevronUp
                                      : BistreUiIcon.chevronDown,
                                  size: 14,
                                  semanticsLabel: l10n.t(
                                    L10nKey.chatTurnRawMetadata,
                                  ),
                                  onPressed: () =>
                                      setState(() => _showRaw = !_showRaw),
                                ),
                              ],
                            ),
                            DisclosureReveal(
                              open: _showRaw,
                              child: Padding(
                                padding: const EdgeInsetsDirectional.only(
                                  top: BistreSpacing.s8,
                                ),
                                child: FolioSurface(
                                  borderRadius: 8,
                                  child: InkText(
                                    pretty,
                                    role: InkTextRole.codeBlock,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Modal previewing a local image or text attachment cleanly with Escape and Android back support.
class AttachmentViewerModal extends StatelessWidget {
  const AttachmentViewerModal({
    super.key,
    required this.attachment,
    required this.reduceMotionOverride,
    required this.onClose,
  });

  final ComposerAttachment attachment;
  final bool reduceMotionOverride;
  final VoidCallback onClose;

  bool get _isImage => attachment.mimeType.startsWith('image/');

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width * 0.92).clamp(280.0, 720.0);
    final file = File(attachment.path);
    final fileExists = attachment.path.isNotEmpty && file.existsSync();

    return FolioModalBackdrop(
      onDismiss: onClose,
      reduceMotionOverride: reduceMotionOverride,
      child: FocusScope(
        autofocus: true,
        child: GestureDetector(
          onTap: () {},
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxW,
              maxHeight: media.height * 0.82,
            ),
            child: FolioSurface(
              tone: FolioTone.elevated,
              borderRadius: 12,
              padding: const EdgeInsetsDirectional.all(BistreSpacing.s16),
              boxShadow: theme.floatingShadow,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BistreIcon(
                        BistreUiIcon.paperclip,
                        size: 16,
                        color: theme.accentBrass,
                      ),
                      const SizedBox(width: BistreSpacing.s8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkText(
                              attachment.name,
                              role: InkTextRole.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            InkText(
                              l10n.joinMeta(<String>[
                                attachment.mimeType,
                                '${(attachment.sizeBytes / 1024).toStringAsFixed(1)} KB',
                              ]),
                              role: InkTextRole.captionMeta,
                              color: theme.inkMuted,
                            ),
                          ],
                        ),
                      ),
                      BistreIconButton(
                        icon: BistreUiIcon.close,
                        size: 15,
                        semanticsLabel: l10n.t(L10nKey.threadCancel),
                        onPressed: onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: BistreSpacing.s12),
                  const FolioDivider(),
                  const SizedBox(height: BistreSpacing.s12),
                  Flexible(
                    child: _isImage && fileExists
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              file,
                              fit: BoxFit.contain,
                              errorBuilder: (_, _, _) => Center(
                                child: InkText(
                                  attachment.name,
                                  role: InkTextRole.bodyCompact,
                                  color: theme.inkMuted,
                                ),
                              ),
                            ),
                          )
                        : SmoothScrollable(
                            builder: (_, scroll) => SingleChildScrollView(
                              controller: scroll,
                              child: FolioSurface(
                                borderRadius: 8,
                                child: InkText(
                                  attachment.inlineReference.isNotEmpty
                                      ? attachment.inlineReference
                                      : attachment.path,
                                  role: InkTextRole.codeBlock,
                                ),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
