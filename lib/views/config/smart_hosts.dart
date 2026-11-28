import 'package:fl_clash/l10n/l10n.dart';
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
        '${AppLocalizations.of(context).forkReceivedHosts}: ${state.sourceCounts[id] ?? 0}',
        if (state.cachedSources.contains(id))
          AppLocalizations.of(context).forkUseCache
        else if (state.fallbackSources.contains(id))
          AppLocalizations.of(context).forkFallbackDownloaded,
        if (state.errors[id] != null) '${AppLocalizations.of(context).error}: ${state.errors[id]}',
        if (state.errors[id] != null && state.enabled && state.autoUpdate && state.sources.contains(id))
          AppLocalizations.of(context).forkRetryInterval,
      ].join('\n')),
      trailing: Switch(
        value: state.sources.contains(id),
        onChanged: state.updating ? null : (value) => controller.configure(source: id, sourceEnabled: value),
      ),
    );
    return CommonScaffold(
      title: 'Hosts',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(items: [const ManualHostsItem()]),
          const ListSectionGap(),
          generateSection(
            title: AppLocalizations.of(context).forkManagement,
            items: [
              ListItem(
                title: Text(AppLocalizations.of(context).forkEnableSmartHosts),
                subtitle: Text('${AppLocalizations.of(context).forkReceivedHosts}: ${state.entries.length}'),
                trailing: Switch(
                  value: state.enabled,
                  onChanged: state.updating ? null : (value) => controller.configure(enabled: value),
                ),
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkAutoUpdate),
                trailing: Switch(
                  value: state.autoUpdate,
                  onChanged: state.updating ? null : (value) => controller.configure(autoUpdate: value),
                ),
              ),
              ListItem<int>.options(
                title: Text(AppLocalizations.of(context).forkUpdateInterval),
                options: const [6, 12, 24, 48, 168],
                value: state.intervalHours,
                textBuilder: (value) => AppLocalizations.of(context).profileHoursFigure(value),
                onChanged: (value) => controller.configure(intervalHours: value),
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkUpdateNow),
                subtitle: Text(state.lastUpdate == null ? AppLocalizations.of(context).forkNoUpdate : '${AppLocalizations.of(context).lastUpdated}: ${state.lastUpdate!.toLocal().toString().split('.').first}'),
                onTap: state.updating || !state.enabled ? null : controller.refresh,
                trailing: state.updating ? const SizedBox.square(dimension: 18, child: CommonCircleLoading(size: 18)) : null,
              ),
            ],
            footer: AppLocalizations.of(context).forkSmartHostsHint,
          ),
          const ListSectionGap(),
          generateSection(
            title: AppLocalizations.of(context).forkSources,
            items: [
              source('malw', 'MALW.link', AppLocalizations.of(context).forkMalwHint),
              source('geohide', 'GeoHide', AppLocalizations.of(context).forkGeoHideHint),
              ListItem(
                title: Text(AppLocalizations.of(context).forkAdBlock),
                trailing: Switch(
                  value: state.includeAdblock,
                  onChanged: state.updating ? null : (value) => controller.configure(includeAdblock: value),
                ),
              ),
              ListItem.open(
                title: Text(AppLocalizations.of(context).forkCustomHttpsSources),
                widget: MapEditView(
                  title: AppLocalizations.of(context).forkSources,
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
                    if (context.mounted) await dialogs.showAlert(title: AppLocalizations.of(context).forkSources, message: TextSpan(text: error.toString()));
                  }
                },
              ),
              for (final entry in state.customSources.entries)
                source(entry.key, entry.key, entry.value),
            ],
          ),
          const ListSectionGap(),
          generateSection(
            title: AppLocalizations.of(context).forkYouTubeOptimization,
            items: [
              source('youtube', AppLocalizations.of(context).forkCommunityList, AppLocalizations.of(context).forkYoutubeListHint),
              ListItem(
                title: Text(AppLocalizations.of(context).forkSlowCdn),
                trailing: Switch(value: state.blockSlowCdn,
                    onChanged: state.cdnChecking ? null : (value) => controller.configure(blockSlowCdn: value)),
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkAutoCdn),
                subtitle: Text(AppLocalizations.of(context).forkDailyOff),
                trailing: Switch(value: state.autoCdn,
                    onChanged: state.cdnChecking ? null : (value) => controller.configure(autoCdn: value)),
              ),
              ListItem<double>.options(
                title: Text(AppLocalizations.of(context).forkSpeedThreshold),
                options: const [0.5, 1.0, 1.5, 2.0, 3.0, 5.0],
                value: state.cdnThreshold,
                textBuilder: (value) => '$value Mbps',
                onChanged: (value) => controller.configure(cdnThreshold: value),
              ),
              ListItem<int>.options(
                title: Text(AppLocalizations.of(context).forkRetention),
                options: const [1, 3, 7, 14, 30],
                value: state.cdnTtlDays,
                textBuilder: (value) => AppLocalizations.of(context).profileDaysFigure(value),
                onChanged: (value) => controller.configure(cdnTtlDays: value),
              ),
              ListItem(
                title: Text(AppLocalizations.of(context).forkCheckCdn),
                subtitle: Text(state.cdnMessage ?? AppLocalizations.of(context).forkRealDirect),
                onTap: state.cdnChecking || state.updating ? null : controller.checkCdn,
                trailing: state.cdnChecking ? const SizedBox.square(dimension: 18, child: CommonCircleLoading(size: 18)) : null,
              ),
              for (final record in state.cdnMeasurements)
                ListItem(title: Text(record.host),
                    subtitle: Text('${record.fast ? AppLocalizations.of(context).forkCdnFast : AppLocalizations.of(context).forkSlow} · ${record.mbps.toStringAsFixed(2)} Mbps')),
              ListItem(title: Text(AppLocalizations.of(context).forkResetMeasurements),
                  onTap: state.cdnChecking ? null : controller.resetCdn),
            ],
            footer: AppLocalizations.of(context).forkCdnHint,
          ),
          const ListSectionGap(),
          generateSection(
            title: AppLocalizations.of(context).forkReceivedHosts,
            items: [
              ListItem.open(
                title: Text(AppLocalizations.of(context).forkExclusions),
                widget: MapEditView(
                  title: AppLocalizations.of(context).forkExclusions,
                  entries: {for (final host in state.exclusions) host: 'exclude'},
                  keyMaxLength: 253,
                  valueMaxLength: 64,
                  titleBuilder: (item) => Text(item.key),
                  subtitleBuilder: (item) => Text(AppLocalizations.of(context).forkExcludeAuto),
                ),
                onChanged: (value) {
                  if (value is Map<String, String>) controller.configure(exclusions: value.keys.toSet());
                },
              ),
              ListItem.open(
                title: Text(AppLocalizations.of(context).forkViewAutoHosts),
                subtitle: Text('${state.entries.length}'),
                widget: _SmartHostsEntries(entries: state.entries, candidates: state.candidates),
              ),
              ListItem.open(
                title: Text(AppLocalizations.of(context).forkViewAppliedHosts),
                subtitle: Text(AppLocalizations.of(context).forkAllApplied),
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
  late Future<({Map<String, String> entries, HostCandidates candidates})> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<({Map<String, String> entries, HostCandidates candidates})> _load() async {
    if (ref.read(coreStatusProvider) != CoreStatus.connected) {
      throw StateError(AppLocalizations().forkCoreUnavailable);
    }
    final setup = ref.read(setupActionProvider.notifier);
    final before = setup.pushes;
    final candidates = setup.appliedHostCandidates;
    final entries = await ref.read(coreHandlerProvider).getAppliedHosts();
    return (entries: entries, candidates: setup.pushes == before ? candidates : const <String, Map<String, String>>{});
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<({Map<String, String> entries, HostCandidates candidates})>(
    future: _entries,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done && snapshot.hasData) {
        return _SmartHostsEntries(
          entries: snapshot.data!.entries,
          candidates: snapshot.data!.candidates,
          title: AppLocalizations.of(context).forkAppliedHosts,
        );
      }
      return CommonScaffold(
        title: AppLocalizations.of(context).forkAppliedHosts,
        body: Center(
          child: snapshot.connectionState != ConnectionState.done
              ? const CommonCircleLoading()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${AppLocalizations.of(context).forkAppliedHosts} · ${AppLocalizations.of(context).error}: ${snapshot.error}'),
                    TextButton(
                      onPressed: () => setState(() => _entries = _load()),
                      child: Text(AppLocalizations.of(context).retry),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

class _SmartHostsEntries extends StatefulWidget {
  const _SmartHostsEntries({required this.entries, this.title, this.candidates = const {}});
  final HostCandidates candidates;
  final Map<String, String> entries;
  final String? title;
  @override
  State<_SmartHostsEntries> createState() => _SmartHostsEntriesState();
}

class _SmartHostsEntriesState extends State<_SmartHostsEntries> {
  String _query = '';
  bool _conflictsOnly = false;
  String _source(String source) => switch (source) {
    'profile' => AppLocalizations.of(context).forkProfileScript,
    'manual' => AppLocalizations.of(context).forkManualHosts,
    _ => smartHostLabel(source.startsWith('auto:') ? source.substring(5) : source),
  };
  Map<String, String> _candidates(String domain) => widget.candidates[normalizedHostKey(domain)] ?? const {};
  bool _conflict(String domain) => _candidates(domain).values.toSet().length > 1;
  @override
  Widget build(BuildContext context) {
    final entries = widget.entries.entries.where((entry) =>
      (!_conflictsOnly || _conflict(entry.key)) &&
      (entry.key.toLowerCase().contains(_query.toLowerCase()) ||
      entry.value.toLowerCase().contains(_query.toLowerCase()) ||
      _candidates(entry.key).keys.any((source) => _source(source).toLowerCase().contains(_query.toLowerCase())))
    ).toList()..sort((a, b) => a.key.compareTo(b.key));
    return CommonScaffold(
      title: '${widget.title ?? AppLocalizations.of(context).forkReceivedHosts} (${widget.entries.length})',
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      body: Builder(builder: (context) => ListView.builder(
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 16 + context.bottomInset),
        itemCount: entries.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return ListItem(
              title: Text(AppLocalizations.of(context).forkOnlyConflicts),
              subtitle: Text('${AppLocalizations.of(context).forkConflicts}: ${widget.entries.keys.where(_conflict).length}'),
              trailing: Switch(value: _conflictsOnly, onChanged: (value) => setState(() => _conflictsOnly = value)),
            );
          }
          final entry = entries[index - 1];
          final candidates = _candidates(entry.key);
          final matching = candidates.entries.where((item) => item.value == entry.value).map((item) => _source(item.key)).toList();
          return ListItem(
            title: Text(entry.key),
            subtitle: Text([
              entry.value,
              matching.isEmpty ? AppLocalizations.of(context).forkUnknownSource : '${AppLocalizations.of(context).forkSourceMatches}: ${matching.join(', ')}',
              if (_conflict(entry.key)) '${AppLocalizations.of(context).forkConflict}:',
              if (_conflict(entry.key))
                for (final item in candidates.entries) '${_source(item.key)}: ${item.value}',
            ].join('\n'), maxLines: 12),
          );
        },
      )),
    );
  }
}

class ManualHostsItem extends ConsumerWidget {
  const ManualHostsItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hosts = ref.watch(
      patchClashConfigProvider.select((state) => state.hosts),
    );
    return ListItem.open(
      title: Text(Localizations.localeOf(context).languageCode == 'ru'
          ? 'Добавить записи' : 'Add records'),
      subtitle: Text(
        hosts.isEmpty
            ? appLocalizations.none
            : appLocalizations.itemsCount(hosts.length),
      ),
      widget: MapEditView(
        title: 'Hosts',
        entries: hosts,
        keyMaxLength: TextInputLimits.domain,
        valueMaxLength: TextInputLimits.hostValue,
        titleBuilder: (item) => Text(item.key),
        subtitleBuilder: (item) => Text(item.value),
      ),
      onChanged: (value) {
        if (value is! Map<String, String>) {
          return;
        }
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith(hosts: value));
      },
    );
  }
}
