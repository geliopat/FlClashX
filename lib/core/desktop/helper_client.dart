import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/desktop_channel.dart';
import 'package:fl_clash/common/print.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:win32_registry/win32_registry.dart';

import 'core_manifest.dart';
import 'launcher.dart';
import 'model.dart';
import 'process_probe.dart';

/// [coreMismatch]: the Helper's hash of the Core on disk is not the bundled
/// manifest's, as when a packager strips the binary; reinstalling the Helper
/// cannot fix that.
enum HelperReadiness { ready, notReady, manifestMissing, coreMismatch }

final class HelperStartResponse {
  final String sessionId;
  final int pid;

  const HelperStartResponse({required this.sessionId, required this.pid});
}

final class HelperStopResponse {
  final bool stopped;

  const HelperStopResponse({required this.stopped});
}

final class HelperZapretStrategy {
  final String id;
  final String name;
  final String filename;
  final String description;
  final String engine;
  final String category;

  const HelperZapretStrategy({
    required this.id,
    required this.name,
    required this.filename,
    required this.description,
    required this.engine,
    required this.category,
  });

  factory HelperZapretStrategy.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('Zapret strategy must be an object');
    }
    final map = Map<String, Object?>.from(value);
    String field(String key) {
      final item = map[key];
      if (item is! String || item.isEmpty) {
        throw FormatException('Zapret strategy field $key is invalid');
      }
      return item;
    }
    final engine = field('engine');
    if (engine != 'winws' && engine != 'winws2') {
      throw const FormatException('Unsupported Zapret engine');
    }
    return HelperZapretStrategy(
      id: field('id'),
      name: field('name'),
      filename: field('filename'),
      description: field('description'),
      engine: engine,
      category: field('category'),
    );
  }
}

final class HelperZapretListInfo {
  final String filename;
  final int bytes;
  final int entries;
  final bool userManaged;

  const HelperZapretListInfo({
    required this.filename,
    required this.bytes,
    required this.entries,
    required this.userManaged,
  });

  factory HelperZapretListInfo.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Zapret list info must be an object');
    final map = Map<String, Object?>.from(value);
    final filename = map['filename'];
    final bytes = map['bytes'];
    final entries = map['entries'];
    final userManaged = map['userManaged'];
    if (filename is! String || bytes is! int || entries is! int || userManaged is! bool ||
        bytes < 0 || entries < 0) {
      throw const FormatException('Zapret list info fields are invalid');
    }
    return HelperZapretListInfo(
      filename: filename,
      bytes: bytes,
      entries: entries,
      userManaged: userManaged,
    );
  }
}

final class HelperZapretListContent {
  final String filename;
  final String content;

  const HelperZapretListContent({required this.filename, required this.content});
}

final class HelperZapretStatus {
  final bool running;
  final int? pid;
  final String? strategyId;
  final String? engine;
  final String? mode;
  final List<String> winDivertFilters;
  final List<String> processingLists;
  final int cleanedProcesses;

  const HelperZapretStatus({
    required this.running,
    required this.pid,
    this.strategyId,
    this.engine,
    this.mode,
    this.winDivertFilters = const [],
    this.processingLists = const [],
    this.cleanedProcesses = 0,
  });
}

final class HelperException implements Exception {
  final String code;
  final String message;
  final Object? details;

  const HelperException({
    required this.code,
    required this.message,
    this.details,
  });

  @override
  String toString() => 'HelperException($code, $message, $details)';
}

final class HelperClient {
  final Dio _dio;
  final String Function() _expectedHelperPath;
  final Future<String> Function() _readCoreSha256;
  final String Function() _baseUrl;
  String? _coreSha256Cache;

  HelperClient({
    Dio? dio,
    String Function()? expectedHelperPath,
    Future<String> Function()? readCoreSha256,
    String? baseUrl,
  }) : _dio = dio ?? _createDio(),
       _baseUrl = baseUrl == null ? _defaultBaseUrl : (() => baseUrl),
       _expectedHelperPath = expectedHelperPath ?? _defaultHelperPath,
       _readCoreSha256 = readCoreSha256 ?? _readBundledCoreSha256;

  // The bundled manifest.json is a fixed build artifact; a usable value is read
  // once. An empty result means it is unusable now, so the Helper is skipped.
  Future<String> _readCoreSha256Once() async {
    final cached = _coreSha256Cache;
    if (cached != null) {
      return cached;
    }
    String coreSha256;
    try {
      coreSha256 = await _readCoreSha256();
    } catch (_) {
      coreSha256 = '';
    }
    if (coreSha256.isNotEmpty) {
      _coreSha256Cache = coreSha256;
    }
    return coreSha256;
  }

  // The Helper protocol never leaves the machine; never route it through a
  // proxy. Linux carries it over a Unix socket the systemd unit owns, so the
  // authority in the URL is a placeholder the connection factory ignores.
  static Dio _createDio() {
    return Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.findProxy = (uri) => 'DIRECT';
          if (Platform.isLinux) {
            client.connectionFactory = (uri, proxyHost, proxyPort) {
              return Socket.startConnect(
                InternetAddress(
                  helperSocketPath,
                  type: InternetAddressType.unix,
                ),
                0,
              );
            };
          }
          return client;
        },
      );
  }

  String get baseUrl => _baseUrl();

  static String _defaultBaseUrl() {
    if (Platform.isLinux) {
      return 'http://$appHelperService';
    }
    final published = Platform.isWindows ? _readPublishedPort() : null;
    return 'http://$localhost:${helperPortFor(published: published, pre: isPreDesktopApp)}';
  }

  /// A 0.4.2 Helper on [helperPort] stops its Core for any session.
  @visibleForTesting
  static int helperPortFor({required int? published, required bool pre}) {
    if (published != null) {
      return published;
    }
    if (pre) {
      throw const HelperException(
        code: 'helperUnavailable',
        message: 'The Helper has not published its port',
      );
    }
    return helperPort;
  }

  static int? _readPublishedPort() {
    try {
      final key = LOCAL_MACHINE.open(helperPortKey);
      try {
        return key.getInt(helperPortValue);
      } finally {
        key.close();
      }
    } catch (_) {
      return null;
    }
  }

  static Future<String> _readBundledCoreSha256() async {
    return (await CoreManifest.readCoreSha256()) ?? '';
  }

  static p.Context get _pathContext {
    return p.Context(
      style: Platform.isWindows ? p.Style.windows : p.Style.posix,
    );
  }

  static String _defaultHelperPath() {
    final context = _pathContext;
    return context.join(
      context.dirname(Platform.resolvedExecutable),
      Platform.isWindows ? '$appHelperService.exe' : appHelperService,
    );
  }

  Future<HelperReadiness> readiness({
    Duration? timeout,
    bool logFailure = true,
  }) async {
    if (timeout != null && timeout <= Duration.zero) {
      return HelperReadiness.notReady;
    }
    final cancelToken = CancelToken();
    final timeoutTimer = timeout == null
        ? null
        : Timer(
            timeout,
            () => cancelToken.cancel('helper ping deadline exceeded'),
          );
    try {
      final coreSha256 = await _readCoreSha256Once();
      if (coreSha256.isEmpty) {
        _logPingFailure('Core manifest is missing or invalid', logFailure);
        return HelperReadiness.manifestMissing;
      }
      final response = await _dio.get<Object?>(
        '$baseUrl/ping',
        queryParameters: {'coreSha256': coreSha256},
        cancelToken: cancelToken,
        options: _options(ResponseType.plain, acceptAnyStatus: true),
      );
      return response.statusCode == HttpStatus.ok
          ? _readyFromOk(response, logFailure)
          : _notReadyFromPing(response, logFailure);
    } catch (error) {
      _logPingFailure('helper ping failed: $error', logFailure);
      return HelperReadiness.notReady;
    } finally {
      timeoutTimer?.cancel();
    }
  }

  HelperReadiness _readyFromOk(Response<Object?> response, bool logFailure) {
    final protocolVersion = response.headers.value(helperProtocolVersionHeader);
    final helperPath = response.data;
    if (helperPath is! String) {
      _logPingFailure('helper ping returned invalid response', logFailure);
      return HelperReadiness.notReady;
    }
    if (protocolVersion != helperProtocolVersion) {
      _logPingFailure('helper protocol mismatch: $protocolVersion', logFailure);
      return HelperReadiness.notReady;
    }
    final matches = _pathContext.equals(
      helperPath.trim(),
      _expectedHelperPath(),
    );
    if (!matches) {
      _logPingFailure('helper executable path mismatch', logFailure);
      return HelperReadiness.notReady;
    }
    return HelperReadiness.ready;
  }

  HelperReadiness _notReadyFromPing(
    Response<Object?> response,
    bool logFailure,
  ) {
    final statusCode = response.statusCode;
    final protocolVersion = response.headers.value(helperProtocolVersionHeader);
    if (statusCode == HttpStatus.conflict) {
      final code = _mapFrom(response.data)?['code'];
      if (code == 'coreSha256Mismatch') {
        _logPingFailure('Helper Core SHA256 mismatch', logFailure);
        return HelperReadiness.coreMismatch;
      }
      if (protocolVersion == helperProtocolVersion) {
        _logPingFailure(
          'helper could not access the Core executable',
          logFailure,
        );
        return HelperReadiness.notReady;
      }
      _logPingFailure(
        'helper returned an unrecognized conflict '
        '(protocol $protocolVersion)',
        logFailure,
      );
      return HelperReadiness.notReady;
    }
    _logPingFailure(
      'helper ping returned HTTP $statusCode '
      '(protocol $protocolVersion)',
      logFailure,
    );
    return HelperReadiness.notReady;
  }

  void _logPingFailure(String message, bool enabled) {
    if (enabled) {
      commonPrint.log(message, logLevel: LogLevel.warning);
    }
  }

  /// /start hashes the whole Core binary before spawning it, and Smart App
  /// Control adds a cloud reputation lookup inside CreateProcess; the ping
  /// budget cut those off as a transport error and hid the Helper's answer.
  static const startTimeout = Duration(seconds: 15);

  /// Covers the Helper's graceful-exit wait plus its forced kill, so a Core
  /// slow to tear down its TUN reports as stopped rather than as a transport error.
  static const stopTimeout = Duration(seconds: 6);

  Future<HelperStartResponse> start({
    required String address,
    required String sessionId,
  }) async {
    _validateSessionId(sessionId);
    try {
      final response = await _dio.post<Object?>(
        '$baseUrl/start',
        data: {'address': address, 'sessionId': sessionId},
        options: _options(ResponseType.json, receiveTimeout: startTimeout),
      );
      final data = _responseMap(response, operation: 'start');
      final returnedSession = data['sessionId'];
      final pid = data['pid'];
      if (returnedSession != sessionId || pid is! int || pid <= 0) {
        throw const HelperException(
          code: 'invalidResponse',
          message: 'Helper returned an invalid start response',
        );
      }
      return HelperStartResponse(
        sessionId: returnedSession as String,
        pid: pid,
      );
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapDioException(error, operation: 'start');
    } catch (error) {
      throw HelperException(
        code: 'transportError',
        message: 'Unable to start Core through Helper',
        details: error.toString(),
      );
    }
  }

  Future<HelperStopResponse> stop(String sessionId) async {
    _validateSessionId(sessionId);
    try {
      final response = await _dio.post<Object?>(
        '$baseUrl/stop',
        data: {'sessionId': sessionId},
        options: _options(ResponseType.json, receiveTimeout: stopTimeout),
      );
      return _parseStopResponse(response, sessionId);
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      final response = error.response;
      if (response?.statusCode == HttpStatus.conflict) {
        final data = _mapFrom(response?.data);
        final reason = data?['reason'];
        if (reason is String) {
          throw HelperException(
            code: reason,
            message: 'Helper refused to stop the requested Core session',
            details: data,
          );
        }
      }
      throw _mapDioException(error, operation: 'stop');
    } catch (error) {
      throw HelperException(
        code: 'transportError',
        message: 'Unable to stop Core through Helper',
        details: error.toString(),
      );
    }
  }

  /// Reads the built-in Zapret2/Flowseal strategy catalog from the Helper.
  Future<List<HelperZapretStrategy>> zapretStrategies() async {
    try {
      final response = await _dio.get<Object?>(
        '$baseUrl/zapret/strategies',
        options: _options(ResponseType.json, receiveTimeout: const Duration(seconds: 3)),
      );
      final value = response.data;
      if (value is! List || value.isEmpty) {
        throw HelperException(
          code: 'invalidResponse',
          message: 'Helper вернул пустой или некорректный список стратегий Zapret',
          details: value,
        );
      }
      try {
        final strategies = value
            .map(HelperZapretStrategy.fromJson)
            .toList(growable: false);
        final ids = strategies.map((item) => item.id).toSet();
        if (ids.length != strategies.length) {
          throw const FormatException('Duplicate Zapret strategy IDs');
        }
        return strategies;
      } on FormatException catch (error) {
        throw HelperException(
          code: 'invalidResponse',
          message: 'Helper вернул некорректный каталог стратегий Zapret',
          details: error.message,
        );
      }
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: 'strategies');
    } catch (error) {
      throw HelperException(
        code: 'transportError',
        message: 'Не удалось получить каталог стратегий Zapret через Helper',
        details: error.toString(),
      );
    }
  }

  /// Lists the editable, allow-listed Zapret text files.
  Future<List<HelperZapretListInfo>> zapretLists() async {
    try {
      final response = await _dio.get<Object?>(
        '$baseUrl/zapret/lists',
        options: _options(ResponseType.json, receiveTimeout: const Duration(seconds: 4)),
      );
      final value = response.data;
      if (value is! List) {
        throw HelperException(code: 'invalidResponse', message: 'Helper вернул некорректный список файлов Zapret', details: value);
      }
      return value.map(HelperZapretListInfo.fromJson).toList(growable: false);
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: 'lists');
    } catch (error) {
      throw HelperException(code: 'transportError', message: 'Не удалось получить списки Zapret', details: error.toString());
    }
  }

  Future<HelperZapretListContent> readZapretList(String filename) async {
    try {
      final response = await _dio.get<Object?>(
        '$baseUrl/zapret/lists/${Uri.encodeComponent(filename)}',
        options: _options(ResponseType.json, receiveTimeout: const Duration(seconds: 4)),
      );
      final data = _responseMap(response, operation: 'Zapret list');
      final returnedName = data['filename'];
      final content = data['content'];
      if (returnedName != filename || content is! String) {
        throw HelperException(code: 'invalidResponse', message: 'Helper вернул некорректное содержимое списка Zapret', details: data);
      }
      return HelperZapretListContent(filename: filename, content: content);
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: 'read list');
    } catch (error) {
      throw HelperException(code: 'transportError', message: 'Не удалось прочитать список Zapret', details: error.toString());
    }
  }

  Future<HelperZapretListInfo> writeZapretList(String filename, String content) async {
    try {
      final response = await _dio.put<Object?>(
        '$baseUrl/zapret/lists/${Uri.encodeComponent(filename)}',
        data: {'content': content},
        options: _options(ResponseType.json, receiveTimeout: const Duration(seconds: 8)),
      );
      final data = _responseMap(response, operation: 'Save Zapret list');
      return HelperZapretListInfo.fromJson(data);
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: 'save list');
    } catch (error) {
      throw HelperException(code: 'transportError', message: 'Не удалось сохранить список Zapret', details: error.toString());
    }
  }

  /// Reads the Helper-owned Zapret process, regardless of which engine the
  /// selected profile uses. The Helper keeps it in a kill-on-close Job Object.
  Future<HelperZapretStatus> zapretStatus() async {
    try {
      final response = await _dio.get<Object?>(
        '$baseUrl/zapret',
        options: _options(ResponseType.json, receiveTimeout: const Duration(seconds: 3)),
      );
      return _parseZapretResponse(response, operation: 'Zapret status');
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: 'status');
    } catch (error) {
      throw HelperException(
        code: 'transportError',
        message: 'Не удалось получить состояние Zapret через Helper',
        details: error.toString(),
      );
    }
  }

  Future<HelperZapretStatus> startZapret({required String strategyId, required String mode}) =>
      _zapretAction('start', operation: 'start', strategyId: strategyId, mode: mode);

  Future<HelperZapretStatus> stopZapret() =>
      _zapretAction('stop', operation: 'stop');

  Future<HelperZapretStatus> restartZapret({required String strategyId, required String mode}) =>
      _zapretAction('restart', operation: 'restart', strategyId: strategyId, mode: mode);

  Future<HelperZapretStatus> _zapretAction(
    String route, {
    required String operation,
    String? strategyId,
    String? mode,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        '$baseUrl/zapret/$route',
        data: strategyId == null
            ? null
            : {'strategyId': strategyId, 'mode': mode ?? 'fullBypass'},
        options: _options(
          ResponseType.json,
          receiveTimeout: operation == 'stop'
              ? stopTimeout
              : const Duration(seconds: 20),
        ),
      );
      return _parseZapretResponse(response, operation: 'Zapret $operation');
    } on HelperException {
      rethrow;
    } on DioException catch (error) {
      throw _mapZapretDioException(error, operation: operation);
    } catch (error) {
      throw HelperException(
        code: 'transportError',
        message: 'Не удалось выполнить операцию Zapret через Helper',
        details: error.toString(),
      );
    }
  }

  HelperZapretStatus _parseZapretResponse(
    Response<Object?> response, {
    required String operation,
  }) {
    final data = _responseMap(response, operation: operation);
    final running = data['running'];
    final pid = data['pid'];
    final cleaned = data['cleanedProcesses'] ?? 0;
    final strategyId = data['strategyId'];
    final engine = data['engine'];
    final mode = data['mode'];
    final filters = data['winDivertFilters'] ?? const [];
    final lists = data['processingLists'] ?? const [];
    if (running is! bool ||
        (pid != null && (pid is! int || pid <= 0)) ||
        cleaned is! int ||
        cleaned < 0 ||
        (strategyId != null && (strategyId is! String || strategyId.isEmpty)) ||
        (engine != null && engine != 'winws' && engine != 'winws2') ||
        (mode != null && mode != 'strictSplit' && mode != 'fullBypass') ||
        filters is! List || filters.any((item) => item is! String) ||
        lists is! List || lists.any((item) => item is! String) ||
        (running && (pid == null || strategyId == null || engine == null)) ||
        (!running && (pid != null || strategyId != null || engine != null))) {
      throw HelperException(
        code: 'invalidResponse',
        message: 'Helper вернул некорректное состояние Zapret',
        details: data,
      );
    }
    return HelperZapretStatus(
      running: running,
      pid: pid as int?,
      strategyId: strategyId as String?,
      engine: engine as String?,
      mode: mode as String?,
      winDivertFilters: filters.cast<String>().toList(growable: false),
      processingLists: lists.cast<String>().toList(growable: false),
      cleanedProcesses: cleaned,
    );
  }

  HelperException _mapZapretDioException(
    DioException error, {
    required String operation,
  }) {
    if (error.response?.statusCode == HttpStatus.notFound) {
      return const HelperException(
        code: 'zapretUnsupported',
        message: 'Служба Helper не поддерживает Zapret2. Перезапусти или обнови FlClashX, чтобы обновить службу.',
      );
    }
    return _mapDioException(error, operation: 'Zapret $operation');
  }

  HelperStopResponse _parseStopResponse(
    Response<Object?> response,
    String sessionId,
  ) {
    final data = _responseMap(response, operation: 'stop');
    final returnedSession = data['sessionId'];
    final stopped = data['stopped'];
    final reason = data['reason'];
    if (returnedSession != sessionId ||
        stopped is! bool ||
        (stopped && reason != null) ||
        (!stopped && reason != 'notRunning')) {
      throw const HelperException(
        code: 'invalidResponse',
        message: 'Helper returned an invalid stop response',
      );
    }
    return HelperStopResponse(stopped: stopped);
  }

  Map<String, Object?> _responseMap(
    Response<Object?> response, {
    required String operation,
  }) {
    if (response.statusCode != HttpStatus.ok) {
      throw HelperException(
        code: 'unexpectedStatus',
        message: 'Helper $operation returned HTTP ${response.statusCode}',
        details: response.data,
      );
    }
    final data = _mapFrom(response.data);
    if (data == null) {
      throw HelperException(
        code: 'invalidResponse',
        message: 'Helper returned an invalid $operation response',
        details: response.data,
      );
    }
    return data;
  }

  HelperException _mapDioException(
    DioException error, {
    required String operation,
  }) {
    final data = _mapFrom(error.response?.data);
    final code = data?['code'];
    final message = data?['message'];
    if (code is String && message is String) {
      return HelperException(
        code: code,
        message: message,
        details: data?['details'],
      );
    }
    return HelperException(
      code: 'transportError',
      message: 'Helper $operation request failed',
      details: error.toString(),
    );
  }

  Map<String, Object?>? _mapFrom(Object? data) {
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    if (data is! Map) {
      return null;
    }
    return Map<String, Object?>.from(data);
  }

  void _validateSessionId(String sessionId) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(sessionId)) {
      throw const HelperException(
        code: 'invalidSessionId',
        message: 'Core session ID must be 128-bit lowercase hexadecimal',
      );
    }
  }

  Options _options(
    ResponseType responseType, {
    bool acceptAnyStatus = false,
    Duration receiveTimeout = const Duration(seconds: 2),
  }) {
    return Options(
      responseType: responseType,
      connectTimeout: const Duration(milliseconds: 300),
      receiveTimeout: receiveTimeout,
      // The Helper reports readiness via non-2xx (400, 409, ...), so only
      // transport errors should surface as DioExceptions.
      validateStatus: acceptAnyStatus ? (_) => true : null,
    );
  }
}

final class HelperLauncher implements CoreProcessLauncher {
  final HelperClient client;
  final ProcessLivenessProbe livenessProbe;

  const HelperLauncher(this.client, {this.livenessProbe = isProcessAlive});

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    try {
      final response = await client.start(
        address: address,
        sessionId: sessionId,
      );
      return HelperCoreLease(
        sessionId: response.sessionId,
        pid: response.pid,
        client: client,
        livenessProbe: livenessProbe,
      );
    } catch (error, stackTrace) {
      try {
        await client.stop(sessionId);
      } catch (releaseError) {
        commonPrint.log(
          'Failed to release Helper session $sessionId after a start failure: '
          '${compactError(releaseError)}',
          logLevel: LogLevel.warning,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

// The Helper reports these codes before it spawns a Core, and /start releases
// the previously managed Core first, so no Helper-managed Core is left behind
// and a direct launch is safe to retry.
const _preSpawnHelperErrors = {'coreVerificationFailed', 'processLaunchFailed'};

final class FallbackCoreLauncher implements CoreProcessLauncher {
  final CoreProcessLauncher primary;
  final CoreProcessLauncher fallback;

  const FallbackCoreLauncher({required this.primary, required this.fallback});

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    try {
      return await primary.start(sessionId: sessionId, address: address);
    } on HelperException catch (error) {
      if (!_preSpawnHelperErrors.contains(error.code)) rethrow;
      commonPrint.log(
        'Helper could not start the Core ($error); '
        'falling back to direct Core',
        logLevel: LogLevel.warning,
      );
      return fallback.start(sessionId: sessionId, address: address);
    }
  }
}

typedef HelperReadinessProbe = Future<HelperReadiness> Function();

final class HelperLauncherResolver implements DesktopCoreLauncherResolver {
  final bool hasHelper;
  final CoreProcessLauncher directLauncher;
  final CoreProcessLauncher helperLauncher;
  final HelperReadinessProbe helperReady;

  const HelperLauncherResolver({
    required this.hasHelper,
    required this.directLauncher,
    required this.helperLauncher,
    required this.helperReady,
  });

  @override
  Future<CoreProcessLauncher> resolve() async {
    if (!hasHelper) return directLauncher;
    final readiness = await helperReady();
    if (readiness == HelperReadiness.ready) {
      return FallbackCoreLauncher(
        primary: helperLauncher,
        fallback: directLauncher,
      );
    }
    return directLauncher;
  }
}

const _unreachableHelperCodes = {'transportError', 'helperUnavailable'};

final class HelperCoreLease implements CoreProcessLease {
  @override
  final String sessionId;

  @override
  final int pid;

  final HelperClient _client;
  final ProcessLivenessProbe _livenessProbe;
  Future<CoreProcessStopResult>? _stopOperation;

  HelperCoreLease({
    required this.sessionId,
    required this.pid,
    required HelperClient client,
    ProcessLivenessProbe livenessProbe = isProcessAlive,
  }) : _client = client,
       _livenessProbe = livenessProbe;

  @override
  CoreProcessOwner get owner => CoreProcessOwner.helper;

  @override
  String? get crashHeadline => null;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    final stopOperation = _stopOperation;
    if (stopOperation != null) {
      return stopOperation;
    }
    final nextOperation = _stop().onError((
      Object error,
      StackTrace stackTrace,
    ) {
      _stopOperation = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _stopOperation = nextOperation;
    return nextOperation;
  }

  // A dead Helper takes its Core with it; the OS is then the only witness.
  Future<CoreProcessStopResult> _stop() async {
    final HelperStopResponse response;
    try {
      response = await _client.stop(sessionId);
    } on HelperException catch (error) {
      if (!_unreachableHelperCodes.contains(error.code) ||
          await _livenessProbe(pid)) {
        rethrow;
      }
      commonPrint.log(
        'Helper is unreachable and Core $pid has already exited; '
        'session $sessionId is released',
        logLevel: LogLevel.warning,
      );
      return const CoreProcessStopResult(stopped: false, exitConfirmed: true);
    }
    return CoreProcessStopResult(
      stopped: response.stopped,
      exitConfirmed: true,
    );
  }
}

final helperClient = HelperClient();
