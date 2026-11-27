import 'dart:io';

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/views/zapret.dart';
import 'package:fl_clash/views/diagnostics.dart';
import 'package:fl_clash/views/zapret_logs.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/icons/app_glyphs.dart';
import 'package:fl_clash/views/views.dart';
import 'package:material_ui/material_ui.dart';

class Navigation implements NavigationPort {
  static Navigation? _instance;

  @override
  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
    bool simple = false,
  }) {
    return [
      NavigationItem(
        glyph: AppGlyphs.home,
        label: PageLabel.dashboard,
        builder: (_) =>
            const DashboardView(key: GlobalObjectKey(PageLabel.dashboard)),
      ),
      NavigationItem(
        glyph: AppGlyphs.globe,
        label: PageLabel.proxies,
        builder: (_) =>
            const ProxiesView(key: GlobalObjectKey(PageLabel.proxies)),
        modes: hasProxies
            ? [NavigationItemMode.mobile, NavigationItemMode.desktop]
            : [],
      ),
      NavigationItem(
        glyph: AppGlyphs.files,
        label: PageLabel.profiles,
        builder: (_) =>
            const ProfilesView(key: GlobalObjectKey(PageLabel.profiles)),
      ),
      NavigationItem(
        glyph: AppGlyphs.network,
        label: PageLabel.connections,
        builder: (_) => const ConnectionFeedsView(
          key: GlobalObjectKey(PageLabel.connections),
        ),
        modes: simple
            ? []
            : [NavigationItemMode.desktop, NavigationItemMode.moreFull],
      ),
      NavigationItem(
        glyph: AppGlyphs.dns,
        label: PageLabel.dns,
        builder: (_) =>
            const DnsQueriesView(key: GlobalObjectKey(PageLabel.dns)),
        modes: simple ? [] : [NavigationItemMode.moreFull],
      ),
      NavigationItem(
        glyph: AppGlyphs.resources,
        label: PageLabel.resources,
        builder: (_) => Platform.isWindows
            ? const DiagnosticsView(key: GlobalObjectKey(PageLabel.resources))
            : const ResourcesView(key: GlobalObjectKey(PageLabel.resources)),
        modes: Platform.isWindows
            ? [NavigationItemMode.desktop, NavigationItemMode.more]
            : simple ? [] : [NavigationItemMode.more],
      ),
      NavigationItem(
        glyph: AppGlyphs.fileText,
        label: PageLabel.logs,
        builder: (_) => const LogsView(key: GlobalObjectKey(PageLabel.logs)),
        modes: openLogs
            ? [NavigationItemMode.desktop, NavigationItemMode.more]
            : [],
      ),
      if (Platform.isWindows)
        NavigationItem(
          glyph: AppGlyphs.shieldOff,
          label: PageLabel.zapret,
          builder: (_) => const ZapretView(key: GlobalObjectKey(PageLabel.zapret)),
          modes: [NavigationItemMode.desktop],
        ),
      if (Platform.isWindows)
        NavigationItem(
          glyph: AppGlyphs.fileText,
          label: PageLabel.zapretLogs,
          builder: (_) => const ZapretLogsView(key: GlobalObjectKey(PageLabel.zapretLogs)),
          modes: [NavigationItemMode.desktop],
        ),
      if (Platform.isWindows)
        NavigationItem(
          glyph: AppGlyphs.clipboardList,
          label: PageLabel.serviceJournal,
          builder: (_) => const ZapretLogsView(
            key: GlobalObjectKey(PageLabel.serviceJournal), journalOnly: true),
          modes: [NavigationItemMode.desktop],
        ),
      NavigationItem(
        glyph: AppGlyphs.settings,
        label: PageLabel.tools,
        builder: (_) => const ToolsView(key: GlobalObjectKey(PageLabel.tools)),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
    ];
  }

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
