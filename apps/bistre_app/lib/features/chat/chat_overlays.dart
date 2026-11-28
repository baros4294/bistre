import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/bistre_engine.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_selection_controls.dart';
import '../../design/bistre_theme.dart';
import '../../design/disclosure_reveal.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import '../studio/runs_dock_panel.dart';
import 'usage_details_pill.dart';

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
                        semanticsLabel: l10n.t(L10nKey.shellClose),
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
                                        label: l10n.t(L10nKey.chatPinnedShow),
                                        compact: true,
                                        onPressed: () {
                                          onClose();
                                          unawaited(
                                            controller.revealNode(
                                              node.threadId,
                                              node.id,
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(width: BistreSpacing.s4),
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
  /// The raw provider metadata is a diagnostic: folded until asked for.
  bool _showRaw = false;

  /// What was sent and what came back, while core keeps them (replies since it started).
  late final Future<EngineRawExchange?>? _exchange =
      widget.node.role == 'assistant'
      ? widget.controller.rawExchangeFor(widget.node)
      : null;

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
    // The sources core parsed from the provider's response, not URLs scraped from text.
    final sources = widget.controller.groundingFor(widget.node.id);
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
                        semanticsLabel: l10n.t(L10nKey.shellClose),
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
                            // The plain summary first: model, tokens, time, cost.
                            if (widget.node.usageMeta case final usage?) ...[
                              InkText(
                                usage.providerName.isEmpty
                                    ? l10n.isolate(usage.modelId)
                                    : l10n.t(
                                        L10nKey.shellModelOnProvider,
                                        <String, Object?>{
                                          'model': l10n.isolate(usage.modelId),
                                          'provider': l10n.isolate(
                                            usage.providerName,
                                          ),
                                        },
                                      ),
                                role: InkTextRole.labelStrong,
                              ),
                              const SizedBox(height: BistreSpacing.s8),
                              UsageBreakdownRows(usage: usage),
                              const SizedBox(height: BistreSpacing.s16),
                            ],
                            if (sources.isNotEmpty) ...[
                              InkText(
                                l10n.t(
                                  L10nKey.chatTurnSources,
                                  <String, Object?>{'count': sources.length},
                                ),
                                role: InkTextRole.labelStrong,
                                color: theme.accentBrass,
                              ),
                              const SizedBox(height: BistreSpacing.s8),
                              for (final source in sources) ...[
                                GroundingSourceRow(
                                  source: source,
                                  onCopyLink: () => unawaited(
                                    widget.controller.copyText(source.url),
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
                            if (_exchange case final exchange?)
                              FutureBuilder<EngineRawExchange?>(
                                future: exchange,
                                builder: (context, snap) => _RawExchangeRows(
                                  loading:
                                      snap.connectionState !=
                                      ConnectionState.done,
                                  exchange: snap.data,
                                  onCopy: (text) => unawaited(
                                    widget.controller.copyText(text),
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

/// A reply's raw request body and response stream, each folded until opened; a reply core
/// no longer keeps says so.
class _RawExchangeRows extends StatefulWidget {
  const _RawExchangeRows({
    required this.loading,
    required this.exchange,
    required this.onCopy,
  });

  final bool loading;
  final EngineRawExchange? exchange;
  final ValueChanged<String> onCopy;

  @override
  State<_RawExchangeRows> createState() => _RawExchangeRowsState();
}

class _RawExchangeRowsState extends State<_RawExchangeRows> {
  bool _requestOpen = false;
  bool _responseOpen = false;

  Widget _fold(
    BistreLocalizationController l10n,
    L10nKey title,
    String text,
    bool open,
    VoidCallback onToggle,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: InkText(l10n.t(title), role: InkTextRole.labelStrong),
          ),
          BistreIconButton(
            icon: BistreUiIcon.copy,
            size: 13,
            semanticsLabel: l10n.t(L10nKey.chatActionCopy),
            onPressed: () => widget.onCopy(text),
          ),
          BistreIconButton(
            icon: open ? BistreUiIcon.chevronUp : BistreUiIcon.chevronDown,
            size: 14,
            semanticsLabel: l10n.t(title),
            onPressed: onToggle,
          ),
        ],
      ),
      DisclosureReveal(
        open: open,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s8),
          child: FolioSurface(
            borderRadius: 8,
            child: InkText(text, role: InkTextRole.codeBlock),
          ),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final exchange = widget.exchange;
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s12),
      child: widget.loading
          ? const SizedBox.shrink()
          : exchange == null
          ? InkText(
              l10n.t(L10nKey.chatTurnRawGone),
              role: InkTextRole.captionMeta,
              color: theme.inkMuted,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _fold(
                  l10n,
                  L10nKey.chatTurnRawRequest,
                  '${exchange.url}\n\n${exchange.requestBody}',
                  _requestOpen,
                  () => setState(() => _requestOpen = !_requestOpen),
                ),
                const SizedBox(height: BistreSpacing.s8),
                _fold(
                  l10n,
                  L10nKey.chatTurnRawResponse,
                  exchange.response,
                  _responseOpen,
                  () => setState(() => _responseOpen = !_responseOpen),
                ),
                if (exchange.truncated)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      top: BistreSpacing.s4,
                    ),
                    child: InkText(
                      l10n.t(L10nKey.chatTurnRawTruncated),
                      role: InkTextRole.captionMeta,
                      color: theme.inkMuted,
                    ),
                  ),
              ],
            ),
    );
  }
}

/// Modal previewing a local image or text attachment cleanly with Escape and Android back support.
/// One action in the file viewer's action row.
typedef ViewerAction = ({
  L10nKey label,
  BistreUiIcon icon,
  VoidCallback onPressed,
});

/// The file viewer: pictures zoom and can be copied, text and code show as selectable text, a
/// sound file plays where the host can play it, and every file can be saved, shown in its
/// folder, or opened in its default app where the platform allows. Anything else names the file and offers those
/// actions.
class AttachmentViewerModal extends StatefulWidget {
  const AttachmentViewerModal({
    super.key,
    required this.attachment,
    required this.reduceMotionOverride,
    required this.onClose,
    this.onOpenFolder,
    this.onOpenInApp,
    this.onSaveCopy,
    this.onCopyPicture,
    this.onPlay,
    this.onStop,
    this.onCopied,
  });

  final ComposerAttachment attachment;
  final bool reduceMotionOverride;
  final VoidCallback onClose;

  /// Each action is shown only when set (the platform and file allow it).
  final VoidCallback? onOpenFolder;
  final VoidCallback? onOpenInApp;
  final VoidCallback? onSaveCopy;
  final VoidCallback? onCopyPicture;
  final VoidCallback? onPlay;
  final VoidCallback? onStop;

  /// After the shown text was copied (the shell shows its notice).
  final VoidCallback? onCopied;

  @override
  State<AttachmentViewerModal> createState() => _AttachmentViewerModalState();
}

/// Most bytes of a text file the viewer reads and lays out.
const int kMaxViewerTextBytes = 256 * 1024;

/// Whether the viewer shows [mimeType] as text.
bool isViewerText(String mimeType) {
  final mime = mimeType.toLowerCase();
  return mime.startsWith('text/') ||
      mime.endsWith('+json') ||
      mime.endsWith('+xml') ||
      const <String>{
        'application/json',
        'application/xml',
        'application/javascript',
        'application/x-yaml',
        'application/yaml',
        'application/toml',
        'application/x-sh',
        'application/sql',
      }.contains(mime);
}

class _AttachmentViewerModalState extends State<AttachmentViewerModal> {
  final BistreSelectionControls _selection = BistreSelectionControls();

  /// The shown text and whether the file was longer; null while loading or not text.
  Future<(String, bool)>? _text;

  bool get _isImage => widget.attachment.mimeType.startsWith('image/');

  @override
  void initState() {
    super.initState();
    if (!_isImage &&
        widget.attachment.path.isNotEmpty &&
        isViewerText(widget.attachment.mimeType)) {
      _text = _readText(widget.attachment.path);
    }
  }

  @override
  void dispose() {
    // Closing the viewer ends its sound.
    widget.onStop?.call();
    super.dispose();
  }

  static Future<(String, bool)> _readText(String path) async {
    final file = await File(path).open();
    try {
      final total = await file.length();
      final bytes = await file.read(kMaxViewerTextBytes);
      // A cut can split a character; the decoder shows it as one replacement mark.
      return (utf8.decode(bytes, allowMalformed: true), total > bytes.length);
    } finally {
      await file.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final media = MediaQuery.sizeOf(context);
    final maxW = (media.width * 0.92).clamp(280.0, 720.0);
    final att = widget.attachment;
    final actions = <ViewerAction>[
      if (widget.onPlay case final play?)
        (label: L10nKey.viewerPlay, icon: BistreUiIcon.volume, onPressed: play),
      if (widget.onStop case final stop?)
        (
          label: L10nKey.chatActionStop,
          icon: BistreUiIcon.stop,
          onPressed: stop,
        ),
      if (widget.onCopyPicture case final copy?)
        (
          label: L10nKey.viewerCopyPicture,
          icon: BistreUiIcon.copy,
          onPressed: copy,
        ),
      if (widget.onSaveCopy case final save?)
        (
          label: L10nKey.viewerSaveCopy,
          icon: BistreUiIcon.download,
          onPressed: save,
        ),
      if (widget.onOpenInApp case final open?)
        (
          label: L10nKey.viewerOpenApp,
          icon: BistreUiIcon.exportIcon,
          onPressed: open,
        ),
      if (widget.onOpenFolder case final folder?)
        (
          label: L10nKey.settingsStorageOpenFolder,
          icon: BistreUiIcon.folder,
          onPressed: folder,
        ),
    ];

    return FolioModalBackdrop(
      onDismiss: widget.onClose,
      reduceMotionOverride: widget.reduceMotionOverride,
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
                              att.name,
                              role: InkTextRole.titleMedium,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            InkText(
                              l10n.joinMeta(<String>[
                                att.mimeType,
                                l10n.fileSize(att.sizeBytes),
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
                        semanticsLabel: l10n.t(L10nKey.shellClose),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const SizedBox(height: BistreSpacing.s12),
                  const FolioDivider(),
                  const SizedBox(height: BistreSpacing.s12),
                  Flexible(child: _body(theme, l10n)),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: BistreSpacing.s12),
                    Wrap(
                      spacing: BistreSpacing.s8,
                      runSpacing: BistreSpacing.s8,
                      children: [
                        for (final a in actions)
                          EngravedButton(
                            label: l10n.t(a.label),
                            compact: true,
                            leading: BistreIcon(
                              a.icon,
                              size: 13,
                              color: theme.inkSecondary,
                            ),
                            onPressed: a.onPressed,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BistreThemeData theme, BistreLocalizationController l10n) {
    final att = widget.attachment;
    if (_isImage && att.path.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // Decoded at most 2560 px on its long side (a 48 MP photo decoded in full is about
        // 190 MB), with smooth pinch/wheel zoom.
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          child: Image(
            image: ResizeImage(
              FileImage(File(att.path)),
              width: kMaxPreviewDecodePx,
              height: kMaxPreviewDecodePx,
              policy: ResizeImagePolicy.fit,
            ),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                _note(theme, l10n.t(L10nKey.viewerNoPreview)),
          ),
        ),
      );
    }
    final text = _text;
    if (text == null) {
      return att.inlineReference.isNotEmpty
          ? _textPanel(theme, l10n, att.inlineReference, cut: false)
          : _note(theme, l10n.t(L10nKey.viewerNoPreview));
    }
    return FutureBuilder<(String, bool)>(
      future: text,
      builder: (context, snap) {
        if (snap.hasError) {
          return _note(theme, l10n.t(L10nKey.viewerNoPreview));
        }
        final data = snap.data;
        if (data == null) return const SizedBox(height: 48);
        return _textPanel(theme, l10n, data.$1, cut: data.$2);
      },
    );
  }

  Widget _note(BistreThemeData theme, String message) => Padding(
    padding: const EdgeInsetsDirectional.symmetric(vertical: BistreSpacing.s16),
    child: InkText(
      message,
      role: InkTextRole.bodyCompact,
      color: theme.inkMuted,
    ),
  );

  Widget _textPanel(
    BistreThemeData theme,
    BistreLocalizationController l10n,
    String text, {
    required bool cut,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Flexible(
        child: Stack(
          children: [
            SmoothScrollable(
              builder: (_, scroll) => SingleChildScrollView(
                controller: scroll,
                child: FolioSurface(
                  borderRadius: 8,
                  child: SelectableRegion(
                    selectionControls: _selection,
                    contextMenuBuilder: buildBistreSelectableContextMenu,
                    child: InkText(text, role: InkTextRole.codeBlock),
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              top: BistreSpacing.s4,
              end: BistreSpacing.s4,
              child: BistreIconButton(
                icon: BistreUiIcon.copy,
                size: 14,
                semanticsLabel: l10n.t(L10nKey.chatActionCopy),
                onPressed: () => unawaited(() async {
                  await Clipboard.setData(ClipboardData(text: text));
                  widget.onCopied?.call();
                }()),
              ),
            ),
          ],
        ),
      ),
      if (cut)
        Padding(
          padding: const EdgeInsetsDirectional.only(top: BistreSpacing.s8),
          child: InkText(
            l10n.t(L10nKey.viewerTextCut, <String, Object?>{
              'size': l10n.fileSize(kMaxViewerTextBytes),
            }),
            role: InkTextRole.captionMeta,
            color: theme.inkMuted,
          ),
        ),
    ],
  );
}

/// Longest side an attachment preview is decoded at.
const int kMaxPreviewDecodePx = 2560;
