import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/flclashz_upstream_versions.dart';
import 'package:fl_clash/core/desktop/core_release_selection.dart';
import 'package:fl_clash/core/desktop/helper_client.dart';
import 'package:fl_clash/features/update/core_release_manifest.dart';
import 'package:fl_clash/features/update/core_release_updater.dart';
import 'package:fl_clash/features/update/download.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// Windows only. Checking downloads the small signed manifest, not the EXE.
/// Activation and rollback belong to the existing exclusive restart worker.
class CoreReleaseSection extends ConsumerStatefulWidget {
  const CoreReleaseSection({super.key});

  @override
  ConsumerState<CoreReleaseSection> createState() => _CoreReleaseSectionState();
}

class _CoreReleaseSectionState extends ConsumerState<CoreReleaseSection> {
  bool _busy = false;
  String? _status;
  CancelToken? _downloadCancel;

  String _tr(String ru, String en) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

  CoreReleaseUpdater _updater() => CoreReleaseUpdater(
    downloader: UpdateDownloader(
      root: () async => Directory(p.join(await appPath.homeDirPath, 'core-update-downloads')),
    ),
    helper: helperClient,
  );

  String get _bundledVersion => coreVersionDefine.isNotEmpty
      ? coreVersionDefine
      : bundledMihomoVersion;

  Future<void> _run(Future<void> Function() work) async {
    if (_busy || !mounted) return;
    setState(() { _busy = true; _status = null; });
    try {
      await work();
    } catch (error) {
      if (mounted) setState(() => _status = _tr('Ошибка: $error', 'Error: $error'));
    } finally {
      if (mounted) setState(() { _busy = false; _downloadCancel = null; });
    }
  }

  Future<void> _check() => _run(() async {
    final action = ref.read(coreActionProvider.notifier);
    final updater = _updater();
    final token = _downloadCancel = CancelToken();
    final offer = await updater.check(cancelToken: token);
    final journal = await coreReleaseSelection.read();
    if (!mounted) return;
    final bundled = _bundledVersion.startsWith('v') ? _bundledVersion : 'v$_bundledVersion';
    final minimum = CoreReleaseVersion.parse('$bundled-z.1');
    final version = offer.manifest.version;
    // The first published package predates the new adapter RPCs. Its
    // engine is identical, but installing it would remove client features.
    if (version.compareTo(CoreReleaseVersion.parse(minimumIndependentCoreVersion)) < 0) {
      setState(() => _status = _tr('Для этой версии клиента требуется новый адаптер ядра', 'This client requires a newer core adapter'));
      return;
    }
    if (version.compareTo(minimum) < 0 ||
        (journal.current != null && version.compareTo(journal.current!.version) <= 0)) {
      setState(() => _status = _tr('Обновлений ядра нет', 'No core updates'));
      return;
    }
    final approved = await dialogs.showMessage(
      context: context,
      title: _tr('Обновить ядро', 'Update core'),
      message: TextSpan(text: _tr(
        'Версия: ${version.value}. После проверки подписи и файла ядро будет перезапущено. При ошибке будет восстановлена предыдущая версия.',
        'Version: ${version.value}. After signature and file verification the core will restart. A failed activation restores the previous version.',
      )),
      cancelable: true,
    );
    if (approved != true || !mounted) return;
    PreparedCoreRelease? prepared;
    try {
      prepared = await updater.downloadOffer(
        offer,
        cancelToken: token,
        onProgress: (received, total) {
          if (mounted && total != null && total > 0) {
            final percent = (received * 100 ~/ total).clamp(0, 100);
            setState(() => _status = _tr('Загрузка: $percent%', 'Downloading: $percent%'));
          }
        },
      );
      if (!mounted) return;
      setState(() => _status = _tr('Проверка и установка…', 'Verifying and installing…'));
      // Stage first. An invalid package never stops the active core.
      final manifest = await updater.stage(prepared);
      if (!mounted) return;
      final ok = await action.activateCoreRelease(manifest);
      if (mounted) setState(() => _status = ok
          ? _tr('Установлено: ${manifest.version.value}', 'Installed: ${manifest.version.value}')
          : _tr('Обновление не применено', 'Update not applied'));
    } finally {
      await prepared?.dispose();
    }
  });

  Future<void> _rollback() => _run(() async {
    final action = ref.read(coreActionProvider.notifier);
    final state = await coreReleaseSelection.read();
    if (!mounted) return;
    if (!state.hasPrevious) {
      setState(() => _status = _tr('Нет предыдущей версии', 'No previous version'));
      return;
    }
    final target = state.previous?.version.value ?? _bundledVersion;
    final approved = await dialogs.showMessage(
      context: context,
      title: _tr('Восстановить предыдущее ядро', 'Restore previous core'),
      message: TextSpan(text: target),
      cancelable: true,
    );
    if (approved != true || !mounted) return;
    final ok = await action.restorePreviousCoreRelease();
    if (mounted) setState(() => _status = ok
        ? _tr('Восстановлено: $target', 'Restored: $target')
        : _tr('Восстановление не выполнено', 'Restore failed'));
  });

  @override
  void dispose() {
    _downloadCancel?.cancel('Core update view closed');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = _busy || safeModeBuild || ref.watch(safeModeProvider);
    return generateSection(
      title: _tr('Независимое ядро FlClashZ', 'Independent FlClashZ core'),
      items: [
        ListItem(
          leading: const GlyphIcon(AppGlyphs.cpu),
          title: Text(_tr('Проверить обновление ядра', 'Check core updates')),
          subtitle: Text(_status ?? _tr('Отдельно от приложения', 'Separate from app updates')),
          onTap: disabled ? null : _check,
        ),
        ListItem(
          leading: const GlyphIcon(AppGlyphs.sync),
          title: Text(_tr('Предыдущая версия ядра', 'Previous core version')),
          onTap: disabled ? null : _rollback,
        ),
      ],
    );
  }
}
