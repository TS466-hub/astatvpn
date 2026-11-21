import 'dart:convert';

import 'package:astatvpn/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Как при сохранении на диск: через текст JSON.
Map<String, dynamic> viaJson(Map<String, dynamic> j) => (jsonDecode(jsonEncode(j)) as Map).cast<String, dynamic>();

void main() {
  group('ServerEntry', () {
    test('сервер из ссылки', () {
      final s = ServerEntry(
        id: 'abc',
        name: '🇳🇱 Нидерланды',
        protocol: 'vless',
        address: 'nl.example.com',
        port: 443,
        outbound: {
          'tag': 'proxy',
          'protocol': 'vless',
          'settings': {'address': 'nl.example.com', 'port': 443},
        },
        delayMs: 87,
      );
      final j = viaJson(s.toJson());
      expect(j.containsKey('full'), isFalse);
      expect(j.containsKey('auto'), isFalse);
      final r = ServerEntry.fromJson(j);
      expect(r.id, 'abc');
      expect(r.name, '🇳🇱 Нидерланды');
      expect(r.protocol, 'vless');
      expect(r.address, 'nl.example.com');
      expect(r.port, 443);
      expect(r.outbound, s.outbound);
      expect(r.full, isNull);
      expect(r.delayMs, 87);
      expect(r.auto, isFalse);
      expect(viaJson(r.toJson()), j);
    });

    test('готовая конфигурация с балансировщиком', () {
      final s = ServerEntry(
        id: 'auto-1',
        name: '🇪🇺 Авто',
        protocol: 'auto',
        address: '',
        port: 0,
        full: {
          'outbounds': [
            {'tag': 'proxy-1', 'protocol': 'vless'},
          ],
          'routing': {
            'balancers': [
              {'tag': 'auto'},
            ],
          },
        },
        auto: true,
      );
      final j = viaJson(s.toJson());
      expect(j.containsKey('outbound'), isFalse);
      expect(j.containsKey('delayMs'), isFalse);
      final r = ServerEntry.fromJson(j);
      expect(r.auto, isTrue);
      expect(r.full, s.full);
      expect(r.outbound, isNull);
      expect(r.delayMs, isNull);
      expect(r.port, 0);
      expect(viaJson(r.toJson()), j);
    });

    test('недоступный сервер: задержка -1 сохраняется', () {
      final s = ServerEntry(id: 'x', name: 'x', protocol: 'trojan', address: 'a.example.com', port: 1, outbound: {'tag': 'proxy'}, delayMs: -1);
      expect(ServerEntry.fromJson(viaJson(s.toJson())).delayMs, -1);
    });
  });

  group('Profile', () {
    test('все поля', () {
      final p = Profile(
        id: 'p1',
        name: 'AstatVPN',
        kind: ProfileKind.astat,
        url: 'https://sub.example.com/abc?x=1%202',
        servers: [
          ServerEntry(id: 'a', name: 'A', protocol: 'vless', address: 'a.example.com', port: 443, outbound: {'tag': 'proxy'}),
          ServerEntry(id: 'b', name: 'B', protocol: 'auto', address: '', port: 0, full: {'outbounds': []}, auto: true),
        ],
        updatedAt: DateTime(2026, 11, 15, 12, 30, 45, 123),
        usedBytes: 123456789012,
        totalBytes: 0,
        expireAt: DateTime.fromMillisecondsSinceEpoch(1767225600 * 1000),
        updateHours: 1,
        supportUrl: 'https://t.me/example_bot',
        announce: 'Работы до 12:00',
        lastError: 'Нет связи',
      );
      final j = viaJson(p.toJson());
      final r = Profile.fromJson(j);
      expect(r.id, 'p1');
      expect(r.name, 'AstatVPN');
      expect(r.kind, ProfileKind.astat);
      expect(r.url, p.url);
      expect(r.servers.map((s) => s.id), ['a', 'b']);
      expect(r.servers[1].auto, isTrue);
      expect(r.servers[0].outbound, {'tag': 'proxy'});
      expect(r.updatedAt, p.updatedAt);
      expect(r.updatedAt!.isAtSameMomentAs(p.updatedAt!), isTrue);
      expect(r.usedBytes, 123456789012);
      expect(r.totalBytes, 0);
      expect(r.expireAt!.isAtSameMomentAs(p.expireAt!), isTrue);
      expect(r.expireAt!.toUtc(), DateTime.utc(2026, 1, 1));
      expect(r.updateHours, 1);
      expect(r.supportUrl, 'https://t.me/example_bot');
      expect(r.announce, 'Работы до 12:00');
      expect(r.lastError, 'Нет связи');
      expect(viaJson(r.toJson()), j);
    });

    test('время хранится в UTC и не зависит от часового пояса устройства', () {
      final at = DateTime.utc(2026, 6, 1, 10);
      final p = Profile(id: 'p', name: 'n', kind: ProfileKind.url, url: 'https://sub.example.com/x', updatedAt: at.toLocal(), expireAt: at.toLocal());
      final j = viaJson(p.toJson());
      expect(j['updatedAt'], '2026-06-01T10:00:00.000Z');
      expect(j['expireAt'], '2026-06-01T10:00:00.000Z');
      final r = Profile.fromJson(j);
      expect(r.updatedAt!.isUtc, isFalse);
      expect(r.updatedAt!.isAtSameMomentAs(at), isTrue);
      expect(r.expireAt!.isAtSameMomentAs(at), isTrue);
      // прежний вид без пояса читается как местное время
      final old = Profile.fromJson({...j, 'updatedAt': '2026-06-01T10:00:00.000'});
      expect(old.updatedAt, DateTime(2026, 6, 1, 10));
    });

    test('только обязательные поля и значения по умолчанию', () {
      final p = Profile(id: 'p2', name: 'Локальный', kind: ProfileKind.local);
      final j = viaJson(p.toJson());
      expect(j.keys.toSet(), {'id', 'name', 'kind', 'servers', 'updateHours'});
      final r = Profile.fromJson(j);
      expect(r.kind, ProfileKind.local);
      expect(r.url, isNull);
      expect(r.servers, isEmpty);
      expect(r.updatedAt, isNull);
      expect(r.usedBytes, isNull);
      expect(r.totalBytes, isNull);
      expect(r.expireAt, isNull);
      expect(r.updateHours, 12);
      expect(r.supportUrl, isNull);
      expect(r.announce, isNull);
      expect(r.lastError, isNull);
      expect(r.needsUpdate, isFalse);
      r.servers.add(ServerEntry(id: 'a', name: 'A', protocol: 'vless', address: 'a', port: 1));
      expect(r.servers.length, 1);
    });

    test('неизвестный вид, повреждённые даты и отсутствие списка', () {
      final r = Profile.fromJson({'id': 'p', 'name': 'n', 'kind': 'new-kind', 'updatedAt': 'вчера', 'expireAt': ''});
      expect(r.kind, ProfileKind.url);
      expect(r.updatedAt, isNull);
      expect(r.expireAt, isNull);
      expect(r.servers, isEmpty);
      expect(r.updateHours, 12);
    });

    test('все виды профиля проходят туда и обратно', () {
      for (final kind in ProfileKind.values) {
        expect(Profile.fromJson(viaJson(Profile(id: 'p', name: 'n', kind: kind).toJson())).kind, kind);
      }
    });

    test('needsUpdate', () {
      final p = Profile(id: 'p', name: 'n', kind: ProfileKind.url, url: 'https://sub.example.com/x', updateHours: 2);
      expect(p.needsUpdate, isTrue);
      p.updatedAt = DateTime.now().subtract(const Duration(minutes: 119));
      expect(p.needsUpdate, isFalse);
      p.updatedAt = DateTime.now().subtract(const Duration(minutes: 121));
      expect(p.needsUpdate, isTrue);
      // после сохранения и чтения ответ тот же
      expect(Profile.fromJson(viaJson(p.toJson())).needsUpdate, isTrue);
      p.updatedAt = DateTime.now().subtract(const Duration(minutes: 5));
      expect(Profile.fromJson(viaJson(p.toJson())).needsUpdate, isFalse);
    });
  });

  group('AppSettings', () {
    test('значения по умолчанию', () {
      final s = AppSettings();
      expect(s.ruDirect, isTrue);
      expect(s.appFilter, AppFilterMode.off);
      expect(s.apps, isEmpty);
      expect(s.autoConnect, isFalse);
      expect(s.theme, ThemeChoice.dark);
      expect(s.autoUpdate, isTrue);
      final r = AppSettings.fromJson(<String, dynamic>{});
      expect(viaJson(r.toJson()), viaJson(s.toJson()));
      r.apps.add('com.example.app');
      expect(r.apps, ['com.example.app']);
    });

    test('все поля', () {
      final s = AppSettings(ruDirect: false, appFilter: AppFilterMode.include, apps: ['com.example.one', 'com.example.two'], autoConnect: true, theme: ThemeChoice.light, autoUpdate: false);
      final j = viaJson(s.toJson());
      final r = AppSettings.fromJson(j);
      expect(r.ruDirect, isFalse);
      expect(r.appFilter, AppFilterMode.include);
      expect(r.apps, ['com.example.one', 'com.example.two']);
      expect(r.autoConnect, isTrue);
      expect(r.theme, ThemeChoice.light);
      expect(r.autoUpdate, isFalse);
      expect(viaJson(r.toJson()), j);
    });

    test('все значения перечислений', () {
      for (final mode in AppFilterMode.values) {
        for (final theme in ThemeChoice.values) {
          final r = AppSettings.fromJson(viaJson(AppSettings(appFilter: mode, theme: theme).toJson()));
          expect(r.appFilter, mode);
          expect(r.theme, theme);
        }
      }
    });

    test('неизвестные значения заменяются значениями по умолчанию', () {
      final r = AppSettings.fromJson({'appFilter': 'nope', 'theme': 'pink', 'apps': null, 'ruDirect': null, 'autoConnect': 'yes', 'autoUpdate': 1});
      expect(r.appFilter, AppFilterMode.off);
      expect(r.theme, ThemeChoice.dark);
      expect(r.apps, isEmpty);
      expect(r.ruDirect, isTrue);
      expect(r.autoConnect, isFalse);
      expect(r.autoUpdate, isTrue);
    });
  });

  group('stableId', () {
    test('одинаковый текст — одинаковый идентификатор', () {
      for (final text in ['', 'a', 'vless|nl.example.com|443|🇳🇱 Нидерланды', 'full|auto|🇪🇺 Авто', 'x' * 10000]) {
        expect(stableId(text), stableId(text), reason: text);
        expect(stableId(text), stableId(String.fromCharCodes(text.codeUnits)));
      }
    });

    test('короткая строка из строчных букв и цифр', () {
      for (final text in ['', 'a', 'привет', '🇳🇱', 'x' * 10000]) {
        final id = stableId(text);
        expect(id, matches(RegExp(r'^[0-9a-z]{1,13}$')), reason: text);
      }
    });

    test('разный текст — разные идентификаторы', () {
      final ids = <String>{};
      for (var i = 0; i < 20000; i++) {
        ids.add(stableId('vless|server$i.example.com|443|Server $i'));
      }
      expect(ids.length, 20000);
      expect(stableId('a|b'), isNot(stableId('b|a')));
      expect(stableId('vless|a.example.com|443|x'), isNot(stableId('vless|a.example.com|444|x')));
      expect(stableId('Москва'), isNot(stableId('москва')));
    });

    test('значения не меняются между версиями приложения', () {
      // FNV-1a, 64 бита, без старшего бита, в 36-ричной записи: от этого зависят сохранённые выбор сервера и замеры
      expect(stableId(''), (0xcbf29ce484222325 & 0x7fffffffffffffff).toRadixString(36));
      expect(stableId('a'), (0xaf63dc4c8601ec8c & 0x7fffffffffffffff).toRadixString(36));
      expect(stableId('foobar'), (0x85944171f73967e8 & 0x7fffffffffffffff).toRadixString(36));
    });
  });
}
