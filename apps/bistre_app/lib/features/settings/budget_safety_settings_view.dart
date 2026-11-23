import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../design/bistre_controls.dart';
import '../../design/bistre_icons.dart';
import '../../design/bistre_theme.dart';
import '../../design/ink_primitives.dart';
import '../../l10n/bistre_localizations.dart';
import '../../l10n/l10n_keys.g.dart';
import '../shell/folio_controller.dart';

/// Safety & Budget Studio:
/// - Explicit Unlimited spending toggle (`walletDailyCeilingMicros == null`)
/// - Custom USD daily spending limit input + optional quick chips (`$1`, `$5`, `$25`, `$100`)
/// - Live today's Wallet Shield spend readout & progress bar
/// - Tool permissions, Local-first routing, and Stateless private requests
class BudgetSafetySettingsView extends StatefulWidget {
  const BudgetSafetySettingsView({super.key, required this.controller});

  final FolioController controller;

  @override
  State<BudgetSafetySettingsView> createState() =>
      _BudgetSafetySettingsViewState();
}

class _BudgetSafetySettingsViewState extends State<BudgetSafetySettingsView> {
  final TextEditingController _customAmountCtrl = TextEditingController();
  final FocusNode _customAmountFocus = FocusNode();

  static const List<(int, String)> _quickCaps = <(int, String)>[
    (1000000, r'$1.00'),
    (5000000, r'$5.00'),
    (25000000, r'$25.00'),
    (100000000, r'$100.00'),
  ];

  @override
  void initState() {
    super.initState();
    _syncAmountInput();
  }

  @override
  void dispose() {
    _customAmountCtrl.dispose();
    _customAmountFocus.dispose();
    super.dispose();
  }

  void _syncAmountInput() {
    final cap = widget.controller.settings.walletDailyCeilingMicros;
    if (cap != null) {
      _customAmountCtrl.text = FolioController.formatMicrosUsd(cap)
          .replaceFirst(r'$', '');
    } else if (_customAmountCtrl.text.isEmpty) {
      _customAmountCtrl.text = '10.00';
    }
  }

  void _applyCustomAmount() {
    final parsed = FolioController.parseUsdToMicros(_customAmountCtrl.text);
    if (parsed == null || parsed <= 0) return;
    _customAmountCtrl.text = FolioController.formatMicrosUsd(parsed)
        .replaceFirst(r'$', '');
    unawaited(
      widget.controller.updateSettings(
        widget.controller.settings.copyWith(walletDailyCeilingMicros: parsed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = BistreTheme.of(context);
    final l10n = BistreLocalizations.of(context);
    final ctrl = widget.controller;
    final s = ctrl.settings;
    final isUnlimited = s.isWalletUnlimited;
    final capMicros = s.walletDailyCeilingMicros;
    if (capMicros != null && !_customAmountFocus.hasFocus) {
      final synced = FolioController.formatMicrosUsd(capMicros)
          .replaceFirst(r'$', '');
      if (_customAmountCtrl.text != synced) {
        _customAmountCtrl.text = synced;
      }
    }
    final dailySpend = ctrl.walletDailySpendMicros;
    final spentStr = FolioController.formatMicrosUsd(dailySpend);
    final capStr = capMicros != null
        ? FolioController.formatMicrosUsd(capMicros)
        : l10n.t(L10nKey.settingsBudgetUnlimited);
    final ratio = (capMicros != null && capMicros > 0)
        ? (dailySpend / capMicros).clamp(0.0, 1.0)
        : 0.0;
    final spendBadgeLabel = isUnlimited
        ? l10n.t(L10nKey.settingsBudgetUnlimited)
        : '$spentStr / $capStr';
    final unlimitedSummary =
        '${l10n.t(L10nKey.settingsBudgetUnlimitedBadge)} ($spentStr)';

    return SingleChildScrollView(
      padding: const EdgeInsetsDirectional.fromSTEB(28, 22, 28, 40),
      child: Align(
        alignment: AlignmentDirectional.topStart,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Live Wallet Shield Spend Card
              FolioSurface(
                tone: FolioTone.elevated,
                padding: const EdgeInsetsDirectional.all(20),
                borderRadius: 14,
                boxShadow: theme.cardShadow,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        BistreIcon(
                          BistreUiIcon.shield,
                          size: 16,
                          color: theme.accentBrass,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkText(
                            l10n.t(L10nKey.settingsBudgetTodaySpend),
                            role: InkTextRole.titleMedium,
                          ),
                        ),
                        WaxSealBadge(
                          label: spendBadgeLabel,
                          status: isUnlimited
                              ? WaxSealStatus.ok
                              : (ratio >= 0.9
                                    ? WaxSealStatus.error
                                    : WaxSealStatus.ok),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (isUnlimited)
                      InkText(
                        unlimitedSummary,
                        role: InkTextRole.bodyCompact,
                        color: theme.inkSecondary,
                      )
                    else ...[
                      SizedBox(
                        height: 6,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: ColoredBox(
                            color: theme.bgSurface,
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: FractionallySizedBox(
                                widthFactor: ratio,
                                heightFactor: 1,
                                child: SizedBox.expand(
                                  child: ColoredBox(
                                    color: ratio >= 0.9
                                        ? theme.statusErr
                                        : theme.accentBrass,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      InkText(
                        l10n.t(
                          L10nKey.settingsTrustSpendToday,
                          <String, Object?>{'spent': spentStr, 'limit': capStr},
                        ),
                        role: InkTextRole.captionMeta,
                        color: theme.inkMuted,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: BistreSpacing.s24),

              // Daily Spending Limit Controls
              BistreSettingsSection(
                title: l10n.t(L10nKey.settingsTrustCeilingHeading),
                children: [
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsBudgetUnlimitedToggle),
                    description: l10n.t(L10nKey.settingsBudgetUnlimitedBadge),
                    trailing: BistreSwitch(
                      value: isUnlimited,
                      semanticsLabel: l10n.t(
                        L10nKey.settingsBudgetUnlimitedToggle,
                      ),
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onChanged: (unlimited) {
                        if (unlimited) {
                          unawaited(
                            ctrl.updateSettings(
                              s.copyWith(setWalletUnlimited: true),
                            ),
                          );
                        } else {
                          final parsed =
                              FolioController.parseUsdToMicros(
                                _customAmountCtrl.text,
                              ) ??
                              10000000;
                          final safeCap = parsed > 0 ? parsed : 10000000;
                          _customAmountCtrl.text =
                              FolioController.formatMicrosUsd(safeCap)
                                  .replaceFirst(r'$', '');
                          unawaited(
                            ctrl.updateSettings(
                              s.copyWith(walletDailyCeilingMicros: safeCap),
                            ),
                          );
                        }
                      },
                    ),
                  ),
                  if (!isUnlimited)
                    BistreSettingRow(
                      label: l10n.t(L10nKey.settingsBudgetCustomAmount),
                      bottom: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              SizedBox(
                                width: 156,
                                child: QuillInput(
                                  controller: _customAmountCtrl,
                                  focusNode: _customAmountFocus,
                                  placeholder: _kDefaultAmountHint,
                                  maxLines: 1,
                                  submitOnEnter: false,
                                  onSubmitted: _applyCustomAmount,
                                ),
                              ),
                              const SizedBox(width: 8),
                              EngravedButton(
                                label: l10n.t(
                                  L10nKey.settingsBudgetApplyAmount,
                                ),
                                primary: true,
                                compact: true,
                                onPressed: _applyCustomAmount,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final preset in _quickCaps)
                                InkChip(
                                  label: preset.$2,
                                  selected: capMicros == preset.$1,
                                  onSelected: () {
                                    _customAmountCtrl.text = preset.$2
                                        .replaceFirst(r'$', '');
                                    unawaited(
                                      ctrl.updateSettings(
                                        s.copyWith(
                                          walletDailyCeilingMicros: preset.$1,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: BistreSpacing.s24),

              // Model prices (public price lists; Spec 06)
              BistreSettingsSection(
                title: l10n.t(L10nKey.settingsPricesHeading),
                children: [
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsPricesAutoRefresh),
                    description: l10n.t(L10nKey.settingsPricesAutoRefreshHint),
                    trailing: BistreSwitch(
                      value: s.pricingAutoRefresh,
                      semanticsLabel: l10n.t(L10nKey.settingsPricesAutoRefresh),
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onChanged: (on) => unawaited(
                        ctrl.updateSettings(s.copyWith(pricingAutoRefresh: on)),
                      ),
                    ),
                  ),
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsPricesRefreshNow),
                    trailing: EngravedButton(
                      label: l10n.t(L10nKey.settingsPricesRefreshNow),
                      compact: true,
                      onPressed: () => unawaited(ctrl.refreshPrices()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: BistreSpacing.s24),

              // Permissions & Privacy
              BistreSettingsSection(
                title: l10n.t(L10nKey.settingsTrustPresetHeading),
                children: [
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsTrustPresetHeading),
                    trailing: BistreSegmentedControl<String>(
                      selected: s.trustPreset,
                      onSelected: (v) => unawaited(
                        ctrl.updateSettings(s.copyWith(trustPreset: v)),
                      ),
                      options: <BistreSegmentedOption<String>>[
                        BistreSegmentedOption<String>(
                          value: 'parchment_safe',
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
                  ),
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsTrustLocalFirst),
                    trailing: BistreSwitch(
                      value: s.walletLocalFirst,
                      semanticsLabel: l10n.t(L10nKey.settingsTrustLocalFirst),
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onChanged: (v) => unawaited(
                        ctrl.updateSettings(s.copyWith(walletLocalFirst: v)),
                      ),
                    ),
                  ),
                  BistreSettingRow(
                    label: l10n.t(L10nKey.settingsTrustStateless),
                    trailing: BistreSwitch(
                      value: s.providerStatelessDefault,
                      semanticsLabel: l10n.t(L10nKey.settingsTrustStateless),
                      reduceMotionOverride: ctrl.reduceMotionOverride,
                      onChanged: (v) => unawaited(
                        ctrl.updateSettings(
                          s.copyWith(providerStatelessDefault: v),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static const String _kDefaultAmountHint = '10.00';
}
