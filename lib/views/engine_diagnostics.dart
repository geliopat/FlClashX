import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

/// Explicit in-memory recording. Never export endpoints to the general
/// diagnostic report; the core owns both bounded histories.
class EngineDiagnosticsView extends ConsumerStatefulWidget {
  const EngineDiagnosticsView({super.key});

  @override
  ConsumerState<EngineDiagnosticsView> createState() => _EngineDiagnosticsViewState();
}

class _EngineDiagnosticsViewState extends ConsumerState<EngineDiagnosticsView> with CoreEventListener {
  bool _busy = false;
  bool _supported = false;
  String? _error;
  int _capacity = 0;
  bool _chain = false;
  List<Map<String, dynamic>> _closed = const [];
  List<Map<String, dynamic>> _chains = const [];

  String _tr(String ru, String en) =>
      Localizations.localeOf(context).languageCode == 'ru' ? ru : en;

  @override
  void initState() {
    super.initState();
    coreEventManager.addListener(this);
    Future.microtask(() { if (mounted) _load(); });
  }

  @override
  void dispose() {
    coreEventManager.removeListener(this);
    super.dispose();
  }

  @override
  void onClosedFlowChanged() {
    if (mounted && !_busy && _capacity > 0 &&
        ModalRoute.of(context)?.isCurrent != false) {
      _load();
    }
  }

  Future<void> _load({int? capacity, bool? chain}) async {
    if (!mounted || _busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (ref.read(coreStatusProvider) != CoreStatus.connected) {
        throw StateError(_tr('Ядро не подключено', 'Core not connected'));
      }
      final core = ref.read(coreHandlerProvider);
      final capabilities = await core.getCoreCapabilities();
      if (!mounted) return;
      final supported = capabilities.containsAll(const {
        'closed-flow-history-v1', 'chain-diagnostics-v1',
      });
      if (!supported) {
        setState(() {
          _supported = false;
          _closed = const [];
          _chains = const [];
        });
        return;
      }
      if (capacity != null || chain != null) {
        await core.setEngineDiagnostics(
          closedFlowCapacity: capacity ?? _capacity,
          chainDiagnostics: chain ?? _chain,
        );
      }
      final snapshot = await core.getEngineDiagnostics();
      if (!mounted) return;
      final settings = snapshot['settings'] as Map;
      List<Map<String, dynamic>> rows(String key) => [
        for (final item in (snapshot[key] as List? ?? const []).whereType<Map>())
          Map<String, dynamic>.from(item),
      ];
      setState(() {
        _supported = true;
        _capacity = settings['closedFlowCapacity'] as int;
        _chain = settings['chainDiagnostics'] as bool;
        _closed = rows('closed');
        _chains = rows('chains');
      });
    } catch (error) {
      if (mounted) setState(() { _error = '$error'; _supported = false; _closed = const []; _chains = const []; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _join(Object? value) => value is List
      ? value.whereType<String>().join(' → ')
      : '';

  @override
  Widget build(BuildContext context) {
    final connected = ref.watch(coreStatusProvider) == CoreStatus.connected;
    final enabled = connected && _supported && !_busy;
    final count = _closed.length + _chains.length;
    return CommonScaffold(
      title: _tr('Диагностика ядра', 'Core diagnostics'),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        itemCount: count + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return generateSection(
              items: [
                ListItem(
                  title: Text(_tr('Обновить данные', 'Refresh data')),
                  trailing: _busy ? const CircularProgressIndicator() : const GlyphIcon(AppGlyphs.sync),
                  onTap: connected && !_busy ? () => _load() : null,
                  subtitle: Text(_error ?? (_supported
                      ? _tr('Записей: $count', 'Records: $count')
                      : _tr('Требуется совместимый адаптер ядра', 'Compatible core adapter required'))),
                ),
                ListItem(
                  title: Text(_tr('Закрытые соединения', 'Closed connections')),
                  subtitle: Text(_tr('До 1024 записей в памяти; счётчики на момент закрытия',
                      'Up to 1024 in-memory records; counters at removal')),
                  trailing: Switch(value: _capacity > 0,
                      onChanged: enabled ? (value) => _load(capacity: value ? 1024 : 0) : null),
                ),
                ListItem(
                  title: Text(_tr('Диагностика цепочек', 'Chain diagnostics')),
                  subtitle: Text(_tr('До 256 попыток; не проверка доступности всего каскада',
                      'Up to 256 dial attempts; not an end-to-end health check')),
                  trailing: Switch(value: _chain,
                      onChanged: enabled ? (value) => _load(chain: value) : null),
                ),
              ],
            );
          }
          if (index <= _closed.length) {
            final row = _closed[index - 1];
            return ListItem(
              title: Text(_join(row['chains']).isEmpty ? '${row['id']}' : _join(row['chains'])),
              subtitle: Text('${row['removedAt']} · ${row['rule']} · ↑ ${row['upload']} B · ↓ ${row['download']} B'),
            );
          }
          final row = _chains[index - _closed.length - 1];
          final successful = row['DialSucceeded'] == true;
          final delay = ((row['Duration'] as num?) ?? 0) / 1000000;
          return ListItem(
            title: Text('${row['Group']} · ${row['Target']}'),
            subtitle: Text('${row['Network']} · ${delay.toStringAsFixed(1)} ms · ${_join(row['Chains'])} · '
              '${successful ? _tr('Подключение создано', 'Dial succeeded') : _tr('Ошибка подключения', 'Dial failed')}'),
          );
        },
      ),
    );
  }
}
