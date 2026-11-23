import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../design/smooth_scroll.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Immutable representation of a workspace or MCP tool activity row inside a run.
class ToolActivityEntry {
  const ToolActivityEntry({
    required this.id,
    required this.toolName,
    required this.summary,
    required this.status,
    this.riskTier = 'tier0_read_only',
    this.outputText = '',
    this.diffText,
    this.checkpointId,
    this.durationMs = 0,
  });

  final String id;
  final String toolName;
  final String summary;

  /// One of: `running`, `completed`, `failed`, `awaiting_approval`.
  final String status;
  final String riskTier;
  final String outputText;
  final String? diffText;
  final String? checkpointId;
  final int durationMs;
}

/// Tools whose consecutive completed steps fold into one quiet row.
const Set<String> kFoldableReadOnlyTools = <String>{
  'read',
  'grep',
  'glob',
  'web_fetch',
  'web_search',
};

/// Folds runs of consecutive completed read/search steps into a single entry (summaries and
/// outputs joined) so long exploration bursts read as one quiet line (`docs/design/DESIGN.md` §8).
/// [joinSummaries] is the locale's meta join (`BistreLocalizationController.joinMeta`).
List<ToolActivityEntry> foldReadOnlySteps(
  List<ToolActivityEntry> entries, {
  required String Function(Iterable<String>) joinSummaries,
}) {
  bool foldable(ToolActivityEntry e) =>
      e.status == 'completed' && kFoldableReadOnlyTools.contains(e.toolName);
  final out = <ToolActivityEntry>[];
  var i = 0;
  while (i < entries.length) {
    var j = i;
    while (j < entries.length && foldable(entries[j])) {
      j++;
    }
    if (j - i >= 2) {
      final run = entries.sublist(i, j);
      out.add(
        ToolActivityEntry(
          id: run.first.id,
          toolName: run.first.toolName,
          summary: joinSummaries(run.map((e) => e.summary)),
          status: 'completed',
          outputText: run.map((e) => e.outputText).join('\n\n'),
          durationMs: run.fold<int>(0, (sum, e) => sum + e.durationMs),
        ),
      );
      i = j;
    } else {
      out.add(entries[i]);
      i++;
    }
  }
  return out;
}

/// Quiet collapsed live tool activity timeline with expandable `imara-diff` unified or (on wide layouts) split diff viewer,
/// inline 4-level approval card, and 1-click Rewind backed by SQLite checkpoints.
class ToolTimelineView extends StatelessWidget {
  const ToolTimelineView({
    super.key,
    required this.entries,
    this.onApproveOnce,
    this.onApproveChat,
    this.onDeny,
    this.onRewindCheckpoint,
  });

  final List<ToolActivityEntry> entries;
  final ValueChanged<String>? onApproveOnce;
  final ValueChanged<String>? onApproveChat;
  final ValueChanged<String>? onDeny;
  final ValueChanged<String>? onRewindCheckpoint;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final rows = foldReadOnlySteps(
      entries,
      joinSummaries: BistreLocalizations.of(context).joinMeta,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: BistreSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _ToolActivityRow(
              entry: rows[i],
              onApproveOnce: onApproveOnce,
              onApproveChat: onApproveChat,
              onDeny: onDeny,
              onRewindCheckpoint: onRewindCheckpoint,
            ),
          ],
        ],
      ),
    );
  }
}

class _ToolActivityRow extends StatefulWidget {
  const _ToolActivityRow({
    required this.entry,
    this.onApproveOnce,
    this.onApproveChat,
    this.onDeny,
    this.onRewindCheckpoint,
  });

  final ToolActivityEntry entry;
  final ValueChanged<String>? onApproveOnce;
  final ValueChanged<String>? onApproveChat;
  final ValueChanged<String>? onDeny;
  final ValueChanged<String>? onRewindCheckpoint;

  @override
  State<_ToolActivityRow> createState() => _ToolActivityRowState();
}

class _ToolActivityRowState extends State<_ToolActivityRow> {
  bool _expanded = false;

  static String _formatDuration(int ms) {
    if (ms <= 0) return '';
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000.0).toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final entry = widget.entry;
    final awaiting = entry.status == 'awaiting_approval';
    final failed = entry.status == 'failed';
    final running = entry.status == 'running';

    final statusColor = awaiting
        ? theme.statusWarn
        : failed
        ? theme.statusErr
        : running
        ? theme.accentBrass
        : theme.statusOk;

    final statusText = awaiting
        ? l10n.t(L10nKey.toolApprovalTitle)
        : failed
        ? l10n.t(L10nKey.toolFailed)
        : running
        ? l10n.t(L10nKey.toolRunning)
        : l10n.t(L10nKey.toolCompleted);

    final durationBadge = _formatDuration(entry.durationMs);
    final hasExpandableDetails =
        entry.outputText.trim().isNotEmpty ||
        (entry.diffText != null && entry.diffText!.trim().isNotEmpty);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: awaiting
            ? theme.bgElevated
            : theme.bgSurface.withValues(alpha: theme.isDark ? 0.50 : 0.65),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: awaiting
              ? theme.statusWarn.withValues(alpha: 0.6)
              : theme.borderHairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: hasExpandableDetails
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: hasExpandableDetails
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              child: Padding(
                padding: const EdgeInsetsDirectional.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 7,
                      height: 7,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    BistreIcon(
                      BistreUiIcon.terminal,
                      size: 13,
                      color: theme.inkMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: InkText(
                        entry.summary.isNotEmpty
                            ? entry.summary
                            : entry.toolName,
                        role: InkTextRole.captionMeta,
                        color: theme.inkPrimary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (durationBadge.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      InkText(
                        durationBadge,
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ],
                    const SizedBox(width: 8),
                    InkText(
                      statusText,
                      role: InkTextRole.captionMeta,
                      color: statusColor,
                    ),
                    if (entry.checkpointId != null &&
                        widget.onRewindCheckpoint != null) ...[
                      const SizedBox(width: 8),
                      EngravedButton(
                        label: l10n.t(L10nKey.toolRewind),
                        compact: true,
                        onPressed: () =>
                            widget.onRewindCheckpoint!(entry.checkpointId!),
                      ),
                    ],
                    if (hasExpandableDetails) ...[
                      const SizedBox(width: 6),
                      BistreIcon(
                        _expanded
                            ? BistreUiIcon.chevronUp
                            : BistreUiIcon.chevronDown,
                        size: 13,
                        color: theme.inkMuted,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (awaiting) ...[
            const FolioDivider(),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.onApproveOnce != null)
                    EngravedButton(
                      label: l10n.t(L10nKey.toolApproveOnce),
                      primary: true,
                      compact: true,
                      onPressed: () => widget.onApproveOnce!(entry.id),
                    ),
                  if (widget.onApproveChat != null)
                    EngravedButton(
                      label: l10n.t(L10nKey.toolApproveChat),
                      compact: true,
                      onPressed: () => widget.onApproveChat!(entry.id),
                    ),
                  if (widget.onDeny != null)
                    EngravedButton(
                      label: l10n.t(L10nKey.toolDeny),
                      compact: true,
                      onPressed: () => widget.onDeny!(entry.id),
                    ),
                ],
              ),
            ),
          ],
          if (_expanded && hasExpandableDetails) ...[
            const FolioDivider(),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (entry.diffText != null &&
                      entry.diffText!.trim().isNotEmpty)
                    _DiffViewer(diffText: entry.diffText!),
                  if (entry.outputText.trim().isNotEmpty &&
                      (entry.diffText == null || entry.diffText!.isEmpty))
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SmoothScrollable(
                        builder: (_, scroll) => SingleChildScrollView(
                          controller: scroll,
                          child: InkText(
                            entry.outputText.trim(),
                            role: InkTextRole.codeBlock,
                            color: theme.inkSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Effective width (logical px ÷ text scale) from which wide layouts offer the Split diff toggle.
const double kSplitDiffMinWidth = 720;

/// One side-by-side diff row: `left` is the old line (context or removal), `right` the new line
/// (context or addition); file and hunk headers span both columns.
typedef SplitDiffRow = ({String? left, String? right, bool header});

/// Pairs a unified diff into side-by-side rows: each run of removals is aligned with the run of
/// additions that follows it, and context lines appear on both sides. Every source line appears
/// exactly once (context lines once per side).
List<SplitDiffRow> pairSplitDiffRows(String diffText) {
  final rows = <SplitDiffRow>[];
  final removed = <String>[];
  final added = <String>[];
  void flush() {
    final n = removed.length > added.length ? removed.length : added.length;
    for (var i = 0; i < n; i++) {
      rows.add((
        left: i < removed.length ? removed[i] : null,
        right: i < added.length ? added[i] : null,
        header: false,
      ));
    }
    removed.clear();
    added.clear();
  }

  for (final line in diffText.split('\n')) {
    final isHeader =
        line.startsWith('@@') ||
        line.startsWith('+++') ||
        line.startsWith('---') ||
        line.startsWith('diff ') ||
        line.startsWith('index ');
    if (isHeader) {
      flush();
      rows.add((left: line, right: null, header: true));
    } else if (line.startsWith('-')) {
      if (added.isNotEmpty) flush();
      removed.add(line);
    } else if (line.startsWith('+')) {
      added.add(line);
    } else {
      flush();
      rows.add((left: line, right: line, header: false));
    }
  }
  flush();
  return rows;
}

class _DiffViewer extends StatefulWidget {
  const _DiffViewer({required this.diffText});

  final String diffText;

  @override
  State<_DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<_DiffViewer> {
  bool _split = false;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final canSplit = constraints.maxWidth / scale >= kSplitDiffMinWidth;
        final split = canSplit && _split;
        final Widget body = split
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in pairSplitDiffRows(widget.diffText))
                    row.header
                        ? _DiffLine(line: row.left ?? '', theme: theme)
                        : _SplitDiffRowView(row: row, theme: theme),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final line in widget.diffText.split('\n'))
                    _DiffLine(line: line, theme: theme),
                ],
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (canSplit)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Padding(
                  padding: const EdgeInsetsDirectional.only(bottom: 6),
                  child: EngravedButton(
                    label: split
                        ? l10n.t(L10nKey.toolDiffUnified)
                        : l10n.t(L10nKey.toolDiffSplit),
                    compact: true,
                    onPressed: () => setState(() => _split = !split),
                  ),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SmoothScrollable(
                builder: (_, scroll) => SingleChildScrollView(
                  controller: scroll,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.bgCanvas,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: theme.borderHairline),
                    ),
                    child: Padding(
                      padding: const EdgeInsetsDirectional.all(8),
                      // Diffs are source code: always left-to-right, even in RTL chats.
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: body,
                      ),
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
}

class _SplitDiffRowView extends StatelessWidget {
  const _SplitDiffRowView({required this.row, required this.theme});

  final SplitDiffRow row;
  final BistreThemeData theme;

  @override
  Widget build(BuildContext context) {
    Widget cell(String? line) => Expanded(
      child: line == null
          ? const SizedBox.shrink()
          : _DiffLine(line: line, theme: theme),
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          cell(row.left),
          SizedBox(width: 1, child: ColoredBox(color: theme.borderHairline)),
          cell(row.right),
        ],
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({required this.line, required this.theme});

  final String line;
  final BistreThemeData theme;

  @override
  Widget build(BuildContext context) {
    final isAdd = line.startsWith('+') && !line.startsWith('+++');
    final isDel = line.startsWith('-') && !line.startsWith('---');
    final isHunk = line.startsWith('@@');

    final bg = isAdd
        ? theme.statusOk.withValues(alpha: 0.12)
        : isDel
        ? theme.statusErr.withValues(alpha: 0.12)
        : null;
    final fg = isAdd
        ? theme.statusOk
        : isDel
        ? theme.statusErr
        : isHunk
        ? theme.accentBrass
        : theme.inkSecondary;

    return ColoredBox(
      color: bg ?? theme.bgCanvas.withValues(alpha: 0),
      child: Padding(
        padding: const EdgeInsetsDirectional.symmetric(
          horizontal: 6,
          vertical: 1,
        ),
        child: InkText(line, role: InkTextRole.codeBlock, color: fg),
      ),
    );
  }
}
