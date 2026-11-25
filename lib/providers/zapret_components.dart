import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final zapretComponentsProvider =
    NotifierProvider<ZapretComponentsController, ZapretComponentState>(
      ZapretComponentsController.new,
    );

class ZapretComponentState {
  const ZapretComponentState(this.versions, {this.checking = false});
  final Map<String, String> versions;
  final bool checking;
}

class ZapretComponentsController extends Notifier<ZapretComponentState> {
  static const installed = {
    'Zapret2': 'v1.0.7',
    'Flowseal': '1.10.4',
    'Lua/BAT source': '8dd17fcbcca4',
  };
  static const _urls = {
    'Zapret2': 'https://api.github.com/repos/bol-van/zapret2/releases/latest',
    'Flowseal': 'https://api.github.com/repos/Flowseal/zapret-discord-youtube/releases/latest',
    'Lua/BAT source': 'https://api.github.com/repos/geliopat/zapret2-gui/commits/main',
  };

  @override
  ZapretComponentState build() {
    if (Platform.isWindows) {
      final timer = Timer.periodic(const Duration(hours: 24), (_) => unawaited(refresh()));
      ref.onDispose(timer.cancel);
      scheduleMicrotask(() => unawaited(refresh()));
    }
    return ZapretComponentState({
      for (final item in installed.entries)
        item.key: 'установлено ${item.value} · upstream не проверен',
    });
  }

  Future<void> refresh() async {
    if (!Platform.isWindows || !ref.mounted || state.checking) return;
    final versions = Map<String, String>.of(state.versions);
    state = ZapretComponentState(versions, checking: true);
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 15)));
    try {
      await Future.wait(_urls.entries.map((entry) async {
        try {
          final response = await dio.get<Map<String, dynamic>>(entry.value,
              options: Options(headers: const {'Accept': 'application/vnd.github+json'}));
          final value = response.data?[entry.key == 'Lua/BAT source' ? 'sha' : 'tag_name'];
          final upstream = value is String
              ? (entry.key == 'Lua/BAT source' && value.length >= 12 ? value.substring(0, 12) : value)
              : 'неизвестно';
          versions[entry.key] = 'установлено ${installed[entry.key]} · upstream $upstream';
        } catch (_) {
          versions[entry.key] = 'установлено ${installed[entry.key]} · проверка недоступна';
        }
      }));
    } finally {
      dio.close(force: true);
      if (ref.mounted) state = ZapretComponentState(Map.unmodifiable(versions));
    }
  }
}
