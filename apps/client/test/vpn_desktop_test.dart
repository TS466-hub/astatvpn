import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/vpn.dart';
import 'package:astatvpn/core/vpn_desktop.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeTransport implements HelperTransport {
  final controller = StreamController<TransportEvent>.broadcast();
  final sent = <Map<String, dynamic>>[];
  var started = false;
  void Function(Map<String, dynamic> req)? onRequest;

  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  void start() => started = true;
  @override
  void send(String line) {
    expect(line.endsWith('\n'), true);
    final req = (jsonDecode(line) as Map).cast<String, dynamic>();
    sent.add(req);
    onRequest?.call(req);
  }

  @override
  void dispose() => controller.close();

  void up() => controller.add(TransportUp());
  void down([int code = 2]) => controller.add(TransportDown(code));
  void line(Object o) => controller.add(TransportLine(jsonEncode(o)));
  void reply(Map<String, dynamic> req, Object result) => line({'id': req['id'], 'ok': true, 'result': result});
  void fail(Map<String, dynamic> req, String error) => line({'id': req['id'], 'ok': false, 'error': error});
}

void main() {
  late FakeTransport t;
  late DesktopVpn vpn;
  setUp(() {
    t = FakeTransport();
    vpn = DesktopVpn(transport: t);
  });
  tearDown(() => vpn.dispose());

  test('status events are delivered in the Vpn shape', () async {
    final got = <VpnStatus>[];
    vpn.statusStream.listen(got.add);
    expect(t.started, true);
    t.up();
    t.line({'event': 'status', 'data': {'state': 'connected', 'since': 1700000000000, 'error': null, 'rx': 10, 'tx': 20, 'name': 'NL'}});
    t.controller.add(TransportLine('garbage'));
    t.controller.add(TransportLine('[1,2]'));
    await pumpEventQueue();
    expect(got.length, 1);
    expect(got[0].state, VpnState.connected);
    expect(got[0].rx, 10);
    expect(got[0].tx, 20);
    expect(got[0].serverName, 'NL');
    expect(got[0].since, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(got[0].error, null);
  });

  test('requests and responses', () async {
    t.onRequest = (req) {
      switch (req['method']) {
        case 'status':
          t.reply(req, {'state': 'disconnected', 'since': 0, 'error': null, 'rx': 0, 'tx': 0, 'name': null});
        case 'version':
          t.reply(req, {'core': '26.11.9', 'helper': '0.1.0'});
        case 'logs':
          t.reply(req, {'text': 'log'});
        case 'ping':
          t.reply(req, {'delays': [for (final _ in req['params']['configs'] as List) 42]});
        case 'start':
          expect(req['params'], {'config': '{}', 'name': 'NL'});
          t.reply(req, {'state': 'connected'});
        case 'stop':
          t.fail(req, 'Ошибка остановки');
      }
    };
    scheduleMicrotask(t.up);
    expect(await vpn.prepare(), true);
    expect((await vpn.status()).state, VpnState.disconnected);
    expect(await vpn.coreVersion(), '26.11.9');
    expect(await vpn.logs(), 'log');
    expect(await vpn.ping(['a', 'b', 'c']), [42, 42, 42]);
    expect(await vpn.ping(List.filled(150, 'x')), List.filled(150, 42));
    expect(t.sent.where((r) => r['method'] == 'ping').length, 1 + 3); // 150 -> 64+64+22
    expect(await vpn.ping([]), <int>[]);
    await vpn.start(config: '{}', name: 'NL', filter: AppFilterMode.off, apps: const []);
    await expectLater(vpn.stop(), throwsA(isA<VpnException>().having((e) => e.message, 'message', 'Ошибка остановки')));
    expect(await vpn.apps(), isEmpty);
    expect(await vpn.openVpnSettings(), false);
    final ids = t.sent.map((r) => r['id']).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('service down: clear errors, pending requests fail, status resets', () async {
    final got = <VpnStatus>[];
    vpn.statusStream.listen(got.add);
    t.down(2);
    await pumpEventQueue();
    expect((await vpn.status()).state, VpnState.disconnected);
    expect(await vpn.coreVersion(), '');
    expect(got, isEmpty);

    t.up();
    t.line({'event': 'status', 'data': {'state': 'connected', 'since': 5, 'error': null, 'rx': 0, 'tx': 0, 'name': 'NL'}});
    await pumpEventQueue();
    final pending = vpn.ping(['a']);
    await pumpEventQueue();
    t.down(2);
    await expectLater(pending, throwsA(isA<VpnException>()));
    await pumpEventQueue();
    expect(got.last.state, VpnState.disconnected);
    expect(got.last.error, isNotNull);

    // служба вернулась
    t.up();
    await pumpEventQueue();
    t.onRequest = (req) => t.reply(req, {'core': 'x'});
    expect(await vpn.coreVersion(), 'x');
  });

  test('oversized request is refused locally', () async {
    t.up();
    await pumpEventQueue();
    final big = 'a' * (DesktopVpn.maxRequestBytes + 1);
    await expectLater(vpn.start(config: big, name: 'x', filter: AppFilterMode.off, apps: const []), throwsA(isA<VpnException>()));
    expect(t.sent, isEmpty);
  });

  test('untrusted pipe message', () async {
    vpn.statusStream.listen((_) {});
    t.down(TransportDown.untrusted);
    await pumpEventQueue();
    // на этой машине не Windows, но транспорт подставной, поэтому сообщения как на Windows
    await expectLater(
        vpn.ping(['a']), throwsA(isA<VpnException>().having((e) => e.message, 'message', contains('посторонней программой'))));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('without a service platform and without transport nothing hangs', () async {
    final plain = DesktopVpn();
    final sw = Stopwatch()..start();
    expect((await plain.status()).state, VpnState.disconnected);
    await expectLater(plain.prepare(), throwsA(isA<VpnException>()));
    expect(await plain.coreVersion(), '');
    expect(await plain.logs(), '');
    expect((await plain.deviceInfo()).keys, containsAll(['model', 'osVersion']));
    await expectLater(plain.installService(), throwsA(isA<VpnException>()));
    expect(sw.elapsedMilliseconds < 1000, true);
    plain.dispose();
    // на Windows и macOS служба есть, и приложение её ждёт: там это поведение проверяют тесты ниже
  }, skip: Platform.isWindows || Platform.isMacOS ? 'на этой системе служба поддерживается' : null);

  group('macOS', () {
    test('команда установки экранирует путь для оболочки и для AppleScript', () {
      expect(DesktopVpn.macInstallScript('/Applications/AstatVPN.app/Contents/Resources/astat-helper'),
          startsWith('do shell script "\'/Applications/AstatVPN.app/Contents/Resources/astat-helper\' install" with prompt'));
      final tricky = DesktopVpn.macInstallScript('/Users/o\'neil/My "Apps"/a\\b/astat-helper');
      // кавычка оболочки закрывается, экранируется и открывается снова; обратная косая и двойная кавычка — для AppleScript
      expect(tricky, contains('\'/Users/o\'\\\\\'\'neil/My \\"Apps\\"/a\\\\b/astat-helper\' install'));
      expect(tricky, endsWith('with administrator privileges'));
    });

    test('версия службы не та: приложение предлагает поставить её заново', () async {
      final t = FakeTransport();
      final vpn = DesktopVpn(transport: t, mac: true);
      addTearDown(vpn.dispose);
      var version = DesktopVpn.helperVersion;
      t.onRequest = (req) => t.reply(req, {'core': '26.11.9', 'helper': version});
      final first = vpn.serviceAvailable();
      t.up();
      expect(await first, true);
      version = '0.0.9';
      expect(await vpn.serviceAvailable(), false);
    });

    test('службы нет: сообщение ведёт к кнопке установки', () async {
      final t = FakeTransport();
      final vpn = DesktopVpn(transport: t, mac: true);
      addTearDown(vpn.dispose);
      final prepared = vpn.prepare();
      t.down(TransportDown.notFound);
      await expectLater(prepared, throwsA(isA<VpnException>().having((e) => e.message, 'message', contains('Установить службу'))));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('сокет службы', () {
    late Directory dir;
    late String path;
    setUp(() {
      // путь к сокету ограничен примерно сотней байт: системный временный каталог подходит не всегда
      dir = Directory('/tmp').createTempSync('astat');
      path = '${dir.path}/s';
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('подключается, передаёт строки в обе стороны и подключается заново', () async {
      final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
      final received = <String>[];
      final clients = <Socket>[];
      server.listen((client) {
        clients.add(client);
        utf8.decoder.bind(client).transform(const LineSplitter()).listen((line) {
          received.add(line);
          client.write('${jsonEncode({'echo': line})}\n');
        }, onError: (_) {});
      });
      final transport = SocketTransport(path);
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      transport.start();
      await _until(() => events.whereType<TransportUp>().isNotEmpty);
      transport.send('привет\n');
      await _until(() => events.whereType<TransportLine>().isNotEmpty);
      expect(received, ['привет']);
      expect(jsonDecode(events.whereType<TransportLine>().single.line), {'echo': 'привет'});

      // служба перезапустилась
      for (final c in clients) {
        c.destroy();
      }
      await _until(() => events.whereType<TransportDown>().isNotEmpty);
      await _until(() => events.whereType<TransportUp>().length == 2);

      await sub.cancel();
      transport.dispose();
      await server.close();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('службы нет: сообщает, что сокет не найден', () async {
      final transport = SocketTransport(path);
      final first = transport.events.first;
      transport.start();
      final event = await first;
      expect(event, isA<TransportDown>().having((e) => e.code, 'code', TransportDown.notFound));
      transport.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('служба сразу закрыла подключение: это отказ в доступе', () async {
      final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
      server.listen((client) => client.destroy());
      final transport = SocketTransport(path);
      final events = <TransportEvent>[];
      final sub = transport.events.listen(events.add);
      transport.start();
      await _until(() => events.whereType<TransportDown>().isNotEmpty);
      expect(events.whereType<TransportDown>().first.code, TransportDown.accessDenied);
      await sub.cancel();
      transport.dispose();
      await server.close();
    }, timeout: const Timeout(Duration(seconds: 20)));
  }, skip: Platform.isWindows ? 'сокеты Unix проверяются на macOS и Linux' : null);
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('условие не выполнилось за 10 секунд');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
