import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../style.dart';
import 'card.dart';
import 'network_takeover.dart';
import 'zapret_strategy_sheet.dart';

/// The `zapret` item from `flclashx-widgets`.
/// ProviderMode uses it for latency diagnostics; the regular dashboard uses
/// the native Zapret on/off card.
class ZapretWidgetCard extends ConsumerWidget {
  const ZapretWidgetCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final providerMode = ref.watch(providerModeProvider);
    if (providerMode) {
      final enabled = ref.watch(
        currentProfileProvider.select(
          (profile) =>
              profile?.headers.dashboardWidgets?.contains(DashboardWidget.zapret) ??
              false,
        ),
      );
      return enabled
          ? const ZapretDiagnosticsCard()
          : const SizedBox.shrink();
    }
    return const ZapretTile();
  }
}

class ZapretDiagnosticsCard extends ConsumerWidget {
  const ZapretDiagnosticsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretDiagnosticsProvider);
    final zapret = ref.watch(zapretControllerProvider);
    String? strategyName(String? id) {
      for (final item in zapret.strategies) {
        if (item.id == id) return item.name;
      }
      return null;
    }
    final displayedStrategyName = strategyName(
      zapret.running ? zapret.activeStrategyId : zapret.selectedStrategyId,
    );
    final colors = DashboardColors.of(context);
    return DashboardCard(
      semanticLabel: AppLocalizations.of(context).forkHttpsLatency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.latency,
            title: AppLocalizations.of(context).forkHttpsLatency,
            trailing: [
              DashboardIconButton(
                glyph: AppGlyphs.filter,
                tooltip: AppLocalizations.of(context).forkChooseStrategy,
                onPressed: () => showZapretStrategiesSheet(context),
              ),
              DashboardIconButton(
                glyph: AppGlyphs.latency,
                tooltip: AppLocalizations.of(context).forkCheckNow,
                onPressed: () =>
                    ref.read(zapretDiagnosticsProvider.notifier).refresh(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.tone,
              borderRadius: BorderRadius.circular(DashboardCorner.tab),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      zapret.running ? AppLocalizations.of(context).forkActiveStrategy : AppLocalizations.of(context).forkSelectedStrategy,
                      style: AppTextStyle.footnote.of(context).copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      displayedStrategyName ?? (zapret.running ? AppLocalizations.of(context).forkUndefined : AppLocalizations.of(context).forkNotSelected),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: AppTextStyle.subheadline.of(context, emphasized: true),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              final groupWidth = compact
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 8) / 2;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: groupWidth,
                    child: _ProbeGroup(
                      title: 'YouTube / GoogleVideo',
                      first: ZapretProbeTarget.youtube,
                      second: ZapretProbeTarget.googleVideo,
                      state: state,
                      background: colors.tone,
                    ),
                  ),
                  SizedBox(
                    width: groupWidth,
                    child: _ProbeGroup(
                      title: 'Discord Voice / Gateway',
                      first: ZapretProbeTarget.discordGateway,
                      second: ZapretProbeTarget.discordVoice,
                      state: state,
                      background: colors.tone,
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
}

class _ProbeGroup extends StatelessWidget {
  const _ProbeGroup({
    required this.title,
    required this.first,
    required this.second,
    required this.state,
    required this.background,
  });

  final String title;
  final ZapretProbeTarget first;
  final ZapretProbeTarget second;
  final ZapretDiagnosticsState state;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(DashboardCorner.tab),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: AppTextStyle.footnote
                  .of(context, emphasized: true)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            _ProbeLine(target: first, result: state.resultOf(first)),
            const SizedBox(height: 7),
            _ProbeLine(target: second, result: state.resultOf(second)),
          ],
        ),
      ),
    );
  }
}

class _ProbeLine extends StatelessWidget {
  const _ProbeLine({required this.target, required this.result});

  final ZapretProbeTarget target;
  final ZapretProbeResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final statusColor = switch (result.status) {
      ZapretProbeStatus.operational => scheme.success,
      ZapretProbeStatus.degraded => scheme.warning,
      ZapretProbeStatus.blocked => scheme.error,
      ZapretProbeStatus.checking => scheme.onSurfaceVariant,
    };
    final statusLabel = switch (result.status) {
      ZapretProbeStatus.operational => AppLocalizations.of(context).forkRunning,
      ZapretProbeStatus.degraded => AppLocalizations.of(context).forkSlow,
      ZapretProbeStatus.blocked => AppLocalizations.of(context).forkNoReply,
      ZapretProbeStatus.checking => AppLocalizations.of(context).forkChecking,
    };
    final value = result.latencyMs == null
        ? statusLabel
        : '${result.latencyMs} ms';
    return Tooltip(
      message: [
        target.url,
        if (result.message != null) result.message!,
        if (result.httpStatus != null) 'HTTP ${result.httpStatus}',
      ].join('\n'),
      child: Semantics(
        label: target.label,
        value: value,
        liveRegion: true,
        child: Row(
          children: [
            Expanded(
              child: Text(
                target.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.subheadline.of(context),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              value,
              style: DashboardText.figure(
                context,
                AppTextStyle.subheadline,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
