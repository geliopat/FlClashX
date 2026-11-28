import 'package:fl_clash/providers/zapret.dart';

/// A deterministic idle service for widget tests that do not launch engines.
/// The Windows linked lifecycle and LocalSystem tests cover real integration.
class IdleZapret extends ZapretController {
  @override
  ZapretState build() => const ZapretState();

  @override
  Future<void> startAlongsideMihomo({bool force = false}) async {}

  @override
  Future<bool> stopAlongsideMihomo() async => false;

  @override
  Future<bool> beginCoreRestart({bool repairHelper = false}) async => false;

  @override
  void endCoreRestart() {}
}
