import 'package:astatvpn/core/app_state.dart';
import 'package:astatvpn/core/models.dart';
import 'package:astatvpn/core/subscription.dart';
import 'package:astatvpn/core/storage.dart';
import 'package:astatvpn/core/vpn.dart';
import 'package:astatvpn/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage extends Storage {
  @override
  Future<void> save(StoredState state) async {}
}

class _FakeVpn extends Vpn {
  late AppState app;
  final calls = <String>[];

  @override
  Future<bool> prepare() async => true;

  @override
  Future<void> start({required String config, required String name, required AppFilterMode filter, required List<String> apps}) async {
    calls.add('start:$name');
    app.status = VpnStatus(state: VpnState.connected, serverName: name);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    app.status = const VpnStatus();
  }
}

ServerEntry _server(String name) =>
    parseSubscription('vless://123e4567-e89b-12d3-a456-426614174000@$name.example.com:443#$name').servers.single;

void main() {
  test('выбор на главной сохраняет туннель до явного переподключения', () async {
    final vpn = _FakeVpn();
    final app = AppState(storage: _MemoryStorage(), vpn: vpn);
    addTearDown(app.dispose);
    vpn.app = app;

    final a = _server('alpha');
    final b = _server('beta');
    final c = _server('gamma');
    final first = Profile(id: 'first', name: 'First', kind: ProfileKind.url, servers: [a, b]);
    final second = Profile(id: 'second', name: 'Second', kind: ProfileKind.url, servers: [c]);
    app.profiles.addAll([first, second]);
    await app.connect();

    await app.selectServer(first, b, reconnectImmediately: false);
    expect(app.needsReconnect, isTrue);
    expect(vpn.calls, ['start:alpha']);

    app.selectProfile(second);
    expect(app.server?.id, c.id);
    app.selectProfile(first);
    expect(app.server?.id, b.id);
    expect(Profile.fromJson(first.toJson()).lastServerId, b.id);

    await app.reconnect();
    expect(vpn.calls, ['start:alpha', 'stop', 'start:beta']);
    expect(app.needsReconnect, isFalse);
  });

  testWidgets('меню на главной переключают подписку и её серверы', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 890);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.runAsync(() async {
      final font = FontLoader('JetBrainsMono');
      for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
        font.addFont(rootBundle.load('assets/fonts/JetBrainsMono-$weight.ttf'));
      }
      await font.load();
    });

    final vpn = _FakeVpn();
    final app = AppState(storage: _MemoryStorage(), vpn: vpn)..ready = true;
    addTearDown(app.dispose);
    vpn.app = app;
    app.settings.theme = ThemeChoice.dark;
    final finland = _server('Finland')..delayMs = 104;
    final netherlands = _server('Netherlands')..delayMs = 87;
    final germany = _server('Germany')..delayMs = 96;
    final sweden = _server('Sweden')..delayMs = 115;
    final first = Profile(id: 'astat', name: 'AstatVPN', kind: ProfileKind.astat, servers: [finland, netherlands, germany]);
    final second = Profile(id: 'backup', name: 'Резервная подписка', kind: ProfileKind.url, servers: [sweden]);
    app.profiles.addAll([first, second]);
    await app.connect();
    await tester.pumpWidget(AstatApp(app: app));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Finland'));
    await tester.pump();
    expect(find.text('Netherlands'), findsOneWidget);
    expect(find.text('Germany'), findsOneWidget);
    expect(find.text('Sweden'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Netherlands'));
    await tester.pump();
    expect(vpn.calls, ['start:Finland']);
    expect(find.text('ПЕРЕПОДКЛЮЧИТЬ'), findsOneWidget);
    expect(find.text('Сейчас: Finland'), findsOneWidget);
    await tester.ensureVisible(find.text('ПЕРЕПОДКЛЮЧИТЬ'));
    await tester.pump();
    await tester.tap(find.text('ПЕРЕПОДКЛЮЧИТЬ'));
    await tester.pump();
    expect(vpn.calls, ['start:Finland', 'stop', 'start:Netherlands']);

    await tester.ensureVisible(find.text('AstatVPN'));
    await tester.tap(find.text('AstatVPN'));
    await tester.pump();
    expect(find.text('Резервная подписка'), findsOneWidget);
    expect(find.text('Germany'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('Резервная подписка'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(app.profile, second);
    expect(find.text('Sweden'), findsNWidgets(2));
    expect(find.text('Netherlands'), findsNothing);
    expect(vpn.calls, ['start:Finland', 'stop', 'start:Netherlands']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
