import 'package:flutter/widgets.dart';

import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';

/// Below this window width the composer is the phone form: one row (+, ring, field, action).
const double kComposerPhoneWidth = 720;

/// Phone composer: the + that opens and closes the tray of occasional controls (attach,
/// tools, thinking, live voice). [marked] puts a small dot on it while a tray setting is not
/// at its default, so that state stays visible with the tray closed.
class ComposerTrayToggle extends StatelessWidget {
  const ComposerTrayToggle({
    super.key,
    required this.open,
    required this.marked,
    required this.onToggle,
  });

  final bool open;
  final bool marked;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        BistreIconButton(
          icon: open ? BistreUiIcon.close : BistreUiIcon.plus,
          size: 16,
          dimension: 36,
          active: open,
          semanticsLabel: l10n.t(
            open ? L10nKey.composerToolsHide : L10nKey.composerToolsShow,
          ),
          onPressed: onToggle,
        ),
        if (marked && !open)
          PositionedDirectional(
            top: 6,
            end: 6,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.accentBrass,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(dimension: 6),
              ),
            ),
          ),
      ],
    );
  }
}

/// Phone composer: the one action at the end of the row. Empty field: voice (dictate).
/// Text typed: send (queue while a reply runs). A reply running: stop, plus queue once
/// there is text.
class ComposerSendActions extends StatelessWidget {
  const ComposerSendActions({
    super.key,
    required this.streaming,
    required this.hasText,
    required this.dictating,
    required this.onSend,
    required this.onStop,
    required this.onDictate,
  });

  final bool streaming;
  final bool hasText;
  final bool dictating;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onDictate;

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final send = BistreIconButton(
      icon: BistreUiIcon.send,
      size: 16,
      dimension: 36,
      active: true,
      color: theme.accentWax,
      semanticsLabel: l10n.t(
        streaming ? L10nKey.composerQueueAction : L10nKey.shellComposerSend,
      ),
      onPressed: onSend,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (streaming)
          BistreIconButton(
            icon: BistreUiIcon.stop,
            size: 16,
            dimension: 36,
            semanticsLabel: l10n.t(L10nKey.chatActionStop),
            onPressed: onStop,
          ),
        if (hasText)
          send
        else if (!streaming)
          BistreIconButton(
            icon: BistreUiIcon.mic,
            size: 16,
            dimension: 36,
            active: dictating,
            color: dictating ? theme.accentWax : theme.inkSecondary,
            semanticsLabel: l10n.t(L10nKey.composerVoiceDictate),
            onPressed: onDictate,
          ),
      ],
    );
  }
}
