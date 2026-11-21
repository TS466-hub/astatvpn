// Проверка настоящим ядром: конфигурации, которые собирает приложение, должны проходить `xray run -test`.
// Запуск: XRAY_BIN=/путь/к/xray XRAY_ASSETS=/каталог/с/geoip.dat flutter test test/core_accepts_config_test.dart
// Без XRAY_BIN тесты пропускаются (в обычном прогоне ядра под рукой нет).
import 'dart:convert';
import 'dart:io';

import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/subscription.dart';
import 'package:astatvpn/core/xray_config.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = '11111111-2222-4333-8444-555555555555';
const _pbk = 'SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc';
const _pin = 'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';

final _links = <String, String>{
  'VLESS Reality Vision': 'vless://$_uuid@example.com:443?type=tcp&security=reality&pbk=$_pbk&sid=6ba85179e30d4fc2&sni=addons.mozilla.org&fp=chrome&flow=xtls-rprx-vision#Reality',
  'VLESS XHTTP через CDN': 'vless://$_uuid@cdn.example.com:443?type=xhttp&security=tls&sni=cdn.example.com&path=%2Fx&mode=packet-up'
      '&extra=${Uri.encodeComponent(jsonEncode({
            'uplinkHTTPMethod': 'GET',
            'uplinkDataPlacement': 'header',
            'scMaxEachPostBytes': 6000,
            'scMinPostsIntervalMs': 10,
            'xmux': {'maxConnections': 2, 'hMaxReusableSecs': '1800-3600'},
          }))}#XHTTP',
  'VLESS WebSocket TLS': 'vless://$_uuid@example.com:443?type=ws&security=tls&host=example.com&path=%2Fws&sni=example.com&alpn=http%2F1.1#WS',
  'VLESS gRPC TLS': 'vless://$_uuid@example.com:443?type=grpc&security=tls&serviceName=grpc&sni=example.com#gRPC',
  'Hysteria2 с отпечатком': 'hysteria2://secret@example.com:443?sni=autohitech.shop&insecure=1&pinSHA256=$_pin#Hy2',
  'Hysteria2 с маскировкой и портами': 'hysteria2://secret@example.com:443,5000-6000?sni=example.com&obfs=salamander&obfs-password=longpassword#Hy2hop',
  'Trojan': 'trojan://password@example.com:443?sni=example.com#Trojan',
  'Shadowsocks': 'ss://${base64Url.encode(utf8.encode('chacha20-ietf-poly1305:password'))}@example.com:8388#SS',
  'VMess WebSocket': 'vmess://${base64.encode(utf8.encode(jsonEncode({
        'v': '2',
        'ps': 'VMess',
        'add': 'example.com',
        'port': '443',
        'id': _uuid,
        'net': 'ws',
        'host': 'example.com',
        'path': '/vm',
        'tls': 'tls',
      })))}',
  'SOCKS': 'socks://${base64.encode(utf8.encode('user:pass'))}@example.com:1080#Socks',
};

void main() {
  final bin = Platform.environment['XRAY_BIN'];
  final assets = Platform.environment['XRAY_ASSETS'];
  final skip = bin == null || bin.isEmpty ? 'нет XRAY_BIN' : null;

  Future<void> accepts(Map<String, dynamic> config) async {
    final dir = await Directory.systemTemp.createTemp('astat-core-test');
    try {
      final file = File('${dir.path}/config.json')..writeAsStringSync(jsonEncode(config));
      final r = await Process.run(bin!, ['run', '-test', '-c', file.path], environment: {'XRAY_LOCATION_ASSET': ?assets});
      expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
    } finally {
      await dir.delete(recursive: true);
    }
  }

  // На компьютере, где идёт тест, вход tun потребовал бы прав администратора: проверяем всё остальное.
  Map<String, dynamic> withoutTun(Map<String, dynamic> config) => {...config, 'inbounds': <dynamic>[]};

  for (final e in _links.entries) {
    test('ядро принимает: ${e.key}', () async {
      final server = parseSubscription(e.value).servers.single;
      for (final ru in [true, false]) {
        await accepts(withoutTun(buildXrayConfig(server, AppSettings(ruDirect: ru), TunPlatform.android)));
      }
      await accepts(buildProbeConfig(server));
    }, skip: skip);
  }

  test('ядро принимает готовую конфигурацию подписки с «Авто»', () async {
    Map<String, dynamic> proxy(String tag) => {
          'tag': tag,
          'protocol': 'vless',
          'settings': {
            'vnext': [
              {
                'address': 'example.com',
                'port': 443,
                'users': [
                  {'id': _uuid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'},
                ],
              },
            ],
          },
          'streamSettings': {
            'network': 'raw',
            'security': 'reality',
            'realitySettings': {'serverName': 'addons.mozilla.org', 'fingerprint': 'chrome', 'publicKey': _pbk, 'shortId': '6ba85179e30d4fc2'},
          },
        };
    final full = {
      'remarks': '🇪🇺 Авто',
      'dns': {
        'servers': [
          {
            'address': '77.88.8.8',
            'domains': ['domain:ru'],
          },
          '1.1.1.1',
        ],
        'queryStrategy': 'UseIPv4',
      },
      'inbounds': [
        {
          'tag': 'socks',
          'port': 10808,
          'listen': '127.0.0.1',
          'protocol': 'socks',
          'settings': {'udp': true, 'auth': 'noauth'},
        },
      ],
      'outbounds': [
        proxy('proxy-0'),
        proxy('proxy-1'),
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': {
        'domainStrategy': 'IPIfNonMatch',
        'rules': [
          {
            'type': 'field',
            'ip': ['77.88.8.8'],
            'port': '53',
            'outboundTag': 'direct',
          },
          {
            'type': 'field',
            'domain': ['domain:ru'],
            'outboundTag': 'direct',
          },
          {
            'type': 'field',
            'ip': ['geoip:ru', '10.0.0.0/8'],
            'outboundTag': 'direct',
          },
          {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto'},
        ],
        'balancers': [
          {
            'tag': 'auto',
            'selector': ['proxy-'],
            'strategy': {'type': 'leastPing'},
            'fallbackTag': 'proxy-0',
          },
        ],
      },
      'observatory': {
        'subjectSelector': ['proxy-'],
        'probeUrl': 'https://www.gstatic.com/generate_204',
        'probeInterval': '1m',
        'enableConcurrency': true,
      },
    };
    final server = parseSubscription(jsonEncode([full])).servers.single;
    expect(server.auto, isTrue);
    await accepts(withoutTun(buildXrayConfig(server, AppSettings(), TunPlatform.android)));
  }, skip: skip);

  // Проверка на настоящей подписке: SUB_FILE — путь к сохранённому ответу сервера подписок.
  // Сам ответ в репозиторий не кладём: в нём ключи пользователя.
  final subFile = Platform.environment['SUB_FILE'];
  test('ядро принимает все пункты сохранённой подписки', () async {
    final servers = parseSubscription(File(subFile!).readAsStringSync()).servers;
    expect(servers, isNotEmpty);
    for (final server in servers) {
      for (final platform in [TunPlatform.android, TunPlatform.windows]) {
        final config = buildXrayConfig(server, AppSettings(), platform);
        final inbounds = config['inbounds'] as List;
        expect(inbounds.map((i) => (i as Map)['protocol']), ['tun'], reason: server.name);
        await accepts(withoutTun(config));
      }
    }
  }, skip: skip ?? (subFile == null || subFile.isEmpty ? 'нет SUB_FILE' : null));
}
