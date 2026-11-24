import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final zapretDiagnosticsProvider =
    NotifierProvider<ZapretDiagnosticsController, ZapretDiagnosticsState>(
      ZapretDiagnosticsController.new,
    );

enum ZapretProbeStatus { checking, operational, degraded, blocked }

enum ZapretProbeTarget {
  youtube(
    'YouTube',
    'www.youtube.com',
    'https://www.youtube.com/generate_204',
  ),
  googleVideo(
    'GoogleVideo',
    'redirector.googlevideo.com',
    'https://redirector.googlevideo.com/report_mapping',
  ),
  discordGateway(
    'Discord Gateway',
    'gateway.discord.gg',
    'https://discord.com/api/v10/gateway',
  ),
  discordVoice(
    'Discord Voice API',
    'discord.media',
    'https://discord.com/api/v10/voice/regions',
  );

  const ZapretProbeTarget(this.label, this.host, this.url);

  final String label;
  final String host;
  final String url;
}

class ZapretProbeResult {
  const ZapretProbeResult({
    this.status = ZapretProbeStatus.checking,
    this.latencyMs,
    this.httpStatus,
    this.message,
  });

  final ZapretProbeStatus status;
  final int? latencyMs;
  final int? httpStatus;
  final String? message;
}

/// Uses the same 450 ms threshold and HTTP success handling as zapret2-gui.
ZapretProbeResult classifyZapretProbe({
  required int? statusCode,
  required int latencyMs,
}) {
  if (statusCode == null) {
    return const ZapretProbeResult(
      status: ZapretProbeStatus.blocked,
      message: 'Сервер не ответил',
    );
  }
  final accepted = statusCode >= 200 && statusCode < 300;
  final status = !accepted || latencyMs > 450
      ? ZapretProbeStatus.degraded
      : ZapretProbeStatus.operational;
  final message = !accepted
      ? 'HTTP $statusCode'
      : latencyMs > 450
          ? 'Высокая задержка'
          : 'Соединение доступно';
  return ZapretProbeResult(
    status: status,
    latencyMs: latencyMs,
    httpStatus: statusCode,
    message: message,
  );
}

class ZapretDiagnosticsState {
  const ZapretDiagnosticsState(this.results);

  final Map<ZapretProbeTarget, ZapretProbeResult> results;

  ZapretProbeResult resultOf(ZapretProbeTarget target) =>
      results[target] ?? const ZapretProbeResult();
}

class ZapretDiagnosticsController extends Notifier<ZapretDiagnosticsState> {
  static const _pollInterval = Duration(seconds: 30);
  static const _dnsTimeout = Duration(seconds: 2);
  static const _connectTimeout = Duration(milliseconds: 2500);
  static const _requestTimeout = Duration(milliseconds: 3500);

  final Dio _client = Dio(
    BaseOptions(
      connectTimeout: _connectTimeout,
      receiveTimeout: _requestTimeout,
      sendTimeout: _connectTimeout,
      responseType: ResponseType.plain,
      followRedirects: true,
      maxRedirects: 3,
      validateStatus: (status) =>
          status != null && status >= 100 && status < 600,
      headers: const {
        'Cache-Control': 'no-cache',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
      },
    ),
  );

  Timer? _poller;
  var _refreshing = false;

  @override
  ZapretDiagnosticsState build() {
    ref.onDispose(() {
      _poller?.cancel();
      _client.close(force: true);
    });
    if (Platform.isWindows) {
      scheduleMicrotask(() {
        if (ref.mounted) unawaited(refresh());
      });
      _poller = Timer.periodic(_pollInterval, (_) {
        if (ref.mounted) unawaited(refresh());
      });
    }
    return ZapretDiagnosticsState({
      for (final target in ZapretProbeTarget.values)
        target: const ZapretProbeResult(),
    });
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || !ref.mounted || _refreshing) return;
    _refreshing = true;
    try {
      final measured = await Future.wait(
        ZapretProbeTarget.values.map(_measure),
      );
      if (!ref.mounted) return;
      state = ZapretDiagnosticsState({
        for (final item in measured) item.$1: item.$2,
      });
    } finally {
      _refreshing = false;
    }
  }

  Future<(ZapretProbeTarget, ZapretProbeResult)> _measure(
    ZapretProbeTarget target,
  ) async {
    // Match zapret2-gui: DNS is a separate phase and is not added to the
    // displayed HTTPS latency.
    try {
      final addresses = await InternetAddress.lookup(target.host).timeout(
        _dnsTimeout,
      );
      if (addresses.isEmpty) {
        return (
          target,
          const ZapretProbeResult(
            status: ZapretProbeStatus.blocked,
            message: 'DNS: адрес не найден',
          ),
        );
      }
    } catch (error) {
      return (
        target,
        ZapretProbeResult(
          status: ZapretProbeStatus.blocked,
          message: 'Ошибка DNS: $error',
        ),
      );
    }

    final stopwatch = Stopwatch()..start();
    try {
      final response = await _client.get<String>(target.url);
      stopwatch.stop();
      return (
        target,
        classifyZapretProbe(
          statusCode: response.statusCode,
          latencyMs: stopwatch.elapsedMilliseconds,
        ),
      );
    } catch (error) {
      stopwatch.stop();
      final message = error is DioException
          ? error.message ?? error.type.name
          : error.toString();
      return (
        target,
        ZapretProbeResult(
          status: ZapretProbeStatus.blocked,
          message: message,
        ),
      );
    }
  }
}
