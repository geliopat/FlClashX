import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:test/test.dart';

void main() {
  test('legacy migration preserves named differences including defaults and empty values', () {
    const current = PatchClashConfig(keepAliveIdle: 0, keepAliveInterval: 60,
      tcpConcurrent: false, allowLan: true, secret: '');
    const inherited = PatchClashConfig(keepAliveInterval: 30, allowLan: true,
      secret: 'provider-secret');
    final owned = legacyLocalClashKeys(current, const AuthenticationProps(),
      {'keep-alive-interval', 'allow-lan', 'secret'},
      inherited: inherited, inheritedAuthentication: const AuthenticationProps());
    expect(owned, {'clash.keep-alive-idle', 'clash.tcp-concurrent',
      'clash.keep-alive-interval', 'clash.secret'});
  });

  test('reference values preserve false and zero and redact authentication and secret', () {
    const inherited = PatchClashConfig(tcpConcurrent: false, keepAliveIdle: 0,
      secret: 'provider-secret');
    final refs = yamlSettingReferences(inherited,
      const AuthenticationProps(enable: true, username: 'private', password: 'password'),
      {'tcp-concurrent', 'keep-alive-idle', 'secret', 'authentication'});
    expect(refs, {'clash.tcp-concurrent': false, 'clash.keep-alive-idle': 0,
      'clash.secret': '••••', 'clash.authentication': true});
  });

  test('source markers survive restart without storing profile values', () {
    final markers = withYamlSources({'app.hideIp'}, {'ipv6', 'tun.stack', 'proxies'});
    expect(hasYamlSourceVersion(markers), isTrue);
    expect(previousYamlSources(markers), {'ipv6', 'tun.stack'});
    expect(withYamlSources(markers, {'ipv6'}).contains('app.hideIp'), isTrue);
    expect(previousYamlSources(withYamlSources(markers, {'ipv6'})), {'ipv6'});
    final kept = keptClashKeys(named: {'keep-alive-idle'}, previous: previousYamlSources(markers),
      owned: {'clash.keep-alive-idle'}, released: {'clash.mixed-port'});
    expect(kept, contains('clash.keep-alive-idle'));
    expect(kept, isNot(contains('clash.tun.stack')));
    expect(kept, isNot(contains('clash.mixed-port')));
  });
  test('Zapret ownership is independent for each header field', () {
    const personal = (autostart: false, autofallback: false, autotune: false,
      tuneonfail: true, mode: 'fullbypass', tunemode: 'veryfast');
    final header = parseZapretHeader('autostart,autofallback,autotune,mode:strictsplit,tunemode:full')!;
    expect(managedZapretKeysOf(header), zapretPageKeys);
    expect(effectiveZapretSettings(header, personal, {}), header);
    expect(effectiveZapretSettings(header, personal, zapretPageKeys), personal);
    final mixed = effectiveZapretSettings(header, personal, {zapretStartSetting, zapretTuneModeSetting});
    expect(mixed.autostart, isFalse);
    expect(mixed.autofallback, isTrue);
    expect(mixed.tunemode, 'veryfast');
    expect(mixed.mode, 'strictsplit');
    expect(effectiveZapretSettings(null, personal, {}), personal);
    final updated = parseZapretHeader('autofallback,mode:fullbypass,tunemode:fast')!;
    final owned = {zapretStartSetting, zapretTuneModeSetting};
    expect(effectiveZapretSettings(updated, personal, owned).tunemode, 'veryfast');
    expect(effectiveZapretSettings(updated, personal, {}).tunemode, 'fast');
    expect(effectiveZapretSettings(updated, personal, owned).autofallback, isTrue);
    expect(managedZapretKeysOf(parseZapretHeader('')), {
      zapretStartSetting, zapretFallbackSetting, zapretAutoTuneSetting, zapretTuneOnFailSetting,
    });
  });
  test('only the keys a subscription may take over count as managed', () {
    expect(
      managedClashKeysOf([
        'mixed-port',
        'tun.stack',
        'tun.enable',
        'dns',
        'proxies',
        'mode',
      ]),
      {'clash.mixed-port', 'clash.tun.stack', 'clash.tun.enable', 'clash.mode'},
    );
  });

  test('an owned mode and tun switch keep what the user chose', () {
    const mine = PatchClashConfig(mode: Mode.global, tun: Tun(enable: false));
    const synced = PatchClashConfig(tun: Tun(enable: true));

    final kept = keepOwnedSettings(mine, synced, {
      'clash.mode',
      'clash.tun.enable',
    });

    expect(kept.mode, Mode.global);
    expect(kept.tun.enable, isFalse);
  });

  test('owned settings keep the value the user chose through a sync', () {
    const mine = PatchClashConfig(
      mixedPort: 1080,
      logLevel: LogLevel.debug,
      interfaceNameMode: InterfaceNameMode.custom,
      interfaceName: 'en1',
      tun: Tun(stack: TunStack.gvisor),
    );
    const theirs = PatchClashConfig(
      mixedPort: 7000,
      logLevel: LogLevel.warning,
      allowLan: true,
      tun: Tun(stack: TunStack.system),
    );

    final kept = keepOwnedSettings(mine, theirs, {
      'clash.mixed-port',
      'clash.interface-name',
      'clash.tun.stack',
    });

    expect(kept.mixedPort, 1080);
    expect(kept.interfaceNameMode, InterfaceNameMode.custom);
    expect(kept.interfaceName, 'en1');
    expect(kept.tun.stack, TunStack.gvisor);
    expect(kept.logLevel, LogLevel.warning);
    expect(kept.allowLan, isTrue);
  });

  test('owned route lists survive a sync that brings others', () {
    const mine = PatchClashConfig(
      tun: Tun(
        routeAddress: ['10.0.0.0/8'],
        routeExcludeAddress: ['192.168.0.0/16'],
      ),
    );
    const theirs = PatchClashConfig(
      tun: Tun(
        routeAddress: ['0.0.0.0/1'],
        routeExcludeAddress: ['172.16.0.0/12'],
      ),
    );

    final kept = keepOwnedSettings(mine, theirs, {
      'clash.tun.route-address',
      'clash.tun.route-exclude-address',
    });

    expect(kept.tun.routeAddress, ['10.0.0.0/8']);
    expect(kept.tun.routeExcludeAddress, ['192.168.0.0/16']);
    expect(
      managedClashKeysOf(['tun.route-address', 'tun.route-exclude-address']),
      {'clash.tun.route-address', 'clash.tun.route-exclude-address'},
    );
  });
}
