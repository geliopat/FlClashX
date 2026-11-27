import 'clash_config.dart';
import 'provider_headers.dart';

/// Flags of `flclashz-settings` and the app switch each one drives.
const appSwitchSettings = {
  'minimize': 'app.minimizeOnExit',
  'autorun': 'app.autoLaunch',
  'shadowstart': 'app.silentLaunch',
  'autostart': 'app.autoRun',
  'autoupdate': 'app.autoCheckUpdate',
  'openlogs': 'app.openLogs',
  'closeconnections': 'app.closeConnections',
};

/// Driven by `flclashz-special: hideip`.
const hideIpSetting = 'app.hideIp';

/// Driven by `flclashz-special: novibrate`.
const vibrationSetting = 'app.vibration';

/// Cards supplied by `flclashz-widgets` can be returned to the provider.
/// `denywidgets` remains a separate forced policy.
const dashboardWidgetsSetting = 'app.dashboardWidgets';

/// The profile-update-interval header belongs to a single subscription.
String profileUpdateIntervalSetting(int profileId) =>
    'profile.$profileId.updateInterval';

// Each Zapret option has the same ownership semantics as other settings.
const zapretStartSetting = 'zapret.autostart';
const zapretFallbackSetting = 'zapret.autofallback';
const zapretAutoTuneSetting = 'zapret.autotune';
const zapretTuneOnFailSetting = 'zapret.tuneonfail';
const zapretModeSetting = 'zapret.mode';
const zapretTuneModeSetting = 'zapret.tunemode';

const zapretPageKeys = {
  zapretStartSetting, zapretFallbackSetting, zapretAutoTuneSetting,
  zapretTuneOnFailSetting, zapretModeSetting, zapretTuneModeSetting,
};

Set<String> managedZapretKeysOf(ZapretHeaderSettings? header) => {
  if (header != null) ...{
    zapretStartSetting, zapretFallbackSetting,
    zapretAutoTuneSetting, zapretTuneOnFailSetting,
  },
  if (header?.mode != null) zapretModeSetting,
  if (header?.tunemode != null) zapretTuneModeSetting,
};

ZapretHeaderSettings effectiveZapretSettings(
  ZapretHeaderSettings? header,
  ZapretHeaderSettings personal,
  Set<String> owned,
) {
  T pick<T>(String key, T? supplied, T local) =>
      owned.contains(key) ? local : supplied ?? local;
  return (
    autostart: pick(zapretStartSetting, header?.autostart, personal.autostart),
    autofallback: pick(zapretFallbackSetting, header?.autofallback, personal.autofallback),
    autotune: pick(zapretAutoTuneSetting, header?.autotune, personal.autotune),
    tuneonfail: pick(zapretTuneOnFailSetting, header?.tuneonfail, personal.tuneonfail),
    mode: pick(zapretModeSetting, header?.mode, personal.mode),
    tunemode: pick(zapretTuneModeSetting, header?.tunemode, personal.tunemode),
  );
}

/// The config keys a subscription takes over and the user may take back.
const managedClashKeys = {
  'mode',
  'mixed-port',
  'port',
  'socks-port',
  'redir-port',
  'tproxy-port',
  'allow-lan',
  'authentication',
  'ipv6',
  'log-level',
  'find-process-mode',
  'interface-name',
  'routing-mark',
  'tcp-concurrent',
  'unified-delay',
  'keep-alive-interval',
  'keep-alive-idle',
  'disable-keep-alive',
  'external-controller',
  'secret',
  'geodata-loader',
  'geo-auto-update',
  'geo-update-interval',
  'geox-url',
  'global-ua',
  'tun.enable',
  'tun.mtu',
  'tun.congestion-controller',
  'tun.device',
  'tun.stack',
  'tun.route-address',
  'tun.route-exclude-address',
};

String clashSettingKey(String yamlKey) => 'clash.$yamlKey';

/// The lockable keys of each settings page, for its hint.
const generalPageKeys = {
  'app.minimizeOnExit',
  'app.autoLaunch',
  'app.silentLaunch',
  'app.autoRun',
  'app.autoCheckUpdate',
  'app.openLogs',
  'app.closeConnections',
  'clash.allow-lan',
  'clash.authentication',
  'clash.ipv6',
  'clash.find-process-mode',
  'clash.tcp-concurrent',
  'clash.unified-delay',
  'clash.geodata-loader',
  'clash.external-controller',
  'clash.secret',
  'clash.log-level',
  'clash.mixed-port',
  'clash.port',
  'clash.socks-port',
  'clash.redir-port',
  'clash.tproxy-port',
};

const networkPageKeys = {
  'clash.tun.enable',
  'clash.tun.mtu',
  'clash.tun.congestion-controller',
  'clash.tun.stack',
  'clash.interface-name',
  'clash.disable-keep-alive',
  'clash.keep-alive-idle',
  'clash.keep-alive-interval',
  'clash.routing-mark',
  'clash.tun.route-address',
  'clash.tun.route-exclude-address',
};

const themePageKeys = {
  'view.app.theme',
  'view.app.navbar',
  'view.app.tabs',
  'view.app.glass',
  'view.app.color',
  'view.app.black',
  vibrationSetting,
  hideIpSetting,
};

const proxiesPageKeys = {
  'view.proxies.type',
  'view.proxies.sort',
  'view.proxies.layout',
  'view.proxies.icon',
  'view.proxies.card',
  'view.proxies.hidetimeout',
};

/// The settings a `flclashz-view` header speaks for, by what it names.
Set<String> managedViewKeysOf(ViewRequest? view) {
  if (view == null) {
    return const {};
  }
  return {
    if (view.type != null) 'view.proxies.type',
    if (view.sort != null) 'view.proxies.sort',
    if (view.layout != null) 'view.proxies.layout',
    if (view.icon != null) 'view.proxies.icon',
    if (view.card != null) 'view.proxies.card',
    if (view.hideTimeout != null) 'view.proxies.hidetimeout',
    if (view.themeMode != null) 'view.app.theme',
    if (view.floatingNavigationBar != null) 'view.app.navbar',
    if (view.tabAnimation != null) 'view.app.tabs',
    if (view.liquidGlass != null) 'view.app.glass',
    if (view.color != null || view.colorStyle != null) 'view.app.color',
    if (view.pureBlack != null) 'view.app.black',
  };
}

Set<String> managedClashKeysOf(Iterable<String> present) => {
  for (final key in present)
    if (managedClashKeys.contains(key)) clashSettingKey(key),
};

/// [synced] with every setting in [owned] put back as [current] had it.
PatchClashConfig keepOwnedSettings(
  PatchClashConfig current,
  PatchClashConfig synced,
  Set<String> owned,
) {
  var next = synced;
  for (final key in owned) {
    next = switch (key) {
      'clash.mode' => next.copyWith(mode: current.mode),
      'clash.mixed-port' => next.copyWith(mixedPort: current.mixedPort),
      'clash.port' => next.copyWith(port: current.port),
      'clash.socks-port' => next.copyWith(socksPort: current.socksPort),
      'clash.redir-port' => next.copyWith(redirPort: current.redirPort),
      'clash.tproxy-port' => next.copyWith(tproxyPort: current.tproxyPort),
      'clash.allow-lan' => next.copyWith(allowLan: current.allowLan),
      'clash.ipv6' => next.copyWith(ipv6: current.ipv6),
      'clash.log-level' => next.copyWith(logLevel: current.logLevel),
      'clash.find-process-mode' => next.copyWith(
        findProcessMode: current.findProcessMode,
      ),
      'clash.interface-name' => next.copyWith(
        interfaceNameMode: current.interfaceNameMode,
        interfaceName: current.interfaceName,
      ),
      'clash.routing-mark' => next.copyWith(routingMark: current.routingMark),
      'clash.tcp-concurrent' => next.copyWith(
        tcpConcurrent: current.tcpConcurrent,
      ),
      'clash.unified-delay' => next.copyWith(
        unifiedDelay: current.unifiedDelay,
      ),
      'clash.keep-alive-interval' => next.copyWith(
        keepAliveInterval: current.keepAliveInterval,
      ),
      'clash.keep-alive-idle' => next.copyWith(
        keepAliveIdle: current.keepAliveIdle,
      ),
      'clash.disable-keep-alive' => next.copyWith(
        disableKeepAlive: current.disableKeepAlive,
      ),
      'clash.external-controller' => next.copyWith(
        externalController: current.externalController,
      ),
      'clash.secret' => next.copyWith(secret: current.secret),
      'clash.geodata-loader' => next.copyWith(
        geodataLoader: current.geodataLoader,
      ),
      'clash.geo-auto-update' => next.copyWith(
        geoAutoUpdate: current.geoAutoUpdate,
      ),
      'clash.geo-update-interval' => next.copyWith(
        geoUpdateInterval: current.geoUpdateInterval,
      ),
      'clash.geox-url' => next.copyWith(geoXUrl: current.geoXUrl),
      'clash.global-ua' => next.copyWith(globalUa: current.globalUa),
      'clash.tun.enable' => next.copyWith(
        tun: next.tun.copyWith(enable: current.tun.enable),
      ),
      'clash.tun.mtu' => next.copyWith(
        tun: next.tun.copyWith(mtu: current.tun.mtu),
      ),
      'clash.tun.congestion-controller' => next.copyWith(
        tun: next.tun.copyWith(
          congestionController: current.tun.congestionController,
        ),
      ),
      'clash.tun.device' => next.copyWith(
        tun: next.tun.copyWith(device: current.tun.device),
      ),
      'clash.tun.stack' => next.copyWith(
        tun: next.tun.copyWith(stack: current.tun.stack),
      ),
      'clash.tun.route-address' => next.copyWith(
        tun: next.tun.copyWith(routeAddress: current.tun.routeAddress),
      ),
      'clash.tun.route-exclude-address' => next.copyWith(
        tun: next.tun.copyWith(
          routeExcludeAddress: current.tun.routeExcludeAddress,
        ),
      ),
      _ => next,
    };
  }
  return next;
}
