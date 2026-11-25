import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

class SmartHostsView extends ConsumerWidget {
  const SmartHostsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(smartHostsProvider);
    final controller = ref.read(smartHostsProvider.notifier);
    Widget source(String id, String label, String description) => ListItem(
      title: Text(label),
      subtitle: Text([
        description,
        'Записей: ${state.sourceCounts[id] ?? 0}',
        if (state.cachedSources.contains(id))
          'Используется сохранённый или встроенный список'
        else if (state.fallbackSources.contains(id))
          'Загружено с резервного источника',
        if (state.errors[id] != null) 'Ошибка: ${state.errors[id]}',
        if (state.errors[id] != null && state.enabled && state.autoUpdate && state.sources.contains(id))
          'Автоматические повторы с интервалом 15 минут',
      ].join('\n')),
      trailing: Switch(
        value: state.sources.contains(id),
        onChanged: state.updating ? null : (value) => controller.configure(source: id, sourceEnabled: value),
      ),
    );
    return CommonScaffold(
      title: 'Умный Hosts',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: 'Управление',
            items: [
              ListItem(
                title: const Text('Включить умный Hosts'),
                subtitle: Text('Автоматических записей: ${state.entries.length}'),
                trailing: Switch(
                  value: state.enabled,
                  onChanged: state.updating ? null : (value) => controller.configure(enabled: value),
                ),
              ),
              ListItem(
                title: const Text('Автоматическое обновление'),
                trailing: Switch(
                  value: state.autoUpdate,
                  onChanged: state.updating ? null : (value) => controller.configure(autoUpdate: value),
                ),
              ),
              ListItem<int>.options(
                title: const Text('Интервал обновления'),
                options: const [6, 12, 24, 48, 168],
                value: state.intervalHours,
                textBuilder: (value) => '$value ч.',
                onChanged: (value) => controller.configure(intervalHours: value),
              ),
              ListItem(
                title: const Text('Обновить сейчас'),
                subtitle: Text(state.lastUpdate == null ? 'Ещё не обновлялись' : 'Последняя успешная загрузка: ${state.lastUpdate!.toLocal().toString().split('.').first}'),
                onTap: state.updating || !state.enabled ? null : controller.refresh,
                trailing: state.updating ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
            ],
            footer: 'Работает через Hosts Mihomo. Системный hosts Windows и настройки DNS не изменяются. Записи профиля и ручные записи имеют приоритет.',
          ),
          const ListSectionGap(),
          generateSection(
            title: 'Источники',
            items: [
              source('malw', 'MALW.link', 'DNS + SNI-прокси: обход IP-блокировок сервисов (ChatGPT, Spotify, Twitch и др.)'),
              source('geohide', 'GeoHide', 'Hosts GeoHide: рабочие IP и прокси для заблокированных сервисов'),
              ListItem(
                title: const Text('Блокировка рекламы'),
                trailing: Switch(
                  value: state.includeAdblock,
                  onChanged: state.updating ? null : (value) => controller.configure(includeAdblock: value),
                ),
              ),
              ListItem.open(
                title: const Text('Пользовательские HTTPS-источники'),
                widget: MapEditView(
                  title: 'Источники',
                  entries: state.customSources,
                  keyMaxLength: 100,
                  valueMaxLength: 2048,
                  titleBuilder: (item) => Text(item.key),
                  subtitleBuilder: (item) => Text(item.value),
                ),
                onChanged: (value) async {
                  if (value is! Map<String, String>) return;
                  try {
                    await controller.configure(customSources: value);
                  } catch (error) {
                    if (context.mounted) await dialogs.showAlert(title: 'Источники', message: TextSpan(text: error.toString()));
                  }
                },
              ),
              for (final entry in state.customSources.entries)
                source(entry.key, entry.key, entry.value),
            ],
          ),
          const ListSectionGap(),
          generateSection(
            title: 'Оптимизация YouTube',
            items: [
              source('youtube', 'Использовать общественный список', 'Проблемные CDN из списка Zapret2 GUI перенаправляются на 127.0.0.2'),
              ListItem(
                title: const Text('Блокировать измеренные медленные CDN'),
                trailing: Switch(value: state.blockSlowCdn,
                    onChanged: state.cdnChecking ? null : (value) => controller.configure(blockSlowCdn: value)),
              ),
              ListItem(
                title: const Text('Автоматическая проверка скорости CDN'),
                subtitle: const Text('Раз в сутки, по умолчанию выключено'),
                trailing: Switch(value: state.autoCdn,
                    onChanged: state.cdnChecking ? null : (value) => controller.configure(autoCdn: value)),
              ),
              ListItem<double>.options(
                title: const Text('Порог скорости'),
                options: const [0.5, 1.0, 1.5, 2.0, 3.0, 5.0],
                value: state.cdnThreshold,
                textBuilder: (value) => '$value Мбит/с',
                onChanged: (value) => controller.configure(cdnThreshold: value),
              ),
              ListItem<int>.options(
                title: const Text('Срок хранения измерений'),
                options: const [1, 3, 7, 14, 30],
                value: state.cdnTtlDays,
                textBuilder: (value) => '$value дн.',
                onChanged: (value) => controller.configure(cdnTtlDays: value),
              ),
              ListItem(
                title: const Text('Проверить скорость CDN'),
                subtitle: Text(state.cdnMessage ?? 'Реальный видеопоток через DIRECT'),
                onTap: state.cdnChecking || state.updating ? null : controller.checkCdn,
                trailing: state.cdnChecking ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : null,
              ),
              for (final record in state.cdnMeasurements)
                ListItem(title: Text(record.host),
                    subtitle: Text('${record.fast ? "Быстрый" : "Медленный"} · ${record.mbps.toStringAsFixed(2)} Мбит/с')),
              ListItem(title: const Text('Сбросить измерения'),
                  onTap: state.cdnChecking ? null : controller.resetCdn),
            ],
            footer: 'Измерение использует подписанные ссылки видеопотоков и до 3 МиБ на узел. Неизвестный результат не создаёт блокировок. Старые измерения истекают автоматически.',
          ),
          const ListSectionGap(),
          generateSection(
            title: 'Полученные Hosts',
            items: [
              ListItem.open(
                title: const Text('Исключения'),
                widget: MapEditView(
                  title: 'Исключения',
                  entries: {for (final host in state.exclusions) host: 'exclude'},
                  keyMaxLength: 253,
                  valueMaxLength: 64,
                  titleBuilder: (item) => Text(item.key),
                  subtitleBuilder: (item) => const Text('Не добавлять автоматически'),
                ),
                onChanged: (value) {
                  if (value is Map<String, String>) controller.configure(exclusions: value.keys.toSet());
                },
              ),
              ListItem.open(
                title: const Text('Просмотр автоматических записей'),
                subtitle: Text('${state.entries.length}'),
                widget: _SmartHostsEntries(entries: state.entries),
              ),
              ListItem.open(
                title: const Text('Просмотр итогового Hosts'),
                subtitle: const Text('Все записи, применённые в Mihomo'),
                widget: const _AppliedHostsView(),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppliedHostsView extends ConsumerStatefulWidget {
  const _AppliedHostsView();

  @override
  ConsumerState<_AppliedHostsView> createState() => _AppliedHostsViewState();
}

class _AppliedHostsViewState extends ConsumerState<_AppliedHostsView> {
  late Future<Map<String, String>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<Map<String, String>> _load() async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      throw StateError('Ядро Mihomo недоступно');
    }
    return ref.read(coreHandlerProvider).getAppliedHosts();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, String>>(
    future: _entries,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
        return _SmartHostsEntries(
          entries: snapshot.data!,
          title: 'Итоговый Hosts',
        );
      }
      return CommonScaffold(
        title: 'Итоговый Hosts',
        body: Center(
          child: snapshot.connectionState != ConnectionState.done
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Не удалось получить применённые Hosts: ${snapshot.error}'),
                    TextButton(
                      onPressed: () => setState(() => _entries = _load()),
                      child: const Text('Повторить'),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

class _SmartHostsEntries extends StatefulWidget {
  const _SmartHostsEntries({required this.entries, this.title = 'Полученные Hosts'});
  final Map<String, String> entries;
  final String title;
  @override
  State<_SmartHostsEntries> createState() => _SmartHostsEntriesState();
}

class _SmartHostsEntriesState extends State<_SmartHostsEntries> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final entries = widget.entries.entries.where((entry) =>
      entry.key.toLowerCase().contains(_query.toLowerCase()) ||
      entry.value.toLowerCase().contains(_query.toLowerCase())
    ).toList()..sort((a, b) => a.key.compareTo(b.key));
    return CommonScaffold(
      title: '${widget.title} (${widget.entries.length})',
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      body: ListView.builder(
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 16 + context.bottomInset),
        itemCount: entries.length,
        itemBuilder: (context, index) => ListItem(
          title: Text(entries[index].key),
          subtitle: Text(entries[index].value),
        ),
      ),
    );
  }
}
