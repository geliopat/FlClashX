import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
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
      subtitle: Text('$description\nЗаписей: ${state.sourceCounts[id] ?? 0}${state.errors[id] == null ? '' : '\nОшибка: ${state.errors[id]}'}'),
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
                subtitle: Text(state.lastUpdate?.toLocal().toString().split('.').first ?? 'Ещё не обновлялись'),
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
              source('geohide', 'GeoHide', 'Ежедневно обновляемый hosts: рабочие IP и прокси GeoHide для заблокированных сервисов'),
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
                  if (value == null) return;
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
            ],
            footer: 'Список зависит от провайдера и может устаревать. Локальное измерение скорости CDN пока не подключено.',
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
                  if (value != null) controller.configure(exclusions: value.keys.toSet());
                },
              ),
              ListItem.open(
                title: const Text('Просмотр автоматических записей'),
                subtitle: Text('${state.entries.length}'),
                widget: _SmartHostsEntries(entries: state.entries),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SmartHostsEntries extends StatefulWidget {
  const _SmartHostsEntries({required this.entries});
  final Map<String, String> entries;
  @override
  State<_SmartHostsEntries> createState() => _SmartHostsEntriesState();
}

class _SmartHostsEntriesState extends State<_SmartHostsEntries> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final entries = widget.entries.entries.where((entry) =>
      entry.key.contains(_query.toLowerCase()) || entry.value.contains(_query)
    ).toList();
    return CommonScaffold(
      title: 'Полученные Hosts',
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
