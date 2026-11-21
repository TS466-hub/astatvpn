import 'dart:convert';

import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/routing_profile.dart';
import 'package:astatvpn/core/subscription.dart';
import 'package:astatvpn/core/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _happ = {
  'Name': 'Пример Happ',
  'GlobalProxy': 'false',
  'RouteOrder': 'BLOCK_PROXY_DIRECT',
  'DirectSites': ['example.org', 'geosite:ru'],
  'DirectIp': ['192.168.0.0/16'],
  'ProxySites': ['full:app.example.org'],
  'BlockSites': ['example.net'],
};

void main() {
  test('импорт Happ по ссылке и сохранение настроек', () {
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(_happ)))
        .replaceAll('=', '');
    final profile = parseRoutingProfile(
      routingPayload('routing: happ://routing/onadd/$encoded'),
    );
    expect(profile.name, 'Пример Happ');
    expect(profile.globalProxy, isFalse);
    expect(profile.order, [
      RouteAction.block,
      RouteAction.proxy,
      RouteAction.direct,
    ]);
    expect(profile.groups[RouteAction.direct]!.domains, [
      'domain:example.org',
      'geosite:ru',
    ]);
    final saved = AppSettings(
      routingProfileId: 'happ',
      routingProfiles: {'happ': profile},
    );
    expect(
      AppSettings.fromJson(saved.toJson()).routingProfile!.toJson(),
      profile.toJson(),
    );
    expect(AppSettings.fromJson({'ruDirect': false}).routingProfile, isNull);
  });

  test('ручные правила распознают домены и IP, проверяют подсети и отклоняют внешние файлы', () {
    final group = parseManualRules(
      'example.org\n203.0.113.4\n2001:db8::/32\ngeoip:ru\nexample.org',
    );
    expect(group.domains, ['domain:example.org']);
    expect(group.ips, ['203.0.113.4', '2001:db8::/32', 'geoip:ru']);
    expect(() => parseManualRules('203.0.113.0/33'), throwsFormatException);
    expect(
      () => parseManualRules('ext:another.dat:example'),
      throwsFormatException,
    );
    expect(
      () => parseRoutingProfile('{"outbounds":[]}'),
      throwsFormatException,
    );
    expect(
      routingPayload(
        'incy://autorouting/onadd/https://example.org/profile.json',
      ),
      'https://example.org/profile.json',
    );
  });

  test('правила применяются после DNS, сохраняют «Авто» и имеют явный маршрут по умолчанию', () {
    final profile = RoutingProfile.fromJson(_happ);
    final settings = AppSettings(
      routingProfileId: 'happ',
      routingProfiles: {'happ': profile},
    );
    final outbound = parseSubscription(
      'vless://123e4567-e89b-12d3-a456-426614174000@example.org:443',
    ).servers.single.outbound!;
    final server = ServerEntry(
      id: 'auto',
      name: 'Авто',
      protocol: 'auto',
      address: '',
      port: 0,
      full: {
        'inbounds': [
          {'tag': 'socks'},
        ],
        'outbounds': [outbound],
        'routing': {
          'balancers': [
            {
              'tag': 'auto',
              'selector': ['proxy'],
            },
          ],
          'rules': [
            {
              'type': 'field',
              'inboundTag': ['socks'],
              'balancerTag': 'auto',
            },
          ],
        },
      },
    );
    final config = buildXrayConfig(server, settings, TunPlatform.android);
    final rules = config['routing']['rules'] as List;
    expect(rules[0]['port'], 53);
    expect(rules[1]['domain'], ['domain:example.net']);
    expect(rules[1]['outboundTag'], 'astat-routing-blackhole');
    expect(rules[2]['balancerTag'], 'auto');
    expect(rules[4]['ip'], ['192.168.0.0/16']);
    expect(rules[5]['outboundTag'], 'direct');
    expect(rules[5]['network'], 'tcp,udp');
  });
}
