import 'package:astatvpn/core/app_state.dart';
import 'package:astatvpn/core/routing_profile.dart';
import 'package:astatvpn/core/storage.dart';
import 'package:astatvpn/ui/routing.dart';
import 'package:astatvpn/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage extends Storage {
  @override
  Future<void> save(StoredState state) async {}
}

void main() {
  testWidgets('импорт с предпросмотром и создание профиля вручную', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = AppState(storage: _MemoryStorage());
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: RoutingScreen(app: app),
      ),
    );

    await tester.tap(find.text('Импорт'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      '{"Name":"Из Incy","BlockSites":["example.org"]}',
    );
    await tester.tap(find.text('Предпросмотр'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль маршрутизации'), findsOneWidget);
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first;
    final block = find.byKey(const ValueKey(RouteAction.block));
    await tester.scrollUntilVisible(block, 150, scrollable: list);
    expect(tester.widget<TextFormField>(block).controller!.text, 'example.org');
    expect(app.settings.routingProfiles, isEmpty);
    await tester.tap(find.text('СОХРАНИТЬ'));
    await tester.pumpAndSettle();
    expect(app.settings.routingProfiles.values.single.name, 'Из Incy');
    expect(app.settings.routingProfile, isNull);

    await tester.tap(find.text('Из Incy'));
    await tester.pumpAndSettle();
    expect(app.settings.routingProfile?.name, 'Из Incy');

    await tester.tap(find.text('Создать профиль'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Мой профиль');
    await tester.scrollUntilVisible(block, 150, scrollable: list);
    await tester.enterText(
      block,
      'ads.example.org',
    );
    await tester.tap(find.text('СОХРАНИТЬ'));
    await tester.pumpAndSettle();
    expect(app.settings.routingProfiles.values.map((p) => p.name), [
      'Из Incy',
      'Мой профиль',
    ]);
    expect(
      app
          .settings
          .routingProfiles
          .values
          .last
          .groups[RouteAction.block]
          ?.domains,
      ['domain:ads.example.org'],
    );
    await tester.tap(find.text('Стандартные правила'));
    await tester.pumpAndSettle();
    expect(app.settings.routingProfile, isNull);
  });
}
