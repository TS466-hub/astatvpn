import 'dart:convert';

import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/share_link.dart';
import 'package:astatvpn/core/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

// Все ключи, идентификаторы и адреса выдуманы.
const uuid = '11111111-2222-4333-8444-555555555555';
const pbk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

ServerEntry linkServer([String? link]) {
  final p = parseShareLink(link ?? 'vless://$uuid@nl.example.com:443?security=reality&pbk=$pbk&sid=ab&sni=example.org&fp=chrome&flow=xtls-rprx-vision#NL');
  return ServerEntry(id: 'a', name: p.name, protocol: p.protocol, address: p.address, port: p.port, outbound: p.outbound);
}

const ruSites = ['domain:ru', 'domain:su', 'domain:xn--p1ai', 'domain:vk.com', 'domain:yandex.net'];

/// Шаблон подписки для клиента с локальным прокси (как у Happ и v2rayNG).
Map<String, dynamic> template() => (jsonDecode(jsonEncode(_template)) as Map).cast<String, dynamic>();

const _template = {
      'remarks': '🇳🇱 Netherlands',
      'log': {'loglevel': 'debug', 'access': '/tmp/access.log'},
      'inbounds': [
        {
          'tag': 'socks',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'settings': {'udp': true, 'auth': 'noauth'},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
          },
        },
        {
          'tag': 'http',
          'port': 10809,
          'listen': '127.0.0.1',
          'protocol': 'http',
          'settings': {'allowTransparent': false},
        },
      ],
      'dns': {
        'servers': [
          {'address': '77.88.8.8', 'domains': ruSites},
          '1.1.1.1',
          '1.0.0.1',
        ],
        'queryStrategy': 'UseIPv4',
      },
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'ip': ['77.88.8.8'],
            'port': '53',
            'outboundTag': 'direct',
          },
          {'type': 'field', 'domain': ruSites, 'outboundTag': 'direct'},
          {
            'type': 'field',
            'ip': ['geoip:ru', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '127.0.0.0/8', 'fc00::/7', 'fe80::/10'],
            'outboundTag': 'direct',
          },
        ],
      },
      'outbounds': [
        {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {'address': 'nl.example.com', 'port': 443, 'id': uuid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'},
          'streamSettings': {
            'network': 'raw',
            'security': 'reality',
            'realitySettings': {'serverName': 'example.org', 'fingerprint': 'chrome', 'password': pbk, 'shortId': 'ab'},
          },
        },
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
    };

ServerEntry fullServer(Map<String, dynamic> config, {bool auto = false}) =>
    ServerEntry(id: 'f', name: 'x', protocol: auto ? 'auto' : 'vless', address: auto ? '' : 'nl.example.com', port: auto ? 0 : 443, full: config, auto: auto);

List<Map<String, dynamic>> listOf(Map<String, dynamic> config, String key) => (config[key] as List).map((e) => (e as Map).cast<String, dynamic>()).toList();
List<Map<String, dynamic>> rulesOf(Map<String, dynamic> config) => listOf((config['routing'] as Map).cast<String, dynamic>(), 'rules');
List<dynamic> dnsServers(Map<String, dynamic> config) => (config['dns'] as Map)['servers'] as List;
Map<String, dynamic> outboundByTag(Map<String, dynamic> config, Object? tag) => listOf(config, 'outbounds').singleWhere((o) => o['tag'] == tag);

/// То, что должно выполняться для любой собранной конфигурации.
void expectTunOnly(Map<String, dynamic> config) {
  final inbounds = listOf(config, 'inbounds');
  expect(inbounds.length, 1);
  expect(inbounds.single['protocol'], 'tun');
  expect(inbounds.single['tag'], 'tun');
  expect(inbounds.single['tag'], tunTag);
  expect(inbounds.single.containsKey('listen'), isFalse);
  expect(inbounds.single.containsKey('port'), isFalse);
  for (final key in ['api', 'stats', 'metrics', 'reverse', 'remarks']) {
    expect(config.containsKey(key), isFalse, reason: key);
  }
  for (final i in inbounds) {
    expect(['socks', 'http', 'mixed', 'dokodemo-door', 'dokodemo'], isNot(contains(i['protocol'])));
  }
  // первое правило: DNS-запросы из туннеля перехватываются
  final first = rulesOf(config).first;
  expect(first['inboundTag'], ['tun']);
  expect('${first['port']}', '53');
  expect(outboundByTag(config, first['outboundTag'])['protocol'], 'dns');
  // теги исходящих каналов не повторяются, первый — прокси
  final tags = listOf(config, 'outbounds').map((o) => o['tag']).toList();
  expect(tags.toSet().length, tags.length);
  expect(listOf(config, 'outbounds').first['protocol'], isNot(anyOf('freedom', 'blackhole', 'dns')));
  // правила не ссылаются на то, чего нет
  final inboundTags = {'tun', (config['dns'] as Map)['tag']};
  for (final r in rulesOf(config)) {
    if (r['outboundTag'] != null) expect(tags, contains(r['outboundTag']), reason: '$r');
    for (final t in (r['inboundTag'] as List?) ?? const []) {
      expect(inboundTags, contains(t), reason: '$r');
    }
  }
  expect(dnsServers(config), isNotEmpty);
  expect(dnsServers(config), isNot(contains('localhost')));
  final text = jsonEncode(config);
  expect(jsonDecode(text), config);
  expect(text, isNot(contains('10808')));
  expect(text, isNot(contains('10809')));
  expect(text, isNot(contains('127.0.0.1')));
}

void main() {
  group('сервер из ссылки', () {
    for (final platform in TunPlatform.values) {
      test('${platform.name}: только вход tun, DNS перехватывается', () {
        final config = buildXrayConfig(linkServer(), AppSettings(), platform);
        expectTunOnly(config);
        final tun = listOf(config, 'inbounds').single;
        final settings = (tun['settings'] as Map).cast<String, dynamic>();
        expect(settings['mtu'], 1500);
        expect((tun['sniffing'] as Map)['enabled'], isTrue);
        expect((tun['sniffing'] as Map)['routeOnly'], isTrue);
        final proxy = listOf(config, 'outbounds').first;
        expect(proxy['tag'], 'proxy');
        expect(proxy['protocol'], 'vless');
        expect((proxy['settings'] as Map)['address'], 'nl.example.com');
        expect(outboundByTag(config, 'direct')['protocol'], 'freedom');
        expect(outboundByTag(config, 'block')['protocol'], 'blackhole');
        expect((config['log'] as Map)['loglevel'], 'warning');
        switch (platform) {
          case TunPlatform.android:
          case TunPlatform.ios:
            // интерфейс создаёт система: ядру нужно только имя, своих адресов и маршрутов оно не задаёт
            expect(settings['name'], isNotEmpty);
            for (final key in ['gateway', 'dns', 'autoSystemRoutingTable', 'autoOutboundsInterface', 'autoSystemDnsToGateway', 'autoSystemWfpBlockLeak']) {
              expect(settings.containsKey(key), isFalse, reason: key);
            }
          case TunPlatform.windows:
            expect(settings['autoSystemRoutingTable'], ['0.0.0.0/0', '::/0']);
            expect(settings['gateway'], isNotEmpty);
            // autoSystemWfpBlockLeak с dns требует своих DNS-серверов на интерфейсе
            expect(settings['autoSystemWfpBlockLeak'], contains('dns'));
            expect(settings['dns'], isNotEmpty);
          case TunPlatform.linux:
            expect(settings['autoSystemRoutingTable'], ['0.0.0.0/0', '::/0']);
            // autoSystemDnsToGateway требует gateway
            expect(settings['autoSystemDnsToGateway'], isTrue);
            expect(settings['gateway'], isNotEmpty);
          case TunPlatform.macos:
            // туннель поднимает служба: ядро само создаёт интерфейс и маршруты, имя задаёт служба
            expect(settings['autoSystemRoutingTable'], ['0.0.0.0/0', '::/0']);
            expect(settings['autoOutboundsInterface'], 'auto');
            expect(settings['gateway'], ['172.19.0.1/30']);
            expect(settings.containsKey('name'), isFalse);
        }
      });
    }

    test('ruDirect=true: российские сайты, адреса и DNS идут напрямую', () {
      final config = buildXrayConfig(linkServer(), AppSettings(ruDirect: true), TunPlatform.android);
      expectTunOnly(config);
      final rules = rulesOf(config);
      final geo = rules.singleWhere((r) => ((r['ip'] as List?) ?? const []).contains('geoip:ru'));
      expect(geo['outboundTag'], 'direct');
      final domains = rules.singleWhere((r) => ((r['domain'] as List?) ?? const []).contains('domain:ru'));
      expect(domains['outboundTag'], 'direct');
      expect(domains['domain'], containsAll(['domain:su', 'domain:xn--p1ai']));
      final direct = dnsServers(config).whereType<Map>().single;
      expect(direct['address'], '77.88.8.8');
      expect(direct['domains'], contains('domain:ru'));
      expect(direct['skipFallback'], isTrue);
      // запросы встроенного DNS к прямому серверу тоже идут мимо туннеля
      final dnsTag = (config['dns'] as Map)['tag'];
      expect(dnsTag, isNotNull);
      final dnsRule = rules.singleWhere((r) => ((r['inboundTag'] as List?) ?? const []).contains(dnsTag));
      expect(dnsRule['ip'], ['77.88.8.8']);
      expect(dnsRule['outboundTag'], 'direct');
      // остальные серверы имён — обычные, запросы к ним уходят в прокси
      expect(dnsServers(config).whereType<String>(), isNotEmpty);
    });

    test('ruDirect=false: ничего российского напрямую', () {
      final config = buildXrayConfig(linkServer(), AppSettings(ruDirect: false), TunPlatform.android);
      expectTunOnly(config);
      final text = jsonEncode(config);
      expect(text, isNot(contains('geoip:ru')));
      expect(text, isNot(contains('domain:ru')));
      expect(text, isNot(contains('77.88.8.8')));
      expect(dnsServers(config).every((s) => s is String), isTrue);
      for (final r in rulesOf(config)) {
        expect(r.containsKey('domain'), isFalse);
      }
    });

    test('локальные адреса идут напрямую при любом значении ruDirect', () {
      for (final ru in [true, false]) {
        final config = buildXrayConfig(linkServer(), AppSettings(ruDirect: ru), TunPlatform.windows);
        final private = rulesOf(config).singleWhere((r) => ((r['ip'] as List?) ?? const []).contains('geoip:private'));
        expect(private['outboundTag'], 'direct');
        expect(private.containsKey('inboundTag'), isFalse);
      }
    });

    test('исходный сервер не меняется', () {
      final server = linkServer();
      final before = jsonEncode(server.toJson());
      final a = buildXrayConfig(server, AppSettings(), TunPlatform.linux);
      (listOf(a, 'outbounds').first['settings'] as Map)['address'] = 'changed.example.com';
      buildProbeConfig(server);
      expect(jsonEncode(server.toJson()), before);
      final b = buildXrayConfig(server, AppSettings(), TunPlatform.linux);
      expect((listOf(b, 'outbounds').first['settings'] as Map)['address'], 'nl.example.com');
    });

    test('все протоколы из ссылок собираются', () {
      for (final link in [
        'vmess://$uuid@example.com:443?type=ws&security=tls',
        'trojan://secret@example.com:443',
        'ss://${base64.encode(utf8.encode('aes-128-gcm:secret'))}@example.com:8388',
        'hysteria2://secret@example.com:443,5000-6000?sni=example.org&obfs=salamander&obfs-password=secret',
        'socks://example.com:1080',
      ]) {
        final config = buildXrayConfig(linkServer(link), AppSettings(), TunPlatform.ios);
        expectTunOnly(config);
        expect(listOf(config, 'outbounds').first['tag'], 'proxy');
      }
    });
  });

  group('готовая конфигурация из подписки', () {
    test('локальные входы убраны, остальное сохранено', () {
      for (final platform in TunPlatform.values) {
        final config = buildXrayConfig(fullServer(template()), AppSettings(), platform);
        expectTunOnly(config);
        expect((config['log'] as Map), {'loglevel': 'warning'});
        // правила подписки идут после перехвата DNS в прежнем порядке
        final rules = rulesOf(config);
        expect(rules.length, 4);
        expect(rules[1], {
          'type': 'field',
          'ip': ['77.88.8.8'],
          'port': '53',
          'outboundTag': 'direct',
        });
        expect(rules[2]['domain'], ruSites);
        expect(rules[3]['ip'], contains('geoip:ru'));
        expect((config['routing'] as Map)['domainStrategy'], 'IPIfNonMatch');
        // DNS подписки не тронут, добавлен только тег
        expect(dnsServers(config), [
          {'address': '77.88.8.8', 'domains': ruSites},
          '1.1.1.1',
          '1.0.0.1',
        ]);
        expect((config['dns'] as Map)['queryStrategy'], 'UseIPv4');
        // исходящие каналы подписки на месте, канал DNS добавлен в конец
        final outbounds = listOf(config, 'outbounds');
        expect(outbounds.map((o) => o['tag']), ['proxy', 'direct', 'block', 'dns-out']);
        expect(outbounds.first, template()['outbounds'][0]);
        expect(outbounds.last['protocol'], 'dns');
      }
    });

    test('настройка ruDirect на готовую конфигурацию не влияет', () {
      final a = buildXrayConfig(fullServer(template()), AppSettings(ruDirect: true), TunPlatform.android);
      final b = buildXrayConfig(fullServer(template()), AppSettings(ruDirect: false), TunPlatform.android);
      expect(a, b);
    });

    test('исходная конфигурация не меняется (глубокая копия)', () {
      final source = template();
      final server = fullServer(source);
      final before = jsonEncode(source);
      final built = buildXrayConfig(server, AppSettings(), TunPlatform.android);
      expect(jsonEncode(source), before);
      expect(jsonEncode(server.full), before);
      // и собранное не делит с исходным вложенные объекты
      (listOf(built, 'outbounds').first['settings'] as Map)['address'] = 'changed.example.com';
      (rulesOf(built)[2]['domain'] as List).add('domain:changed.example.com');
      (dnsServers(built)).add('9.9.9.9');
      buildProbeConfig(server);
      expect(jsonEncode(source), before);
      expect(source['remarks'], '🇳🇱 Netherlands');
      expect((source['inbounds'] as List).length, 2);
    });

    test('правила с inboundTag локальных входов переносятся на tun', () {
      final source = template();
      (source['routing']['rules'] as List).addAll([
        {
          'type': 'field',
          'inboundTag': ['socks'],
          'domain': ['domain:example.net'],
          'outboundTag': 'block',
        },
        {
          'type': 'field',
          'inboundTag': ['socks', 'http'],
          'network': 'udp',
          'port': '443',
          'outboundTag': 'block',
        },
        {'type': 'field', 'inboundTag': 'http', 'port': '25', 'outboundTag': 'block'},
        {'type': 'field', 'inboundTag': 'socks,http', 'port': '26', 'outboundTag': 'block'},
      ]);
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      final rules = rulesOf(config);
      expect(rules.length, 8);
      for (final r in rules.sublist(4)) {
        expect(r['inboundTag'], ['tun']);
        expect(r['outboundTag'], 'block');
      }
      expect(rules[4]['domain'], ['domain:example.net']);
      expect(jsonEncode(rules), isNot(contains('"socks"')));
      expect(jsonEncode(rules), isNot(contains('"http"')));
    });

    test('API, статистика и метрики убраны вместе со своими правилами', () {
      final source = template()
        ..['api'] = {
          'tag': 'api',
          'services': ['HandlerService', 'StatsService'],
        }
        ..['stats'] = <String, dynamic>{}
        ..['metrics'] = {'tag': 'metrics_out'}
        ..['policy'] = {
          'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
        };
      (source['inbounds'] as List).addAll([
        {
          'tag': 'api',
          'listen': '127.0.0.1',
          'port': 10085,
          'protocol': 'dokodemo-door',
          'settings': {'address': '127.0.0.1'},
        },
        {
          'tag': 'metrics_in',
          'listen': '127.0.0.1',
          'port': 10555,
          'protocol': 'dokodemo-door',
          'settings': {'address': '127.0.0.1'},
        },
      ]);
      (source['routing']['rules'] as List).insertAll(0, [
        {
          'type': 'field',
          'inboundTag': ['api'],
          'outboundTag': 'api',
        },
        {
          'type': 'field',
          'inboundTag': ['metrics_in'],
          'outboundTag': 'metrics_out',
        },
        // служебный вход вместе с обычным: остаётся только обычный
        {
          'type': 'field',
          'inboundTag': ['api', 'socks'],
          'port': '8080',
          'outboundTag': 'block',
        },
        // правило только для служебного входа теряет смысл
        {
          'type': 'field',
          'inboundTag': ['api'],
          'port': '8081',
          'outboundTag': 'direct',
        },
      ]);
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      final text = jsonEncode(config);
      expect(text, isNot(contains('10085')));
      expect(text, isNot(contains('10555')));
      expect(text, isNot(contains('metrics')));
      expect(text, isNot(contains('"api"')));
      expect(text, isNot(contains('8081')));
      final rules = rulesOf(config);
      // перехват DNS + одно перенесённое правило + три правила шаблона: ни одно правило не перехватывает весь трафик
      expect(rules.length, 5);
      expect(rules[1], {
        'type': 'field',
        'inboundTag': ['tun'],
        'port': '8080',
        'outboundTag': 'block',
      });
      for (final r in rules.sublist(1)) {
        expect(r.keys.toSet().difference({'type', 'inboundTag', 'outboundTag', 'balancerTag'}), isNotEmpty, reason: 'правило без условий: $r');
      }
    });

    test('свой канал DNS не дублируется и используется для перехвата', () {
      final source = template();
      (source['outbounds'] as List).add({'tag': 'my-dns', 'protocol': 'dns'});
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect(listOf(config, 'outbounds').where((o) => o['protocol'] == 'dns').map((o) => o['tag']), ['my-dns']);
      expect(rulesOf(config).first['outboundTag'], 'my-dns');
    });

    test('нет прямого канала — добавляется', () {
      final source = template();
      (source['outbounds'] as List).removeWhere((o) => o['protocol'] == 'freedom');
      (source['routing']['rules'] as List).clear();
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect(listOf(config, 'outbounds').map((o) => o['protocol']), ['vless', 'blackhole', 'dns', 'freedom']);
    });

    test('сервер имён localhost заменяется и идёт напрямую', () {
      final source = template();
      source['dns'] = {
        'servers': [
          'localhost',
          {
            'address': 'localhost',
            'domains': ['domain:example.net'],
          },
          'https://dns.example.com/dns-query',
        ],
      };
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect(dnsServers(config), [
        '77.88.8.8',
        {
          'address': '77.88.8.8',
          'domains': ['domain:example.net'],
        },
        'https://dns.example.com/dns-query',
      ]);
      final dnsTag = (config['dns'] as Map)['tag'];
      final rule = rulesOf(config)[1];
      expect(rule['inboundTag'], [dnsTag]);
      expect(rule['ip'], ['77.88.8.8']);
      expect(rule['outboundTag'], 'direct');
    });

    test('прямой канал с другим тегом и свой тег DNS', () {
      final source = template();
      source['outbounds'] = [
        (source['outbounds'] as List).first,
        {
          'tag': 'fragment',
          'protocol': 'freedom',
          'settings': {
            'fragment': {'packets': 'tlshello'},
          },
        },
        {'tag': 'bypass', 'protocol': 'freedom'},
      ];
      source['dns'] = {
        'tag': 'my-dns-in',
        'servers': ['localhost'],
      };
      (source['routing']['rules'] as List)
        ..clear()
        ..add({
          'type': 'field',
          'ip': ['geoip:ru'],
          'outboundTag': 'bypass',
        });
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect((config['dns'] as Map)['tag'], 'my-dns-in');
      final rule = rulesOf(config)[1];
      expect(rule['inboundTag'], ['my-dns-in']);
      expect(listOf(config, 'outbounds').firstWhere((o) => o['tag'] == rule['outboundTag'])['protocol'], 'freedom');
    });

    test('нет секции DNS — подставляются свои серверы', () {
      final source = template()..remove('dns');
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect(dnsServers(config), ['1.1.1.1', '8.8.8.8']);
      final empty = template()..['dns'] = {'servers': []};
      expect(dnsServers(buildXrayConfig(fullServer(empty), AppSettings(), TunPlatform.android)), ['1.1.1.1', '8.8.8.8']);
    });

    test('нет входов, маршрутов и DNS вовсе', () {
      final source = {
        'outbounds': [template()['outbounds'][0]],
      };
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.macos);
      expectTunOnly(config);
      expect(rulesOf(config).length, 1);
      expect(listOf(config, 'outbounds').map((o) => o['protocol']), ['vless', 'dns', 'freedom']);
    });

    test('балансировщик и наблюдатель сохраняются', () {
      final source = template();
      final proxy = (source['outbounds'] as List).first as Map<String, dynamic>;
      source['outbounds'] = [
        {...proxy, 'tag': 'proxy-nl'},
        {
          ...proxy,
          'tag': 'proxy-de',
          'settings': {...proxy['settings'] as Map, 'address': 'de.example.com'},
        },
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ];
      final balancers = [
        {
          'tag': 'auto',
          'selector': ['proxy-'],
          'strategy': {'type': 'leastPing'},
          'fallbackTag': 'proxy-nl',
        },
      ];
      final observatory = {
        'subjectSelector': ['proxy-'],
        'probeUrl': 'https://www.gstatic.com/generate_204',
        'probeInterval': '1m',
        'enableConcurrency': true,
      };
      final burst = {
        'subjectSelector': ['proxy-'],
        'pingConfig': {'destination': 'https://www.gstatic.com/generate_204', 'interval': '1m', 'sampling': 2},
      };
      source['routing']['balancers'] = balancers;
      (source['routing']['rules'] as List).add({
        'type': 'field',
        'inboundTag': ['socks', 'http'],
        'balancerTag': 'auto',
      });
      source['observatory'] = observatory;
      source['burstObservatory'] = burst;
      final config = buildXrayConfig(fullServer(source, auto: true), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      expect((config['routing'] as Map)['balancers'], balancers);
      expect(config['observatory'], observatory);
      expect(config['burstObservatory'], burst);
      expect(rulesOf(config).last, {
        'type': 'field',
        'inboundTag': ['tun'],
        'balancerTag': 'auto',
      });
      expect(listOf(config, 'outbounds').map((o) => o['tag']), ['proxy-nl', 'proxy-de', 'direct', 'block', 'dns-out']);
    });

    test('поля не того вида не роняют сборку', () {
      final source = template()
        ..['dns'] = 'нет'
        ..['routing'] = [1, 2]
        ..['inbounds'] = {'x': 1};
      final config = buildXrayConfig(fullServer(source), AppSettings(), TunPlatform.android);
      expectTunOnly(config);
      final rules = template();
      (rules['routing'] as Map)['rules'] = [
        null,
        5,
        'x',
        {'inboundTag': 7, 'outboundTag': 'direct', 'port': '1'},
      ];
      expectTunOnly(buildXrayConfig(fullServer(rules), AppSettings(), TunPlatform.android));
    });
  });

  group('buildProbeConfig', () {
    void expectProbe(Map<String, dynamic> config) {
      expect(config['inbounds'], isEmpty);
      final outbounds = listOf(config, 'outbounds');
      expect(outbounds.length, 1);
      expect(outbounds.single['protocol'], 'vless');
      for (final key in ['dns', 'observatory', 'burstObservatory', 'api', 'stats', 'metrics', 'remarks']) {
        expect(config.containsKey(key), isFalse, reason: key);
      }
      expect((config['routing'] as Map)['rules'], isEmpty);
      expect((config['routing'] as Map).containsKey('balancers'), isFalse);
      expect((config['log'] as Map)['loglevel'], 'none');
      final text = jsonEncode(config);
      expect(jsonDecode(text), config);
      expect(text, isNot(contains('tun')));
      expect(text, isNot(contains('10808')));
    }

    test('сервер из ссылки', () {
      final config = buildProbeConfig(linkServer());
      expectProbe(config);
      expect(listOf(config, 'outbounds').single['tag'], 'proxy');
      expect((listOf(config, 'outbounds').single['settings'] as Map)['address'], 'nl.example.com');
    });

    test('готовая конфигурация', () {
      final config = buildProbeConfig(fullServer(template()));
      expectProbe(config);
      expect(listOf(config, 'outbounds').single, template()['outbounds'][0]);
    });

    test('готовая конфигурация с балансировщиком: берётся proxy или первый канал', () {
      final source = template();
      final proxy = (source['outbounds'] as List).first as Map<String, dynamic>;
      source['outbounds'] = [
        {'tag': 'direct', 'protocol': 'freedom'},
        {...proxy, 'tag': 'proxy-nl'},
        {...proxy, 'tag': 'proxy'},
      ];
      source['routing']['balancers'] = [
        {
          'tag': 'auto',
          'selector': ['proxy'],
        },
      ];
      source['observatory'] = {
        'subjectSelector': ['proxy'],
      };
      source['burstObservatory'] = {
        'subjectSelector': ['proxy'],
      };
      final config = buildProbeConfig(fullServer(source, auto: true));
      expectProbe(config);
      expect(listOf(config, 'outbounds').single['tag'], 'proxy');
      // без тега proxy — первый прокси, а не прямой канал
      (source['outbounds'] as List).removeLast();
      final other = buildProbeConfig(fullServer(source, auto: true));
      expectProbe(other);
      expect(listOf(other, 'outbounds').single['tag'], 'proxy-nl');
    });
  });

  test('уровень журнала задаёт приложение: обычный или подробный', () {
    expect(buildXrayConfig(linkServer(), AppSettings(), TunPlatform.android)['log'], {'loglevel': 'warning'});
    expect(buildXrayConfig(linkServer(), AppSettings(verboseLog: true), TunPlatform.android)['log'], {'loglevel': 'info'});
    expect(AppSettings.fromJson(AppSettings(verboseLog: true).toJson()).verboseLog, isTrue);
    expect(AppSettings.fromJson({}).verboseLog, isFalse);
  });
}
