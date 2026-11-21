import 'dart:convert';

import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/share_link.dart';
import 'package:astatvpn/core/subscription.dart';
import 'package:flutter_test/flutter_test.dart';

// Все ключи, идентификаторы и адреса выдуманы.
const uuid = '11111111-2222-4333-8444-555555555555';
const pbk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

const vlessLink = 'vless://$uuid@nl.example.com:443?security=reality&pbk=$pbk&sid=ab&sni=example.org&fp=chrome&flow=xtls-rprx-vision#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands';
const hyLink = 'hysteria2://secret@nl.example.com:443?sni=example.org#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20%C2%B7%20Hysteria2';
const trojanLink = 'trojan://secret@de.example.com:8443?sni=de.example.com#Germany';
final ssLink = 'ss://${base64.encode(utf8.encode('aes-128-gcm:secret'))}@fi.example.com:8388#Finland';

final throwsSub = throwsA(isA<SubscriptionException>());

Map<String, dynamic> fullConfig(String remarks, Map<String, dynamic> proxy, {List<Map<String, dynamic>> more = const [], Map<String, dynamic>? routing}) => {
      'remarks': remarks,
      'inbounds': [
        {'tag': 'socks', 'port': 10808, 'listen': '127.0.0.1', 'protocol': 'socks'},
      ],
      'outbounds': [
        proxy,
        ...more,
        {'tag': 'direct', 'protocol': 'freedom'},
        {'tag': 'block', 'protocol': 'blackhole'},
      ],
      'routing': routing ?? {'rules': []},
    };

final flatVless = {
  'tag': 'proxy',
  'protocol': 'vless',
  'settings': {'address': 'nl.example.com', 'port': 443, 'id': uuid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'},
  'streamSettings': {'network': 'raw', 'security': 'reality'},
};

final vnextVless = {
  'tag': 'proxy',
  'protocol': 'vless',
  'settings': {
    'vnext': [
      {
        'address': 'de.example.com',
        'port': 8443,
        'users': [
          {'id': uuid, 'encryption': 'none'},
        ],
      },
    ],
  },
};

final serversTrojan = {
  'tag': 'proxy',
  'protocol': 'trojan',
  'settings': {
    'servers': [
      {'address': '2001:db8::7', 'port': '2053', 'password': 'secret'},
    ],
  },
};

final hysteria = {
  'tag': 'proxy',
  'protocol': 'hysteria',
  'settings': {'version': 2, 'address': 'fi.example.com', 'port': 443},
};

void main() {
  group('ссылки', () {
    test('несколько ссылок в base64', () {
      final body = base64.encode(utf8.encode([vlessLink, hyLink, trojanLink, ssLink].join('\n')));
      final d = parseSubscription(body);
      expect(d.skipped, 0);
      expect(d.servers.map((s) => s.name), ['🇳🇱 Netherlands', '🇳🇱 Netherlands · Hysteria2', 'Germany', 'Finland']);
      expect(d.servers.map((s) => s.protocol), ['vless', 'hysteria2', 'trojan', 'shadowsocks']);
      expect(d.servers.map((s) => s.address), ['nl.example.com', 'nl.example.com', 'de.example.com', 'fi.example.com']);
      expect(d.servers.map((s) => s.port), [443, 443, 8443, 8388]);
      for (final s in d.servers) {
        expect(s.full, isNull);
        expect(s.auto, isFalse);
        expect(s.outbound!['tag'], 'proxy');
        expect(s.delayMs, isNull);
      }
      expect(d.title, isNull);
      expect(d.usedBytes, isNull);
      expect(d.totalBytes, isNull);
      expect(d.expireAt, isNull);
      expect(d.updateHours, isNull);
      expect(d.supportUrl, isNull);
    });

    test('base64 в URL-алфавите без выравнивания, с переносами строк и BOM', () {
      final raw = base64Url.encode(utf8.encode('$vlessLink\r\n$trojanLink\r\n')).replaceAll('=', '');
      final wrapped = raw.replaceAllMapped(RegExp('.{64}'), (m) => '${m[0]}\n');
      for (final body in [raw, wrapped, '﻿$raw', '  $raw\n\n']) {
        final d = parseSubscription(body);
        expect(d.servers.length, 2);
        expect(d.skipped, 0);
      }
    });

    test('ссылки открытым текстом, пустые строки и комментарии не считаются пропусками', () {
      final d = parseSubscription('﻿# подписка\r\n\r\n$vlessLink\r\n  $trojanLink  \r\n// конец\r\n');
      expect(d.servers.map((s) => s.name), ['🇳🇱 Netherlands', 'Germany']);
      expect(d.skipped, 0);
    });

    test('неподдерживаемые строки пропускаются и считаются', () {
      final body = [
        vlessLink,
        'wireguard://key@wg.example.com:51820',
        'tuic://$uuid:pass@tuic.example.com:443',
        'vless://$uuid@bad.example.com:443?security=reality', // нет публичного ключа
        'hysteria2://secret@hy.example.com:443?insecure=1', // без закрепления сертификата
        'vless://',
        'какой-то текст',
        ssLink,
      ].join('\n');
      for (final b in [body, base64.encode(utf8.encode(body))]) {
        final d = parseSubscription(b);
        expect(d.servers.map((s) => s.name), ['🇳🇱 Netherlands', 'Finland']);
        expect(d.skipped, 6);
      }
    });

    test('одни неподдерживаемые строки — ошибка', () {
      expect(() => parseSubscription('wireguard://key@wg.example.com:51820\ntuic://x@y:1'), throwsSub);
      expect(() => parseSubscription('vless://\nss://'), throwsSub);
      expect(() => parseSubscription('просто текст'), throwsSub);
      expect(() => parseSubscription(base64.encode(utf8.encode('привет'))), throwsSub);
      expect(() => parseSubscription('proxies:\n  - name: a\n    type: vless\n'), throwsSub);
    });

    test('одинаковые серверы получают разные идентификаторы', () {
      final d = parseSubscription([vlessLink, vlessLink, trojanLink, vlessLink].join('\n'));
      final ids = d.servers.map((s) => s.id).toList();
      expect(ids.toSet().length, 4);
      expect(ids[1], '${ids[0]}-1');
      expect(ids[3], '${ids[0]}-2');
    });

    test('идентификаторы не меняются между разборами', () {
      final body = [vlessLink, hyLink, vlessLink, trojanLink, ssLink].join('\n');
      final a = parseSubscription(body).servers.map((s) => s.id).toList();
      final b = parseSubscription(base64.encode(utf8.encode(body))).servers.map((s) => s.id).toList();
      expect(a, b);
      expect(a.toSet().length, a.length);
      // перестановка и новые серверы не меняют идентификаторы прежних
      final c = parseSubscription([ssLink, trojanLink, vlessLink].join('\n')).servers;
      expect(c[0].id, a[4]);
      expect(c[1].id, a[3]);
      expect(c[2].id, a[0]);
      final p = parseShareLink(trojanLink);
      expect(a[3], stableId('${p.protocol}|${p.address}|${p.port}|${p.name}'));
    });
  });

  group('готовые конфигурации Xray', () {
    test('массив конфигураций: имя, протокол, адрес и порт', () {
      final body = jsonEncode([
        fullConfig('🇳🇱 Netherlands', flatVless),
        fullConfig('🇩🇪 Germany', vnextVless),
        fullConfig('IPv6', serversTrojan),
        fullConfig('🇫🇮 Finland · Hysteria2', hysteria),
      ]);
      final d = parseSubscription(body);
      expect(d.skipped, 0);
      expect(d.servers.map((s) => s.name), ['🇳🇱 Netherlands', '🇩🇪 Germany', 'IPv6', '🇫🇮 Finland · Hysteria2']);
      expect(d.servers.map((s) => s.protocol), ['vless', 'vless', 'trojan', 'hysteria2']);
      expect(d.servers.map((s) => s.address), ['nl.example.com', 'de.example.com', '2001:db8::7', 'fi.example.com']);
      expect(d.servers.map((s) => s.port), [443, 8443, 2053, 443]);
      for (final s in d.servers) {
        expect(s.outbound, isNull);
        expect(s.auto, isFalse);
        expect(s.full!['outbounds'], isA<List>());
        expect(() => jsonEncode(s.toJson()), returnsNormally);
      }
      expect(d.servers.map((s) => s.id).toSet().length, 4);
      expect(parseSubscription(body).servers.map((s) => s.id), d.servers.map((s) => s.id));
    });

    test('одна конфигурация объектом, с пробелами и BOM вокруг', () {
      final d = parseSubscription('﻿  ${jsonEncode(fullConfig('Один', flatVless))}\n');
      expect(d.servers.single.name, 'Один');
      expect(d.servers.single.address, 'nl.example.com');
    });

    test('без remarks именем становится адрес', () {
      final config = fullConfig('', flatVless)..remove('remarks');
      expect(parseSubscription(jsonEncode([config])).servers.single.name, 'nl.example.com');
      final blank = fullConfig('   ', flatVless);
      expect(parseSubscription(jsonEncode([blank])).servers.single.name, 'nl.example.com');
    });

    test('основным считается исходящий канал с тегом proxy', () {
      final config = fullConfig('Порядок', {...vnextVless, 'tag': 'other'}, more: [flatVless]);
      final s = parseSubscription(jsonEncode([config])).servers.single;
      expect(s.address, 'nl.example.com');
      expect(s.auto, isFalse);
    });

    test('балансировщик и несколько прокси — это «Авто»', () {
      final config = fullConfig(
        '🇪🇺 Авто',
        {...flatVless, 'tag': 'proxy-1'},
        more: [
          {...vnextVless, 'tag': 'proxy-2'},
          {...hysteria, 'tag': 'proxy-3'},
        ],
        routing: {
          'balancers': [
            {
              'tag': 'auto',
              'selector': ['proxy-'],
              'strategy': {'type': 'leastPing'},
            },
          ],
          'rules': [
            {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto'},
          ],
        },
      )..['observatory'] = {
          'subjectSelector': ['proxy-'],
          'probeUrl': 'https://www.gstatic.com/generate_204',
          'probeInterval': '1m',
        };
      final d = parseSubscription(jsonEncode([config, fullConfig('🇳🇱 Netherlands', flatVless)]));
      final auto = d.servers.first;
      expect(auto.auto, isTrue);
      expect(auto.protocol, 'auto');
      expect(auto.name, '🇪🇺 Авто');
      expect(auto.address, '');
      expect(auto.port, 0);
      expect(auto.full!['observatory'], isNotNull);
      expect(d.servers.last.auto, isFalse);
      // балансировщик с единственным прокси — обычный сервер
      final single = fullConfig('Один', flatVless, routing: {
        'balancers': [
          {
            'tag': 'auto',
            'selector': ['proxy'],
          },
        ],
        'rules': [],
      });
      expect(parseSubscription(jsonEncode([single])).servers.single.auto, isFalse);
      // несколько прокси без балансировщика — тоже
      final chain = fullConfig('Цепочка', flatVless, more: [
        {...vnextVless, 'tag': 'hop'},
      ]);
      expect(parseSubscription(jsonEncode([chain])).servers.single.auto, isFalse);
    });

    test('элементы без прокси пропускаются и считаются', () {
      final body = jsonEncode([
        fullConfig('🇳🇱 Netherlands', flatVless),
        {
          'remarks': 'только прямой',
          'outbounds': [
            {'tag': 'direct', 'protocol': 'freedom'},
          ],
        },
        {'remarks': 'пусто'},
        42,
        null,
        'строка',
        [],
      ]);
      final d = parseSubscription(body);
      expect(d.servers.single.name, '🇳🇱 Netherlands');
      expect(d.skipped, 6);
    });

    test('искажённая структура не роняет разбор', () {
      final body = jsonEncode([
        {'remarks': 'a', 'outbounds': 'нет'},
        {'remarks': 'b', 'outbounds': {'tag': 'proxy'}},
        {
          'remarks': 'c',
          'outbounds': [
            null,
            7,
            {'protocol': 42},
            {'protocol': 'vless', 'settings': 'строка'},
          ],
          'routing': 'нет',
        },
        {
          'remarks': {'x': 1},
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {
                'vnext': 'нет',
                'servers': [5],
                'address': ['a'],
                'port': {'p': 1},
              },
            },
          ],
          'routing': {'balancers': 'нет'},
        },
        {
          'remarks': 'e',
          'outbounds': [
            {
              'protocol': 'vless',
              'settings': {'vnext': []},
            },
            {'protocol': 'trojan'},
          ],
          'routing': {
            'balancers': {'a': 1},
          },
        },
      ]);
      late SubscriptionData d;
      expect(() => d = parseSubscription(body), returnsNormally);
      expect(d.skipped, 2);
      expect(d.servers.length, 3);
      for (final s in d.servers) {
        expect(s.port, 0);
        expect(s.auto, isFalse);
        expect(s.name, isNotEmpty);
      }
      expect(d.servers.first.name, 'c');
    });

    test('пустой массив, ответ с ошибкой и повреждённый JSON', () {
      expect(() => parseSubscription('[]'), throwsSub);
      expect(() => parseSubscription('{}'), throwsSub);
      expect(() => parseSubscription('{"error":"not found"}'), throwsSub);
      expect(() => parseSubscription('[{"outbounds":'), throwsSub);
      expect(() => parseSubscription('{'), throwsSub);
    });
  });

  group('outboundEndpoint', () {
    test('плоский вид, vnext и servers', () {
      expect(outboundEndpoint(flatVless), ('nl.example.com', 443));
      expect(outboundEndpoint(vnextVless), ('de.example.com', 8443));
      expect(outboundEndpoint(serversTrojan), ('2001:db8::7', 2053));
      expect(outboundEndpoint(hysteria), ('fi.example.com', 443));
    });

    test('нет настроек или они не того вида', () {
      expect(outboundEndpoint({'protocol': 'freedom'}), ('', 0));
      expect(outboundEndpoint({'protocol': 'vless', 'settings': null}), ('', 0));
      expect(outboundEndpoint({'protocol': 'vless', 'settings': 'x'}), ('', 0));
      expect(outboundEndpoint({'protocol': 'vless', 'settings': <String, dynamic>{}}), ('', 0));
      expect(
        outboundEndpoint({
          'settings': {'address': 'a.example.com', 'port': 443.0},
        }),
        ('a.example.com', 443),
      );
      expect(
        outboundEndpoint({
          'settings': {'address': 'a.example.com', 'port': 'abc'},
        }),
        ('a.example.com', 0),
      );
    });
  });

  group('ошибки', () {
    test('пустой ответ', () {
      for (final body in ['', '   ', '\n\r\n\t', '﻿']) {
        expect(() => parseSubscription(body), throwsSub, reason: jsonEncode(body));
      }
    });

    test('страница HTML вместо подписки', () {
      for (final body in [
        '<!DOCTYPE html><html><head><title>Sign in</title></head><body></body></html>',
        '\n  <html><body>vless://$uuid@nl.example.com:443</body></html>',
        '<?xml version="1.0"?><error/>',
      ]) {
        expect(() => parseSubscription(body), throwsSub, reason: body);
      }
      try {
        parseSubscription('<html></html>');
        fail('должно быть исключение');
      } on SubscriptionException catch (e) {
        expect(e.message, contains('страница'));
        expect(e.toString(), e.message);
      }
    });

    test('никаких исключений, кроме SubscriptionException', () {
      for (final body in [
        'null',
        'true',
        '0',
        '"vless://x"',
        '[[[[[[',
        '[1,2,3]',
        '[null]',
        '{"outbounds":[{"protocol":"vless","settings":[]}]}',
        '{"outbounds":[{"protocol":"vless","settings":{"vnext":[null]}}],"routing":[]}',
        '{"outbounds":{"0":{"protocol":"vless"}}}',
        '====',
        '%%%%',
        'vless://\nvmess://\ntrojan://\nss://\nhysteria2://\nhy2://\nsocks://',
        'A' * 100000,
        '\u0000\u0001\u0002',
      ]) {
        final shown = body.length > 60 ? '${body.substring(0, 60)}…' : body;
        try {
          final d = parseSubscription(body, {'subscription-userinfo': ';;=;a=b=c;expire=99999999999999999999;total=-5', 'profile-title': 'base64:!!!', 'profile-update-interval': 'x'});
          expect(d.servers, isNotEmpty, reason: shown);
        } on SubscriptionException catch (e) {
          expect(e.message, isNotEmpty);
        } catch (e) {
          fail('«$shown»: ${e.runtimeType}: $e');
        }
      }
    });
  });

  group('заголовки', () {
    test('subscription-userinfo', () {
      final d = parseSubscription(vlessLink, {'subscription-userinfo': 'upload=1024; download=2048; total=10737418240; expire=1767225600'});
      expect(d.usedBytes, 3072);
      expect(d.totalBytes, 10737418240);
      expect(d.expireAt!.toUtc(), DateTime.utc(2026, 1, 1));
    });

    test('subscription-userinfo: без пробелов, без срока, безлимит, частичные данные', () {
      final a = parseSubscription(vlessLink, {'subscription-userinfo': 'upload=0;download=0;total=0;expire=0'});
      expect(a.usedBytes, 0);
      expect(a.totalBytes, 0);
      expect(a.expireAt, isNull);
      final b = parseSubscription(vlessLink, {'subscription-userinfo': 'download=500'});
      expect(b.usedBytes, 500);
      expect(b.totalBytes, isNull);
      expect(b.expireAt, isNull);
      final c = parseSubscription(vlessLink, {'subscription-userinfo': 'UPLOAD=1; Download = 2 ; total=abc; expire='});
      expect(c.usedBytes, 3);
      expect(c.totalBytes, isNull);
      expect(c.expireAt, isNull);
      final e = parseSubscription(vlessLink, {'subscription-userinfo': ''});
      expect(e.usedBytes, isNull);
    });

    test('subscription-userinfo: срок за пределами допустимого не роняет разбор', () {
      for (final expire in ['99999999999999999', '9223372036854775807', '-1', '8640000000001']) {
        final d = parseSubscription(vlessLink, {'subscription-userinfo': 'upload=1; download=1; total=1; expire=$expire'});
        expect(d.expireAt, isNull, reason: expire);
        expect(d.usedBytes, 2, reason: expire);
      }
    });

    test('profile-title открытым текстом и в base64', () {
      expect(parseSubscription(vlessLink, {'profile-title': 'AstatVPN'}).title, 'AstatVPN');
      expect(parseSubscription(vlessLink, {'profile-title': 'base64:${base64.encode(utf8.encode('AstatVPN 🚀 подписка'))}'}).title, 'AstatVPN 🚀 подписка');
      expect(parseSubscription(vlessLink, {'profile-title': '  base64:${base64Url.encode(utf8.encode('Астат')).replaceAll('=', '')}  '}).title, 'Астат');
      expect(parseSubscription(vlessLink, {'profile-title': '%D0%90%D1%81%D1%82%D0%B0%D1%82%20VPN'}).title, 'Астат VPN');
      expect(parseSubscription(vlessLink, {'profile-title': 'Скидка 100% навсегда'}).title, 'Скидка 100% навсегда');
      expect(parseSubscription(vlessLink, {'profile-title': 'base64:!!!'}).title, isNull);
      expect(parseSubscription(vlessLink, {'profile-title': 'base64:'}).title, isNull);
      expect(parseSubscription(vlessLink, {'profile-title': '   '}).title, isNull);
    });

    test('profile-update-interval', () {
      expect(parseSubscription(vlessLink, {'profile-update-interval': '1'}).updateHours, 1);
      expect(parseSubscription(vlessLink, {'profile-update-interval': ' 12 '}).updateHours, 12);
      for (final bad in ['0', '-3', 'abc', '', '1.5']) {
        expect(parseSubscription(vlessLink, {'profile-update-interval': bad}).updateHours, isNull, reason: bad);
      }
    });

    test('support-url: адрес не искажается', () {
      expect(parseSubscription(vlessLink, {'support-url': 'https://t.me/example_bot'}).supportUrl, 'https://t.me/example_bot');
      expect(parseSubscription(vlessLink, {'support-url': ' https://example.com/help?q=a%20b%26c '}).supportUrl, 'https://example.com/help?q=a%20b%26c');
      expect(parseSubscription(vlessLink, {'support-url': ''}).supportUrl, isNull);
    });

    test('announce', () {
      expect(parseSubscription(vlessLink, {'announce': 'base64:${base64.encode(utf8.encode('Работы до 12:00'))}'}).announce, 'Работы до 12:00');
      expect(parseSubscription(vlessLink).announce, isNull);
    });

    test('имена заголовков в любом регистре', () {
      final d = parseSubscription(vlessLink, {
        'Subscription-Userinfo': 'upload=1; download=2; total=3; expire=1767225600',
        'PROFILE-TITLE': 'AstatVPN',
        'Profile-Update-Interval': '6',
        'Support-URL': 'https://t.me/example_bot',
        'Content-Type': 'text/plain',
      });
      expect(d.usedBytes, 3);
      expect(d.totalBytes, 3);
      expect(d.expireAt, isNotNull);
      expect(d.title, 'AstatVPN');
      expect(d.updateHours, 6);
      expect(d.supportUrl, 'https://t.me/example_bot');
    });

    test('заголовки работают и с готовыми конфигурациями', () {
      final d = parseSubscription(jsonEncode([fullConfig('a', flatVless)]), {'profile-title': 'AstatVPN', 'profile-update-interval': '1'});
      expect(d.title, 'AstatVPN');
      expect(d.updateHours, 1);
    });
  });
}
