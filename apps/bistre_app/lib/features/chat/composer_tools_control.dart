import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_motion_widgets.dart';
import '../../design/bistre_theme.dart';
import '../../design/hover_hint.dart';
import '../../design/ink_primitives.dart';
import '../../design/popover_placement.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';
import 'composer_folder_button.dart';
import 'content_direction.dart';

/// Composer `Tools` chip opening an above-anchor popover for workspace status, web search,
/// stateless privacy mode, and optional reply prefill.
class ComposerToolsControl extends StatefulWidget {
  const ComposerToolsControl({
    super.key,
    required this.controller,
    this.compact = false,
  });

  final FolioController controller;
  final bool compact;

  @override
  State<ComposerToolsControl> createState() => _ComposerToolsControlState();
}

class _ComposerToolsControlState extends State<ComposerToolsControl> {
  final FolioOverlayController _popover = FolioOverlayController();
  final LayerLink _link = LayerLink();
  final TextEditingController _prefillCtrl = TextEditingController();
  final FocusNode _prefillFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _prefillCtrl.text = widget.controller.replyPrefill;
  }

  @override
  void dispose() {
    _prefillCtrl.dispose();
    _prefillFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final hasActiveTool =
        ctrl.workspaceRootPath.isNotEmpty ||
        ctrl.webSearchEndpoint.isNotEmpty ||
        ctrl.replyPrefill.isNotEmpty ||
        ctrl.activeThreadMode != 'chat';
    final label = l10n.t(L10nKey.chatToolsButton);

    return FolioOverlay(
      controller: _popover,
      overlayBuilder: _buildPopover,
      child: CompositedTransformTarget(
        link: _link,
        // The hint names an icon-only button; a labelled one says it already.
        child: _hintWhenCompact(
          label,
          EngravedButton(
            label: widget.compact ? '' : label,
            semanticsLabel: label,
            compact: true,
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BistreIcon(
                  BistreUiIcon.terminal,
                  size: 13,
                  color: hasActiveTool ? theme.accentBrass : theme.inkSecondary,
                ),
                if (hasActiveTool) ...[
                  const SizedBox(width: 4),
                  SizedBox.square(
                    dimension: 6,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.accentBrass,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            onPressed: () {
              _prefillCtrl.text = ctrl.replyPrefill;
              _popover.toggle();
            },
          ),
        ),
      ),
    );
  }

  Widget _hintWhenCompact(String label, Widget button) =>
      widget.compact ? HoverHint(message: label, child: button) : button;

  Widget _buildPopover(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final dir = Directionality.of(context);
    final ctrl = widget.controller;
    final workspace = ctrl.workspaceRootPath;
    final webSearch = ctrl.webSearchEndpoint;

    final maxPopoverWidth = PopoverPlacement.popoverWidthFor(context, 392);
    final minPopoverWidth = maxPopoverWidth < 340.0 ? maxPopoverWidth : 340.0;
    final shift = PopoverPlacement.popoverShiftFor(
      this.context,
      width: maxPopoverWidth,
      alignStart: true,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _popover.hide,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: _link,
          showWhenUnlinked: false,
          targetAnchor: AlignmentDirectional.topStart.resolve(dir),
          followerAnchor: AlignmentDirectional.bottomStart.resolve(dir),
          // Moved back inside the window on a narrow screen (never off its edge).
          offset: Offset(shift, -8),
          child: FolioFadeSlide(
            beginOffset: const Offset(0, 0.06),
            reduceMotionOverride: ctrl.reduceMotionOverride,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: minPopoverWidth,
                maxWidth: maxPopoverWidth,
              ),
              child: FolioSurface(
                tone: FolioTone.elevated,
                borderRadius: 12,
                boxShadow: theme.floatingShadow,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: InkText(
                            l10n.t(L10nKey.chatToolsTitle),
                            role: InkTextRole.labelStrong,
                          ),
                        ),
                        BistreIconButton(
                          icon: BistreUiIcon.settings,
                          size: 13,
                          dimension: 28,
                          semanticsLabel: l10n.t(L10nKey.settingsTitle),
                          onPressed: () {
                            _popover.hide();
                            ctrl.openSettings(SettingsTab.agent);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    const FolioDivider(),
                    const SizedBox(height: BistreSpacing.s8),
                    // 1. Conversation Mode (Chat / Plan / Build / Write: Option A)
                    if (ctrl.activeThread != null) ...[
                      InkText(
                        l10n.t(L10nKey.chatModeHeading),
                        role: InkTextRole.captionMeta,
                        color: theme.inkSecondary,
                      ),
                      const SizedBox(height: 6),
                      BistreSegmentedControl<String>(
                        expand: true,
                        selected: ctrl.activeThreadMode,
                        onSelected: (m) =>
                            unawaited(ctrl.setActiveThreadMode(m)),
                        options: <BistreSegmentedOption<String>>[
                          BistreSegmentedOption<String>(
                            value: 'chat',
                            label: l10n.t(L10nKey.modeChat),
                          ),
                          BistreSegmentedOption<String>(
                            value: 'plan',
                            label: l10n.t(L10nKey.modePlan),
                          ),
                          BistreSegmentedOption<String>(
                            value: 'code',
                            label: l10n.t(L10nKey.modeCode),
                          ),
                          BistreSegmentedOption<String>(
                            value: 'write',
                            label: l10n.t(L10nKey.modeWrite),
                          ),
                        ],
                      ),
                      const SizedBox(height: BistreSpacing.s8),
                      const FolioDivider(),
                      const SizedBox(height: BistreSpacing.s8),
                    ],
                    // 2. Tool permissions quick switch (Off / Strict / Balanced / Sandbox)
                    InkText(
                      l10n.t(L10nKey.settingsTrustPresetHeading),
                      role: InkTextRole.captionMeta,
                      color: theme.inkSecondary,
                    ),
                    const SizedBox(height: 6),
                    BistreSegmentedControl<String>(
                      expand: true,
                      selected:
                          ctrl.settings.trustPreset == 'parchment' ||
                              ctrl.settings.trustPreset == 'parchment_safe'
                          ? 'strict'
                          : ctrl.settings.trustPreset,
                      onSelected: (v) => unawaited(
                        ctrl.updateSettings(
                          ctrl.settings.copyWith(trustPreset: v),
                          quiet: true,
                        ),
                      ),
                      options: <BistreSegmentedOption<String>>[
                        BistreSegmentedOption<String>(
                          value: 'off',
                          label: l10n.t(L10nKey.settingsAgentPermOff),
                        ),
                        BistreSegmentedOption<String>(
                          value: 'strict',
                          label: l10n.t(L10nKey.settingsTrustParchment),
                        ),
                        BistreSegmentedOption<String>(
                          value: 'guided_craft',
                          label: l10n.t(L10nKey.settingsTrustGuided),
                        ),
                        BistreSegmentedOption<String>(
                          value: 'unchained_sandbox',
                          label: l10n.t(L10nKey.settingsTrustUnchained),
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    const FolioDivider(),
                    const SizedBox(height: BistreSpacing.s8),
                    // 3. Workspace folder with native OS folder picker
                    Row(
                      children: [
                        Expanded(
                          child: _StatusRow(
                            icon: BistreUiIcon.folder,
                            label: l10n.t(L10nKey.chatToolsWorkspace),
                            // No "Off" caption; the empty detail and the button say it.
                            detail: workspace.isNotEmpty ? workspace : null,
                            active: workspace.isNotEmpty,
                          ),
                        ),
                        const SizedBox(width: 6),
                        EngravedButton(
                          label: l10n.t(L10nKey.settingsAgentChooseFolder),
                          compact: true,
                          onPressed: () {
                            // A project chat's pick opens Settings; the popover closes first.
                            if (ctrl.folderProject != null) _popover.hide();
                            unawaited(
                              chooseChatFolder(
                                ctrl,
                                l10n.t(L10nKey.settingsAgentWorkspaceDir),
                                add: false,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    // 4. Web search toggle (DuckDuckGo keyless default or configured endpoint)
                    Row(
                      children: [
                        Expanded(
                          child: _StatusRow(
                            icon: BistreUiIcon.globe,
                            label: l10n.t(L10nKey.chatToolsWebSearch),
                            detail: webSearch.isNotEmpty
                                ? (webSearch == 'duckduckgo'
                                      ? l10n.t(L10nKey.settingsAgentWebDdg)
                                      : webSearch)
                                : null,
                            active: webSearch.isNotEmpty,
                          ),
                        ),
                        const SizedBox(width: 6),
                        BistreSwitch(
                          value: webSearch.isNotEmpty,
                          semanticsLabel: l10n.t(L10nKey.chatToolsWebSearch),
                          reduceMotionOverride: ctrl.reduceMotionOverride,
                          onChanged: (on) => unawaited(
                            ctrl.setWebSearchEndpoint(on ? 'duckduckgo' : ''),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: BistreSpacing.s8),
                    const FolioDivider(),
                    const SizedBox(height: BistreSpacing.s8),
                    InkText(
                      l10n.t(L10nKey.chatToolsPrefillLabel),
                      role: InkTextRole.captionMeta,
                      color: theme.inkSecondary,
                    ),
                    const SizedBox(height: BistreSpacing.s4),
                    QuillInput(
                      controller: _prefillCtrl,
                      focusNode: _prefillFocus,
                      placeholder: l10n.t(L10nKey.chatToolsPrefillPlaceholder),
                      maxLines: 2,
                      compact: true,
                      submitOnEnter: false,
                      onSubmitted: () {},
                      onChanged: ctrl.setReplyPrefill,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.detail,
    required this.active,
  });

  final BistreUiIcon icon;
  final String label;
  final String? detail;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    return Row(
      children: [
        BistreIcon(
          icon,
          size: 13,
          color: active ? theme.statusOk : theme.inkMuted,
        ),
        const SizedBox(width: BistreSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkText(
                label,
                role: InkTextRole.captionMeta,
                color: theme.inkPrimary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              // A folder path keeps its own order in RTL.
              if (detail case final text?)
                OwnDirection(
                  text: text,
                  child: InkText(
                    text,
                    role: InkTextRole.captionMeta,
                    color: active ? theme.statusOk : theme.inkMuted,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
