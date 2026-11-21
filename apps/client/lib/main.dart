import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_state.dart';
import 'core/models.dart';
import 'core/vpn_desktop.dart';
import 'ui/home.dart';
import 'ui/servers.dart';
import 'ui/settings.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // На Windows и macOS туннель поднимает системная служба, на телефонах — VPN-служба самой системы.
  final app = AppState(vpn: Platform.isWindows || Platform.isMacOS ? DesktopVpn() : null);
  app.init();
  runApp(AstatApp(app: app));
}

class AstatApp extends StatelessWidget {
  const AstatApp({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: app,
        builder: (context, _) => MaterialApp(
          title: 'AstatVPN',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: switch (app.settings.theme) {
            ThemeChoice.dark => ThemeMode.dark,
            ThemeChoice.light => ThemeMode.light,
            ThemeChoice.system => ThemeMode.system,
          },
          home: Shell(app: app),
        ),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key, required this.app});
  final AppState app;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // вернулись в приложение: подписка могла измениться (оплата, продление)
    if (state == AppLifecycleState.resumed && widget.app.ready) {
      widget.app.syncAccount();
      if (widget.app.settings.autoUpdate) widget.app.refreshDue();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = widget.app;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: c.bg),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: Row(children: [
                Text('ASTAT', style: mono(c.text, 16, weight: FontWeight.w800, spacing: 2)),
                Text(' VPN', style: mono(c.muted, 16, weight: FontWeight.w500, spacing: 2)),
                const Spacer(),
                if (app.signedIn) Text(app.account?.name ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.muted, 12)),
              ]),
            ),
            Expanded(
              child: !app.ready
                  ? const SizedBox.shrink()
                  : IndexedStack(index: _tab, children: [
                      HomeScreen(app: app),
                      ServersScreen(app: app),
                      SettingsScreen(app: app),
                    ]),
            ),
          ]),
        ),
        bottomNavigationBar: _TabBar(index: _tab, onTap: (i) => setState(() => _tab = i)),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    const labels = ['ГЛАВНАЯ', 'СЕРВЕРЫ', 'НАСТРОЙКИ'];
    return DecoratedBox(
      decoration: BoxDecoration(color: c.bg, border: Border(top: BorderSide(color: c.border))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: Semantics(
                selected: i == index,
                button: true,
                child: InkWell(
                  onTap: () => onTap(i),
                  child: SizedBox(
                    height: 54,
                    // На узком экране или с крупным шрифтом системы «[ НАСТРОЙКИ ]» не помещается во вкладку:
                    // текст уменьшается, а не переносит «]» на вторую строку.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            i == index ? '[ ${labels[i]} ]' : labels[i],
                            maxLines: 1,
                            softWrap: false,
                            style: mono(i == index ? c.text : c.muted, 12, weight: i == index ? FontWeight.w800 : FontWeight.w500, spacing: 0.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
