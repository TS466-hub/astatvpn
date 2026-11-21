import 'dart:convert';
import 'dart:math';

import 'package:astatvpn/core/share_link.dart';
import 'package:flutter_test/flutter_test.dart';

// Все ключи, идентификаторы и адреса выдуманы.
const uuid = '11111111-2222-4333-8444-555555555555';
const pbk = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
final pinHex = 'ab' * 32;
final pinColons = List.filled(32, 'AB').join(':');

Map<String, dynamic> settingsOf(ParsedLink p) => (p.outbound['settings'] as Map).cast<String, dynamic>();
Map<String, dynamic> streamOf(ParsedLink p) => (p.outbound['streamSettings'] as Map).cast<String, dynamic>();
Map<String, dynamic> sub(Map<String, dynamic> m, String key) => (m[key] as Map).cast<String, dynamic>();

String b64(String s) => base64.encode(utf8.encode(s));
String b64url(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');

final throwsShare = throwsA(isA<ShareLinkException>());

void main() {
  group('общее', () {
    test('isShareLink узнаёт все схемы', () {
      for (final s in shareSchemes) {
        expect(isShareLink('${s}x@example.com'), isTrue, reason: s);
        expect(isShareLink('   ${s}x@example.com'), isTrue, reason: s);
      }
      expect(isShareLink('https://example.com'), isFalse);
      expect(isShareLink(''), isFalse);
      expect(isShareLink('# vless://x'), isFalse);
    });

    test('decodeBase64Text: обычный и URL-алфавит, без выравнивания, с переносами', () {
      expect(decodeBase64Text(b64('привет, мир?>')), 'привет, мир?>');
      expect(decodeBase64Text(b64url('привет, мир?>')), 'привет, мир?>');
      final wrapped = b64('a' * 100).replaceAllMapped(RegExp('.{20}'), (m) => '${m[0]}\r\n');
      expect(decodeBase64Text(wrapped), 'a' * 100);
      expect(decodeBase64Text(''), isNull);
      expect(decodeBase64Text('   '), isNull);
      expect(decodeBase64Text('vless://x@y'), isNull);
      expect(decodeBase64Text('abcde'), isNull);
      expect(decodeBase64Text('===='), isNull);
    });

    test('исходящий канал всегда с тегом proxy и кодируется в JSON', () {
      for (final link in [
        'vless://$uuid@example.com:443?security=reality&pbk=$pbk&sid=ab&sni=example.org&fp=chrome&flow=xtls-rprx-vision#a',
        'vmess://$uuid@example.com:443?type=ws&security=tls',
        'trojan://secret@example.com:443',
        'ss://${b64('aes-128-gcm:secret')}@example.com:8388',
        'hysteria2://secret@example.com:443?sni=example.org',
        'hy2://secret@example.com',
        'socks://example.com:1080',
      ]) {
        final p = parseShareLink(link);
        expect(p.outbound['tag'], 'proxy', reason: link);
        expect(() => jsonEncode(p.outbound), returnsNormally, reason: link);
        expect(p.address, 'example.com', reason: link);
      }
    });

    test('пробелы и перенос строки вокруг ссылки, схема в верхнем регистре', () {
      final p = parseShareLink('  \tVLESS://$uuid@example.com:443?security=none#x\r\n');
      expect(p.protocol, 'vless');
      expect(p.name, 'x');
    });
  });

  group('VLESS', () {
    test('Reality + Vision', () {
      final p = parseShareLink(
        'vless://$uuid@example.com:8443?encryption=none&security=reality&type=tcp&sni=www.example.org&pbk=$pbk&sid=abcd1234&fp=firefox&flow=xtls-rprx-vision&spx=%2Fpath#Reality',
      );
      expect(p.name, 'Reality');
      expect(p.protocol, 'vless');
      expect(p.address, 'example.com');
      expect(p.port, 8443);
      expect(p.outbound['protocol'], 'vless');
      // плоский вид VLessOutboundConfig: {address, port, id, flow, encryption}
      expect(settingsOf(p), {'address': 'example.com', 'port': 8443, 'id': uuid, 'encryption': 'none', 'flow': 'xtls-rprx-vision'});
      final s = streamOf(p);
      expect(s['network'], 'raw');
      expect(s['security'], 'reality');
      expect(s.containsKey('tlsSettings'), isFalse);
      final r = sub(s, 'realitySettings');
      expect(r['serverName'], 'www.example.org');
      expect(r['fingerprint'], 'firefox');
      expect(r['password'], pbk);
      expect(r['shortId'], 'abcd1234');
      expect(r['spiderX'], '/path');
    });

    test('Reality без fp получает chrome, без sid — пустой shortId, без sni — адрес сервера', () {
      final r = sub(streamOf(parseShareLink('vless://$uuid@example.com:443?security=reality&pbk=$pbk')), 'realitySettings');
      expect(r['fingerprint'], 'chrome');
      expect(r['shortId'], '');
      expect(r['serverName'], 'example.com');
    });

    test('Reality без публичного ключа отклоняется', () {
      expect(() => parseShareLink('vless://$uuid@example.com:443?security=reality&sni=example.org'), throwsShare);
    });

    test('Reality: то, с чем ядро не запустится, отклоняется сразу', () {
      for (final q in [
        'pbk=invalid',
        'pbk=${pbk}A',
        'pbk=${pbk.substring(1)}',
        'pbk=$pbk&sid=abc',
        'pbk=$pbk&sid=zz',
        'pbk=$pbk&sid=0123456789abcdef01',
        'pbk=$pbk&type=ws',
        'pbk=$pbk&type=httpupgrade',
        'pbk=$pbk&type=kcp',
      ]) {
        expect(() => parseShareLink('vless://$uuid@example.com:443?security=reality&$q'), throwsShare, reason: q);
      }
      for (final q in ['pbk=$pbk&sid=0123456789abcdef', 'pbk=$pbk&sid=', 'pbk=$pbk&type=xhttp&path=%2Fx', 'pbk=$pbk&type=grpc&serviceName=s', 'pbk=${'-_' * 21}A']) {
        expect(streamOf(parseShareLink('vless://$uuid@example.com:443?security=reality&$q'))['security'], 'reality', reason: q);
      }
      // spiderX обязан начинаться с «/»: иное значение не передаётся
      final r = sub(streamOf(parseShareLink('vless://$uuid@example.com:443?security=reality&pbk=$pbk&spx=path')), 'realitySettings');
      expect(r.containsKey('spiderX'), isFalse);
    });

    test('XHTTP c extra, VLESS Encryption и TLS', () {
      const enc = 'mlkem768x25519plus.native.1rtt.QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo';
      final extra = {
        'uplinkHTTPMethod': 'GET',
        'uplinkDataPlacement': 'header',
        'scMaxEachPostBytes': 6000,
        'scMinPostsIntervalMs': 10,
        'xmux': {'maxConnections': 2, 'hMaxReusableSecs': '1800-3600'},
        'headers': {'X-Test': 'a + b / c'},
      };
      final link = 'vless://$uuid@cdn.example.com:443?encryption=$enc&type=xhttp&security=tls&sni=cdn.example.com&fp=chrome&alpn=h2%2Chttp%2F1.1'
          '&host=cdn.example.com&path=%2Fup%20load&mode=packet-up&extra=${Uri.encodeQueryComponent(jsonEncode(extra))}#%F0%9F%87%B3%F0%9F%87%B1%20%D0%9E%D0%B1%D1%85%D0%BE%D0%B4';
      final p = parseShareLink(link);
      expect(p.name, '🇳🇱 Обход');
      expect(settingsOf(p)['encryption'], enc);
      expect(settingsOf(p).containsKey('flow'), isFalse);
      final s = streamOf(p);
      expect(s['network'], 'xhttp');
      expect(s['security'], 'tls');
      final x = sub(s, 'xhttpSettings');
      expect(x['host'], 'cdn.example.com');
      expect(x['path'], '/up load');
      expect(x['mode'], 'packet-up');
      expect(x['extra'], extra);
      final t = sub(s, 'tlsSettings');
      expect(t['serverName'], 'cdn.example.com');
      expect(t['fingerprint'], 'chrome');
      expect(t['alpn'], ['h2', 'http/1.1']);
      expect(t.containsKey('allowInsecure'), isFalse);
    });

    test('splithttp — это xhttp; повреждённый или не объектный extra отклоняется', () {
      expect(streamOf(parseShareLink('vless://$uuid@example.com:443?type=splithttp&path=%2Fx'))['network'], 'xhttp');
      expect(() => parseShareLink('vless://$uuid@example.com:443?type=xhttp&extra=%7B'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@example.com:443?type=xhttp&extra=123'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@example.com:443?type=xhttp&extra=%5B1%5D'), throwsShare);
    });

    test('WebSocket + TLS', () {
      final p = parseShareLink(
        'vless://$uuid@edge.example.com:443?encryption=none&type=ws&path=%2Fws%3Fed%3D2048&host=cdn.example.com&security=tls&sni=edge.example.com&alpn=h2%2Ch3&fp=chrome&vcn=edge.example.com',
      );
      final s = streamOf(p);
      expect(s['network'], 'ws');
      expect(sub(s, 'wsSettings'), {'path': '/ws?ed=2048', 'host': 'cdn.example.com'});
      final t = sub(s, 'tlsSettings');
      expect(t['serverName'], 'edge.example.com');
      expect(t['alpn'], ['h2', 'h3']);
      expect(t['verifyPeerCertByName'], 'edge.example.com');
    });

    test('websocket — синоним ws', () {
      expect(streamOf(parseShareLink('vless://$uuid@example.com:443?type=websocket&path=%2F'))['network'], 'ws');
    });

    test('gRPC', () {
      final s = streamOf(parseShareLink('vless://$uuid@example.com:443?type=grpc&serviceName=svc&authority=auth.example.com&mode=multi&security=tls'));
      expect(s['network'], 'grpc');
      expect(sub(s, 'grpcSettings'), {'authority': 'auth.example.com', 'serviceName': 'svc', 'multiMode': true});
      final gun = streamOf(parseShareLink('vless://$uuid@example.com:443?type=grpc&serviceName=svc&mode=gun'));
      expect(sub(gun, 'grpcSettings'), {'serviceName': 'svc'});
    });

    test('HTTPUpgrade', () {
      final s = streamOf(parseShareLink('vless://$uuid@example.com:443?type=httpupgrade&path=%2Fup&host=h.example.com'));
      expect(s['network'], 'httpupgrade');
      expect(sub(s, 'httpupgradeSettings'), {'path': '/up', 'host': 'h.example.com'});
      expect(s['security'], 'none');
    });

    test('RAW с заголовком HTTP', () {
      final s = streamOf(parseShareLink('vless://$uuid@example.com:80?type=tcp&headerType=http&path=%2Fa%2C%2Fb&host=h1.example.com%2Ch2.example.com'));
      expect(s['network'], 'raw');
      expect(sub(s, 'rawSettings'), {
        'header': {
          'type': 'http',
          'request': {
            'path': ['/a', '/b'],
            'headers': {
              'Host': ['h1.example.com', 'h2.example.com'],
            },
          },
        },
      });
    });

    test('mKCP', () {
      final s = streamOf(parseShareLink('vless://$uuid@example.com:443?type=kcp&mtu=1350&tti=20'));
      expect(s['network'], 'kcp');
      expect(sub(s, 'kcpSettings'), {'mtu': 1350, 'tti': 20});
      expect(streamOf(parseShareLink('vless://$uuid@example.com:443?type=mkcp')).containsKey('kcpSettings'), isFalse);
    });

    test('finalmask из параметра fm', () {
      const fm = '{"udp":[{"type":"noise","settings":{}}]}';
      final s = streamOf(parseShareLink('vless://$uuid@example.com:443?type=tcp&fm=${Uri.encodeQueryComponent(fm)}'));
      expect(s['finalmask'], jsonDecode(fm));
      expect(() => parseShareLink('vless://$uuid@example.com:443?fm=%7B'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@example.com:443?fm=5'), throwsShare);
    });

    test('без параметров: RAW без защиты, шифрование none', () {
      final p = parseShareLink('vless://$uuid@example.com:443');
      expect(settingsOf(p), {'address': 'example.com', 'port': 443, 'id': uuid, 'encryption': 'none'});
      expect(streamOf(p), {'network': 'raw', 'security': 'none'});
      expect(p.name, 'example.com');
    });

    test('IPv6 в скобках', () {
      final p = parseShareLink('vless://$uuid@[2001:db8::1]:8443?security=tls&sni=example.com#v6');
      expect(p.address, '2001:db8::1');
      expect(p.port, 8443);
      expect(settingsOf(p)['address'], '2001:db8::1');
      expect(sub(streamOf(p), 'tlsSettings')['serverName'], 'example.com');
      expect(() => parseShareLink('vless://$uuid@[2001:db8::1:443'), throwsShare);
    });

    test('порт не указан — 443; неверный порт отклоняется', () {
      expect(parseShareLink('vless://$uuid@example.com?security=tls').port, 443);
      expect(parseShareLink('vless://$uuid@example.com:?security=tls').port, 443);
      expect(parseShareLink('vless://$uuid@[2001:db8::1]').port, 443);
      for (final bad in ['65536', '99999', '-1', 'abc', '4 43']) {
        expect(() => parseShareLink('vless://$uuid@example.com:$bad'), throwsShare, reason: bad);
      }
    });

    test('имена: проценты, кириллица, эмодзи, решётка и одинокий знак процента', () {
      String name(String fragment) => parseShareLink('vless://$uuid@example.com:443#$fragment').name;
      expect(name('%D0%9C%D0%BE%D1%81%D0%BA%D0%B2%D0%B0%20%231'), 'Москва #1');
      expect(name('🇩🇪 Германия · Hysteria2'), '🇩🇪 Германия · Hysteria2');
      expect(name('%F0%9F%87%AB%F0%9F%87%AE%20Finland'), '🇫🇮 Finland');
      expect(name('Server #1'), 'Server #1');
      expect(name('100% fast'), '100% fast');
      expect(name('a+b'), 'a+b');
      expect(name('%20%20'), 'example.com');
      expect(name(''), 'example.com');
    });

    test('идентификатор в процентах раскодируется', () {
      expect(settingsOf(parseShareLink('vless://my%20secret%40id@example.com:443'))['id'], 'my secret@id');
    });

    test('нет идентификатора или адреса', () {
      expect(() => parseShareLink('vless://example.com:443'), throwsShare);
      expect(() => parseShareLink('vless://@example.com:443'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@:443'), throwsShare);
    });

    test('адрес с недопустимыми знаками отклоняется', () {
      expect(() => parseShareLink('vless://$uuid@exa mple.com:443'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@сервер.рф:443'), throwsShare);
    });

    test('неизвестные транспорт и защита отклоняются', () {
      for (final q in ['type=h2', 'type=quic', 'type=nonsense', 'security=xtls', 'security=nonsense']) {
        expect(() => parseShareLink('vless://$uuid@example.com:443?$q'), throwsShare, reason: q);
      }
    });

    test('TLS: закрепление сертификата pcs, список через запятую', () {
      final t = sub(streamOf(parseShareLink('vless://$uuid@example.com:443?security=tls&pcs=$pinColons,${'01' * 32}')), 'tlsSettings');
      expect(t['pinnedPeerCertSha256'], '$pinHex,${'01' * 32}');
      expect(() => parseShareLink('vless://$uuid@example.com:443?security=tls&pcs=not-a-pin'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@example.com:443?security=tls&pcs=abcd'), throwsShare);
    });

    test('allowInsecure без закрепления сертификата отклоняется, со значением 0 — нет', () {
      expect(() => parseShareLink('vless://$uuid@example.com:443?security=tls&allowInsecure=1'), throwsShare);
      expect(() => parseShareLink('vless://$uuid@example.com:443?security=tls&insecure=true'), throwsShare);
      final ok = parseShareLink('vless://$uuid@example.com:443?security=tls&allowInsecure=0');
      expect(sub(streamOf(ok), 'tlsSettings').containsKey('allowInsecure'), isFalse);
      final pinned = parseShareLink('vless://$uuid@example.com:443?security=tls&allowInsecure=1&pcs=$pinHex');
      expect(sub(streamOf(pinned), 'tlsSettings')['pinnedPeerCertSha256'], pinHex);
      expect(sub(streamOf(pinned), 'tlsSettings').containsKey('allowInsecure'), isFalse);
    });
  });

  group('VMess', () {
    test('старый формат base64(JSON)', () {
      final j = {
        'v': '2',
        'ps': 'Старый VMess',
        'add': 'vm.example.com',
        'port': '8443',
        'id': uuid,
        'aid': '0',
        'scy': 'aes-128-gcm',
        'net': 'ws',
        'type': 'none',
        'host': 'cdn.example.com',
        'path': '/ws',
        'tls': 'tls',
        'sni': 'sni.example.com',
        'alpn': 'h2,http/1.1',
        'fp': 'chrome',
      };
      for (final body in [b64(jsonEncode(j)), b64url(jsonEncode(j))]) {
        final p = parseShareLink('vmess://$body');
        expect(p.name, 'Старый VMess');
        expect(p.protocol, 'vmess');
        expect(p.address, 'vm.example.com');
        expect(p.port, 8443);
        expect(p.outbound['protocol'], 'vmess');
        expect(settingsOf(p), {'address': 'vm.example.com', 'port': 8443, 'id': uuid, 'security': 'aes-128-gcm'});
        final s = streamOf(p);
        expect(s['network'], 'ws');
        expect(sub(s, 'wsSettings'), {'path': '/ws', 'host': 'cdn.example.com'});
        expect(s['security'], 'tls');
        expect(sub(s, 'tlsSettings'), {
          'serverName': 'sni.example.com',
          'fingerprint': 'chrome',
          'alpn': ['h2', 'http/1.1'],
        });
      }
    });

    test('старый формат: порт числом, tcp без TLS, имя по умолчанию', () {
      final p = parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': 443, 'id': uuid, 'net': 'tcp'}))}');
      expect(p.name, 'vm.example.com');
      expect(p.port, 443);
      expect(settingsOf(p)['security'], 'auto');
      expect(streamOf(p), {'network': 'raw', 'security': 'none'});
    });

    test('старый формат: gRPC берёт serviceName из path', () {
      final p = parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': '443', 'id': uuid, 'net': 'grpc', 'path': 'svc', 'tls': 'tls'}))}');
      expect(sub(streamOf(p), 'grpcSettings')['serviceName'], 'svc');
    });

    test('старый формат: неполные и повреждённые данные', () {
      expect(() => parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': '443'}))}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64(jsonEncode({'add': '', 'port': '443', 'id': uuid}))}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': '70000', 'id': uuid}))}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': 'x', 'id': uuid}))}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64('[1,2,3]')}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64('"строка"')}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64('{не json')}'), throwsShare);
      expect(() => parseShareLink('vmess://${b64(jsonEncode({'add': 'vm.example.com', 'port': '443', 'id': uuid, 'net': 'h2'}))}'), throwsShare);
    });

    test('новый формат в виде URL', () {
      final p = parseShareLink('vmess://$uuid@vm.example.com:8443?encryption=auto&type=ws&host=ws.example.com&path=%2Fw&security=tls&sni=tls.example.com&alpn=h2%2Ch3&fp=safari#VMessAEAD');
      expect(p.name, 'VMessAEAD');
      expect(p.protocol, 'vmess');
      expect(settingsOf(p), {'address': 'vm.example.com', 'port': 8443, 'id': uuid, 'security': 'auto'});
      final s = streamOf(p);
      expect(sub(s, 'wsSettings'), {'path': '/w', 'host': 'ws.example.com'});
      expect(sub(s, 'tlsSettings')['serverName'], 'tls.example.com');
      expect(sub(s, 'tlsSettings')['fingerprint'], 'safari');
    });

    test('новый формат: шифрование по умолчанию auto, заданное сохраняется', () {
      expect(settingsOf(parseShareLink('vmess://$uuid@vm.example.com:443'))['security'], 'auto');
      expect(settingsOf(parseShareLink('vmess://$uuid@vm.example.com:443?encryption=chacha20-poly1305'))['security'], 'chacha20-poly1305');
    });
  });

  group('Trojan', () {
    test('TLS включается всегда', () {
      final p = parseShareLink('trojan://p%40ss%3Aword@trojan.example.com:4443?sni=sni.example.com#%D0%A2%D1%80%D0%BE%D1%8F%D0%BD');
      expect(p.name, 'Троян');
      expect(p.protocol, 'trojan');
      expect(p.port, 4443);
      expect(settingsOf(p), {'address': 'trojan.example.com', 'port': 4443, 'password': 'p@ss:word'});
      final s = streamOf(p);
      expect(s['security'], 'tls');
      expect(sub(s, 'tlsSettings')['serverName'], 'sni.example.com');
    });

    test('security=none заменяется на tls, без параметров тоже tls', () {
      expect(streamOf(parseShareLink('trojan://secret@trojan.example.com:443?security=none'))['security'], 'tls');
      final s = streamOf(parseShareLink('trojan://secret@trojan.example.com'));
      expect(s['security'], 'tls');
      expect(s['tlsSettings'], isA<Map>());
    });

    test('Trojan через WebSocket: SNI берётся из заголовка Host', () {
      final s = streamOf(parseShareLink('trojan://secret@198.51.100.7:443?type=ws&host=cdn.example.com&path=%2Ft'));
      expect(s['network'], 'ws');
      expect(sub(s, 'tlsSettings')['serverName'], 'cdn.example.com');
    });

    test('Trojan с Reality', () {
      final s = streamOf(parseShareLink('trojan://secret@trojan.example.com:443?security=reality&pbk=$pbk&sid=01&sni=example.org'));
      expect(s['security'], 'reality');
      expect(sub(s, 'realitySettings')['password'], pbk);
    });

    test('без пароля отклоняется', () {
      expect(() => parseShareLink('trojan://trojan.example.com:443'), throwsShare);
      expect(() => parseShareLink('trojan://secret@trojan.example.com:443?allowInsecure=1'), throwsShare);
    });
  });

  group('Shadowsocks', () {
    test('SIP002: логин в base64', () {
      for (final user in [b64('chacha20-ietf-poly1305:my:pass@word'), b64url('chacha20-ietf-poly1305:my:pass@word'), Uri.encodeComponent(b64('chacha20-ietf-poly1305:my:pass@word'))]) {
        final p = parseShareLink('ss://$user@ss.example.com:8388#%D0%A1%D0%A1');
        expect(p.name, 'СС');
        expect(p.protocol, 'shadowsocks');
        expect(p.outbound['protocol'], 'shadowsocks');
        expect(p.outbound.containsKey('streamSettings'), isFalse);
        expect(settingsOf(p), {'address': 'ss.example.com', 'port': 8388, 'method': 'chacha20-ietf-poly1305', 'password': 'my:pass@word'});
      }
    });

    test('SIP002: логин открытым текстом с процентами', () {
      const password = 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU+/w==';
      final p = parseShareLink('ss://2022-blake3-aes-256-gcm:${Uri.encodeQueryComponent(password)}@192.0.2.10:8888/?#Example');
      expect(settingsOf(p), {'address': '192.0.2.10', 'port': 8888, 'method': '2022-blake3-aes-256-gcm', 'password': password});
      expect(p.name, 'Example');
      final q = parseShareLink('ss://aes-128-gcm:p%40ss%3Aword%2Fwith%2Bsymbols@ss.example.com:8388');
      expect(settingsOf(q)['password'], 'p@ss:word/with+symbols');
    });

    test('совсем старый формат: вся ссылка в base64', () {
      final p = parseShareLink('ss://${b64('aes-256-gcm:pa%41ss@word@ss.example.com:8389')}#old%20one');
      expect(p.name, 'old one');
      // в старом формате пароль записан как есть, проценты в нём — обычные знаки
      expect(settingsOf(p), {'address': 'ss.example.com', 'port': 8389, 'method': 'aes-256-gcm', 'password': 'pa%41ss@word'});
      final v6 = parseShareLink('ss://${b64url('aes-256-gcm:secret@[2001:db8::5]:8389')}');
      expect(v6.address, '2001:db8::5');
      expect(v6.name, '2001:db8::5');
    });

    test('порт по умолчанию 8388', () {
      expect(parseShareLink('ss://${b64('aes-128-gcm:secret')}@ss.example.com').port, 8388);
    });

    test('плагины и повреждённые ссылки отклоняются', () {
      expect(() => parseShareLink('ss://${b64('aes-128-gcm:secret')}@ss.example.com:8388/?plugin=obfs-local%3Bobfs%3Dhttp'), throwsShare);
      expect(() => parseShareLink('ss://'), throwsShare);
      expect(() => parseShareLink('ss://@'), throwsShare);
      expect(() => parseShareLink('ss://@ss.example.com:8388'), throwsShare);
      expect(() => parseShareLink('ss://!!!@ss.example.com:8388'), throwsShare);
      expect(() => parseShareLink('ss://${b64('nocolon')}@ss.example.com:8388'), throwsShare);
      expect(() => parseShareLink('ss://${b64(':nomethod')}@ss.example.com:8388'), throwsShare);
      expect(() => parseShareLink('ss://${b64('aes-128-gcm:secret')}@'), throwsShare);
      expect(() => parseShareLink('ss://${b64('aes-128-gcm:secret')}'), throwsShare);
      expect(() => parseShareLink('ss://#name'), throwsShare);
    });
  });

  group('Hysteria2', () {
    test('пароль, SNI, порт и TLS по умолчанию', () {
      final p = parseShareLink('hysteria2://secret-auth@hy.example.com:8443/?sni=sni.example.com&alpn=h3#%F0%9F%87%B3%F0%9F%87%B1%20Netherlands%20%C2%B7%20Hysteria2');
      expect(p.name, '🇳🇱 Netherlands · Hysteria2');
      expect(p.protocol, 'hysteria2');
      expect(p.address, 'hy.example.com');
      expect(p.port, 8443);
      expect(p.outbound['protocol'], 'hysteria');
      expect(settingsOf(p), {'version': 2, 'address': 'hy.example.com', 'port': 8443});
      final s = streamOf(p);
      expect(s['network'], 'hysteria');
      expect(s['security'], 'tls');
      expect(sub(s, 'hysteriaSettings'), {'version': 2, 'auth': 'secret-auth'});
      expect(sub(s, 'tlsSettings'), {
        'serverName': 'sni.example.com',
        'alpn': ['h3'],
      });
      expect(s.containsKey('finalmask'), isFalse);
      expect(s.containsKey('rawSettings'), isFalse);
      // параметры других транспортов в Hysteria2 не попадают
      final odd = streamOf(parseShareLink('hy2://secret-auth@hy.example.com?headerType=http&host=h.example.com&path=%2Fp&type=ws'));
      expect(odd['network'], 'hysteria');
      expect(odd.keys.toSet(), {'network', 'security', 'tlsSettings', 'hysteriaSettings'});
    });

    test('hy2:// без порта и параметров', () {
      final p = parseShareLink('hy2://password@example.com');
      expect(p.port, 443);
      expect(p.name, 'example.com');
      expect(streamOf(p)['security'], 'tls');
      expect(sub(streamOf(p), 'hysteriaSettings')['auth'], 'password');
    });

    test('пароль в виде логин:пароль с процентами, плюс остаётся плюсом, пустой пароль', () {
      expect(sub(streamOf(parseShareLink('hysteria2://user:p%3Aa%25ss%40word@example.com:8443/')), 'hysteriaSettings')['auth'], 'user:p:a%ss@word');
      expect(sub(streamOf(parseShareLink('hy2://a+b%2Bc%252B@example.com#Test')), 'hysteriaSettings')['auth'], 'a+b+c%2B');
      expect(sub(streamOf(parseShareLink('hysteria2://example.com/')), 'hysteriaSettings')['auth'], '');
    });

    test('IPv6', () {
      final a = parseShareLink('hy2://auth@[2001:db8::1]');
      expect(a.address, '2001:db8::1');
      expect(a.port, 443);
      final b = parseShareLink('hysteria2://auth@[2001:db8::2]:8443?sni=server.example.com');
      expect(b.address, '2001:db8::2');
      expect(b.port, 8443);
      expect(settingsOf(b)['address'], '2001:db8::2');
    });

    test('pinSHA256 с двоеточиями превращается в pinnedPeerCertSha256', () {
      final t = sub(streamOf(parseShareLink('hysteria2://auth@hy.example.com:443?sni=example.com&pinSHA256=${Uri.encodeQueryComponent(pinColons)}')), 'tlsSettings');
      expect(t['pinnedPeerCertSha256'], pinHex);
      expect(t['pinnedPeerCertSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(t['serverName'], 'example.com');
      // без кодирования двоеточий тоже
      final raw = sub(streamOf(parseShareLink('hy2://auth@hy.example.com:443?pinSHA256=$pinColons')), 'tlsSettings');
      expect(raw['pinnedPeerCertSha256'], pinHex);
    });

    test('insecure=1 без закрепления сертификата отклоняется', () {
      expect(() => parseShareLink('hysteria2://auth@hy.example.com:443?insecure=1'), throwsShare);
      expect(() => parseShareLink('hy2://auth@hy.example.com:443?insecure=true&sni=example.com'), throwsShare);
      expect(() => parseShareLink('hy2://auth@hy.example.com:443?allowInsecure=1'), throwsShare);
      expect(() => parseShareLink('hy2://auth@hy.example.com:443?insecure=1&pinSHA256=bad'), throwsShare);
    });

    test('insecure=1 с закреплённым сертификатом принимается, insecure=0 тоже', () {
      final t = sub(streamOf(parseShareLink('hysteria2://auth@hy.example.com:443?insecure=1&pinSHA256=$pinColons')), 'tlsSettings');
      expect(t['pinnedPeerCertSha256'], pinHex);
      expect(t.containsKey('allowInsecure'), isFalse);
      expect(parseShareLink('hy2://auth@hy.example.com?insecure=0').port, 443);
      expect(parseShareLink('hy2://auth@hy.example.com?insecure=false').port, 443);
    });

    test('диапазоны портов дают маску udphop', () {
      final p = parseShareLink('hysteria2://auth@hy.example.com:443,5000-6000?sni=example.com#hop');
      expect(p.address, 'hy.example.com');
      expect(p.port, 443);
      expect(p.name, 'hop');
      expect(settingsOf(p)['port'], 443);
      final mask = sub(streamOf(p), 'finalmask');
      expect(mask['udp'], [
        {
          'type': 'udphop',
          'settings': {'mode': 'intervalLocal,intervalRemote', 'remotePorts': '443,5000-6000', 'interval': 30},
        },
      ]);
      final v6 = parseShareLink('hy2://auth@[2001:db8::1]:5000-5002?hop-interval=10');
      expect(v6.port, 5000);
      final hop = (sub(streamOf(v6), 'finalmask')['udp'] as List).single as Map;
      expect(hop['settings'], {'mode': 'intervalLocal,intervalRemote', 'remotePorts': '5000-5002', 'interval': 10});
    });

    test('старые параметры ports и mport', () {
      for (final key in ['ports', 'mport']) {
        final p = parseShareLink('hy2://auth@hy.example.com:443?$key=5000-5002&up=50%20mbps&down=100%20mbps');
        final mask = sub(streamOf(p), 'finalmask');
        expect((mask['udp'] as List).single['settings']['remotePorts'], '5000-5002', reason: key);
        expect(mask['quicParams'], {'congestion': 'brutal', 'brutalUp': '50 mbps', 'brutalDown': '100 mbps'});
        expect(p.port, 5000);
      }
    });

    test('obfs=salamander', () {
      final p = parseShareLink('hy2://auth@hy.example.com:443,5000-5002/?obfs=salamander&obfs-password=pass%2Bword&sni=example.com');
      final udp = sub(streamOf(p), 'finalmask')['udp'] as List;
      // порядок важен: смена портов должна оборачивать сам сокет
      expect(udp.map((m) => (m as Map)['type']), ['salamander', 'udphop']);
      expect(udp.first['settings'], {'password': 'pass+word'});
      final single = parseShareLink('hy2://auth@hy.example.com?obfs=salamander&obfs-password=secret');
      expect(sub(streamOf(single), 'finalmask')['udp'], [
        {
          'type': 'salamander',
          'settings': {'password': 'secret'},
        },
      ]);
      expect(parseShareLink('hy2://auth@hy.example.com?obfs=none').outbound, isNot(contains('finalmask')));
      expect(() => parseShareLink('hy2://auth@hy.example.com?obfs=gecko&obfs-password=secret'), throwsShare);
      expect(() => parseShareLink('hy2://auth@hy.example.com?obfs=salamander'), throwsShare);
      expect(() => parseShareLink('hy2://auth@hy.example.com?obfs=salamander&obfs-password=abc'), throwsShare);
    });

    test('неверные адреса и порты отклоняются', () {
      for (final suffix in [
        '',
        ':443',
        'example.com:0',
        'example.com:65536',
        'example.com:-1',
        'example.com:5002-5000',
        'example.com:443,',
        'example.com:443,,444',
        'example.com:abc',
        'example.com:1-2-3',
        '2001:db8::1',
        '[2001:db8::1',
        '[2001:db8::1]junk',
        'example.com?security=none',
        'example.com?security=reality',
        'example.com?ports=0',
        'example.com?mport=7-3',
        'example.com?pcs=not-a-pin',
      ]) {
        expect(() => parseShareLink('hy2://secret@$suffix'), throwsShare, reason: suffix);
      }
    });
  });

  group('SOCKS', () {
    test('без логина', () {
      final p = parseShareLink('socks://192.0.2.1:1081#sk');
      expect(p.protocol, 'socks');
      expect(p.name, 'sk');
      expect(p.outbound['protocol'], 'socks');
      expect(settingsOf(p), {'address': '192.0.2.1', 'port': 1081});
      expect(p.outbound.containsKey('streamSettings'), isFalse);
      expect(parseShareLink('socks://example.com').port, 1080);
    });

    test('логин и пароль в base64 и открытым текстом', () {
      final a = parseShareLink('socks://${b64('socksuser:socks:pass')}@192.0.2.1:1081');
      expect(settingsOf(a), {'address': '192.0.2.1', 'port': 1081, 'user': 'socksuser', 'pass': 'socks:pass'});
      final b = parseShareLink('socks://user:p%40ss@example.com:1080');
      expect(settingsOf(b)['user'], 'user');
      expect(settingsOf(b)['pass'], 'p@ss');
    });

    test('повреждённый логин отклоняется', () {
      expect(() => parseShareLink('socks://!!!@example.com:1080'), throwsShare);
      expect(() => parseShareLink('socks://${b64('nocolon')}@example.com:1080'), throwsShare);
    });
  });

  group('мусор на входе', () {
    final garbage = <String>[
      '',
      ' ',
      '\n',
      'vless://',
      'vless://@',
      'vless://@:443',
      'vless://#',
      'vless://?',
      'vless:///',
      'vmess://',
      'vmess://!!!',
      'vmess://@',
      'vmess://====',
      'vmess://e30',
      'vmess://bnVsbA',
      'trojan://',
      'trojan://@',
      'ss://',
      'ss://@',
      'ss://#',
      'ss://?',
      'ss://:@:',
      'hysteria2://',
      'hysteria2://@',
      'hy2://',
      'hy2://@',
      'hy2://[',
      'hy2://]',
      'hy2://[]',
      'hy2://[]:1',
      'hy2://@:',
      'hy2://a@b:c',
      'socks://',
      'socks://@',
      '://',
      'vless',
      'vless:',
      'vless:/',
      'http://example.com',
      'https://example.com/sub/abc',
      'wireguard://example.com',
      'tuic://example.com',
      'просто текст',
      '<html></html>',
      '{"outbounds":[]}',
      'vless://$uuid@example.com:443?a=%ff',
      'vless://$uuid@example.com:443?type=%ff',
      'vless://%ff@example.com:443',
      'vless://$uuid@example.com:443#%ff',
      'trojan://%@%:%',
      'ss://%ff@example.com:1',
      'ss://%@%',
      'hy2://%ff@example.com?obfs-password=%ff',
      'socks://%ff@example.com',
      'vless://\u0000@\u0000',
      'vmess://${b64('{"add":{"x":1},"port":[1],"id":null}')}',
      'vmess://${b64('{"add":"a","port":"1","id":"x","net":7}')}',
      'vless://$uuid@[::1',
      'vless://$uuid@[zz]:1',
      'vless://$uuid@::1',
      'vless://${'a' * 100000}',
      'vless://$uuid@${'a' * 100000}.example.com:443',
      'vless://$uuid@example.com:443?${'x=1&' * 20000}',
      'vless://$uuid@example.com:443#${'я' * 50000}',
      'vmess://${'A' * 100001}',
      'ss://${'A' * 100000}',
      'ss://${'@' * 10000}',
      'hy2://${'[' * 10000}',
      'hy2://a@b:${'1,' * 10000}',
      'socks://${':' * 10000}',
    ];

    test('только ShareLinkException и никаких других исключений', () {
      for (final g in garbage) {
        final shown = g.length > 60 ? '${g.substring(0, 60)}… (${g.length})' : g;
        try {
          final p = parseShareLink(g);
          // если ссылка всё же разобрана, результат должен быть цельным
          expect(p.outbound['tag'], 'proxy', reason: shown);
          expect(p.address, isNotEmpty, reason: shown);
          expect(p.port, inInclusiveRange(1, 65535), reason: shown);
          jsonEncode(p.outbound);
        } on ShareLinkException catch (e) {
          expect(e.message, isNotEmpty, reason: shown);
          expect(e.toString(), e.message);
        } catch (e) {
          fail('«$shown»: ${e.runtimeType}: $e');
        }
      }
    });

    test('очевидный мусор именно отклоняется', () {
      for (final g in ['', 'vless://', 'vless://@', 'ss://', 'vmess://!!!', 'hy2://', 'socks://', 'http://example.com', 'просто текст']) {
        expect(() => parseShareLink(g), throwsShare, reason: g);
      }
    });

    test('случайные строки и испорченные ссылки', () {
      final rnd = Random(20261115);
      const alphabet = 'abcXYZ019%:/?#[]@!\$&\'()*+,;=-._~ \\"{}|^<>`\u0000\u00e9яЖ🇷🇺\n\t';
      final runes = alphabet.runes.toList();
      final bases = [
        'vless://$uuid@example.com:443?security=reality&pbk=$pbk&sid=ab&type=xhttp&extra=%7B%22a%22%3A1%7D#name',
        'vmess://${b64('{"add":"example.com","port":"443","id":"$uuid","net":"ws","tls":"tls"}')}',
        'vmess://$uuid@example.com:443?type=grpc',
        'trojan://secret@example.com:443?type=ws&host=example.org',
        'ss://${b64('aes-128-gcm:secret')}@example.com:8388#n',
        'ss://${b64('aes-128-gcm:secret@example.com:8388')}',
        'hysteria2://secret@example.com:443,5000-6000?obfs=salamander&obfs-password=secret&pinSHA256=$pinColons&insecure=1#n',
        'hy2://secret@[2001:db8::1]:443?sni=example.com',
        'socks://${b64('u:p')}@example.com:1080',
      ];
      for (var i = 0; i < 6000; i++) {
        String input;
        if (i % 3 == 0) {
          final len = rnd.nextInt(40);
          final scheme = shareSchemes[rnd.nextInt(shareSchemes.length)];
          input = scheme + String.fromCharCodes([for (var k = 0; k < len; k++) runes[rnd.nextInt(runes.length)]]);
        } else {
          // портим рабочую ссылку: вставка, удаление, замена, обрезка
          final chars = bases[rnd.nextInt(bases.length)].runes.toList();
          for (var m = 0, n = 1 + rnd.nextInt(4); m < n; m++) {
            final pos = chars.isEmpty ? 0 : rnd.nextInt(chars.length);
            switch (rnd.nextInt(4)) {
              case 0:
                chars.insert(pos, runes[rnd.nextInt(runes.length)]);
              case 1:
                if (chars.isNotEmpty) chars.removeAt(pos);
              case 2:
                if (chars.isNotEmpty) chars[pos] = runes[rnd.nextInt(runes.length)];
              case 3:
                chars.removeRange(pos, chars.length);
            }
          }
          input = String.fromCharCodes(chars);
        }
        try {
          final p = parseShareLink(input);
          expect(p.address, isNotEmpty, reason: input);
          expect(p.port, inInclusiveRange(1, 65535), reason: input);
          jsonEncode(p.outbound);
        } on ShareLinkException {
          // ожидаемо
        } catch (e) {
          fail('«$input»: ${e.runtimeType}: $e');
        }
      }
    });
  });
}
