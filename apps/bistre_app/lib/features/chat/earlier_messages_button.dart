import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Top of a partly loaded chat: loads the page before the first message shown, then keeps
/// that message in view so the reader does not lose their place.
class EarlierMessagesButton extends StatelessWidget {
  const EarlierMessagesButton({super.key, required this.controller});

  final FolioController controller;

  Future<void> _load() async {
    final anchor = controller.visibleBranchNodes.firstOrNull?.id;
    if (!await controller.loadEarlierNodes() || anchor == null) return;
    controller.revealRequest
      ..value = null
      ..value = anchor;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = BistreLocalizations.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.symmetric(
        vertical: BistreSpacing.s12,
      ),
      child: Center(
        child: EngravedButton(
          label: l10n.t(L10nKey.chatShowEarlierMessages),
          compact: true,
          onPressed: () => unawaited(_load()),
        ),
      ),
    );
  }
}
