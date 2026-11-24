import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class ZapretStatusButton extends ConsumerWidget {
  const ZapretStatusButton({super.key});

  Future<void> _restart(BuildContext context, WidgetRef ref) async {
    final status = ref.read(zapretControllerProvider);
    if (status.busy || !status.available) return;
    final message = status.running
        ? 'Перезапустить Zapret? Перед запуском будут проверены и завершены зависшие процессы winws2.exe, winws.exe и winws2-split.exe.'
        : 'Запустить Zapret2? Перед запуском будут проверены и завершены зависшие процессы winws2.exe, winws.exe и winws2-split.exe.';
    final confirmed = await dialogs.showMessage(
      title: 'Zapret',
      message: TextSpan(text: message),
      confirmText: status.running ? 'Перезапустить' : 'Запустить',
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(zapretControllerProvider.notifier).restart();
    } catch (error) {
      dialogs.showNotifier(
        error is HelperException ? error.message : error.toString(),
        level: MessageLevel.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretControllerProvider);
    final icon = state.busy
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : ZapretMark(running: state.running);
    const style = ElasticPress.buttonStyle;
    final iconOnly = state.running || ViewScope.isMobileOf(context);
    return Tooltip(
      message: state.error ?? 'Zapret',
      child: FadeScaleBox(
        alignment: Alignment.centerRight,
        child: iconOnly
            ? IconButton.filled(
                style: style,
                onPressed: state.busy || !state.available
                    ? null
                    : () => _restart(context, ref),
                icon: icon,
              )
            : FilledButton.icon(
                onPressed: state.busy || !state.available
                    ? null
                    : () => _restart(context, ref),
                style: style,
                icon: icon,
                label: Text(state.busy
                    ? 'Запуск...'
                    : state.running
                        ? 'Zapret включён'
                        : 'Zapret выключен'),
              ),
      ),
    );
  }
}


/// The Zapret mark uses the same compact footprint as the Core heartbeat.
class ZapretMark extends StatelessWidget {
  const ZapretMark({super.key, required this.running, this.color});

  final bool running;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 18,
      child: Center(
        child: Text(
          'Z',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            height: 1,
            fontWeight: FontWeight.w800,
            color: color ?? (running
                ? context.colorScheme.primary
                : context.colorScheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}


/// The Zapret on/off control beside ProviderConnectButton on ProviderMode.
class ProviderZapretButton extends ConsumerWidget {
  const ProviderZapretButton({super.key});

  static const _duration = Duration(milliseconds: 300);

  Future<void> _toggle(WidgetRef ref, ZapretState state) async {
    if (state.busy || !state.available) return;
    try {
      await ref
          .read(zapretControllerProvider.notifier)
          .setEnabled(!state.running);
    } catch (error) {
      dialogs.showNotifier(
        error is HelperException ? error.message : error.toString(),
        level: MessageLevel.error,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(zapretControllerProvider);
    final scheme = context.colorScheme;
    final duration = context.motionDuration(_duration);
    final label = state.running ? 'Остановить Zapret' : 'Запустить Zapret';
    return Tooltip(
      message: state.error ?? label,
      child: Semantics(
        button: true,
        label: label,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: state.running ? 1 : 0),
            duration: duration,
            curve: Curves.easeInOut,
            builder: (context, progress, _) {
              final ink = Color.lerp(
                scheme.onPrimary,
                scheme.primary,
                progress,
              )!;
              return FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.primary.withValues(
                    alpha: 1 - progress,
                  ),
                  foregroundColor: ink,
                  side: BorderSide(
                    color: scheme.primary.withValues(alpha: progress),
                    width: 1.5,
                  ),
                ),
                onPressed: state.busy || !state.available
                    ? null
                    : () => _toggle(ref, state),
                child: state.busy
                    ? SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: ink,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 8,
                        children: [
                          ZapretMark(running: state.running, color: ink),
                          Text(
                            'Zapret',
                            style: AppTextStyle.subheadline.of(
                              context,
                              emphasized: true,
                            ),
                          ),
                        ],
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
