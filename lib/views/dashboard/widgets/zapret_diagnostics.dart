import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../style.dart';
import 'card.dart';

class ZapretDiagnosticsCard extends ConsumerWidget {
  const ZapretDiagnosticsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretDiagnosticsProvider);
    final colors = DashboardColors.of(context);
    return DashboardCard(
      semanticLabel: 'Сетевые задержки YouTube, GoogleVideo и Discord',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.speed,
            title: 'Сетевые задержки · HTTPS',
            trailing: [
              DashboardIconButton(
                glyph: AppGlyphs.refresh,
                tooltip: 'Проверить сейчас',
                onPressed: () =>
                    ref.read(zapretDiagnosticsProvider.notifier).refresh(),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
                      title: 'Discord Gateway / Voice API',
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
      ZapretProbeStatus.operational => 'Работает',
      ZapretProbeStatus.degraded => 'Замедлено',
      ZapretProbeStatus.blocked => 'Нет ответа',
      ZapretProbeStatus.checking => 'Проверка',
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
