import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/astat_api.dart';
import '../core/models.dart';
import '../core/vpn.dart';
import 'login.dart';
import 'routing.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> openUrl(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
  if (!ok && context.mounted) toast(context, 'Не удалось открыть ссылку');
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final s = app.settings;
    final account = app.account;
    return PageBody(children: [
      const SectionTitle('Аккаунт ASTAT'),
      RowsPanel(children: [
        if (!app.signedIn)
          SettingRow(title: 'Войти', subtitle: 'Подписка появится в приложении сама', trailing: const _Arrow(), onTap: () => openLogin(context, app))
        else ...[
          SettingRow(title: account?.name ?? 'Аккаунт', subtitle: account == null ? 'загрузка…' : _accountLine(account)),
          SettingRow(title: 'Личный кабинет', subtitle: 'Тарифы, оплата, устройства', trailing: const _Arrow(), onTap: () => openUrl(context, astatSite)),
          SettingRow(
            title: 'Выйти',
            onTap: () async {
              await app.signOut();
              if (context.mounted) toast(context, 'Вы вышли из аккаунта');
            },
          ),
        ],
      ]),
      const SectionTitle('Подключение'),
      RowsPanel(children: [
        SettingRow(
          title: 'Маршрутизация',
          subtitle: s.routingProfile?.name ?? 'Импорт Happ и Incy, свои правила',
          trailing: const _Arrow(),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RoutingScreen(app: app))),
        ),
        if (s.routingProfile == null)
          SettingRow(
            title: 'Российские сайты напрямую',
            subtitle: 'Сайты и адреса из России открываются без VPN. Для подписки ASTAT правила приходят с сервера.',
            trailing: Check(s.ruDirect),
            onTap: () => app.updateSettings((x) => x.ruDirect = !x.ruDirect),
          ),
        if (Platform.isAndroid)
          SettingRow(
            title: 'Приложения',
            subtitle: switch (s.appFilter) {
              AppFilterMode.off => 'VPN работает для всех приложений',
              AppFilterMode.exclude => 'Мимо VPN: ${plural(s.apps.length, 'приложение', 'приложения', 'приложений')}',
              AppFilterMode.include => 'Через VPN только: ${plural(s.apps.length, 'приложение', 'приложения', 'приложений')}',
            },
            trailing: const _Arrow(),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AppsScreen(app: app))),
          ),
        if (Platform.isAndroid)
          SettingRow(
            title: 'Защита от утечек',
            subtitle: 'В настройках Android включите для AstatVPN «Постоянная VPN» и «Блокировать соединения без VPN»: при обрыве интернет не пойдёт в обход.',
            trailing: const _Arrow(),
            onTap: () async {
              if (!await app.vpn.openVpnSettings() && context.mounted) toast(context, 'Откройте настройки Android → Сеть → VPN');
            },
          ),
        SettingRow(
          title: 'Подключаться при запуске',
          trailing: Check(s.autoConnect),
          onTap: () => app.updateSettings((x) => x.autoConnect = !x.autoConnect),
        ),
        SettingRow(
          title: 'Обновлять подписки самостоятельно',
          trailing: Check(s.autoUpdate),
          onTap: () => app.updateSettings((x) => x.autoUpdate = !x.autoUpdate),
        ),
      ]),
      const SectionTitle('Оформление'),
      RowsPanel(children: [
        for (final (choice, label) in [(ThemeChoice.dark, 'Тёмная'), (ThemeChoice.light, 'Светлая'), (ThemeChoice.system, 'Как в системе')])
          SettingRow(title: label, trailing: Check(s.theme == choice), onTap: () => app.updateSettings((x) => x.theme = choice)),
      ]),
      const SectionTitle('О приложении'),
      RowsPanel(children: [
        SettingRow(title: 'Журнал', subtitle: 'Сообщения ядра, помогает разобраться со сбоем', trailing: const _Arrow(), onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LogsScreen(app: app)))),
        SettingRow(title: 'Поддержка', trailing: const _Arrow(), onTap: () => openUrl(context, app.profile?.supportUrl ?? 'https://t.me/astat_robot')),
        _VersionRow(vpn: app.vpn),
      ]),
    ]);
  }

  String _accountLine(AstatAccount a) {
    if (a.subUrl == null) return 'подписки нет';
    final plan = a.planName ?? 'подписка';
    if (a.state != 'active' && a.daysLeft <= 0) return '$plan · срок истёк';
    return '$plan · осталось ${plural(a.daysLeft, 'день', 'дня', 'дней')}';
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow();
  @override
  Widget build(BuildContext context) => Text('>', style: mono(context.c.muted, 15, weight: FontWeight.w700));
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({required this.vpn});
  final Vpn vpn;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: vpn.coreVersion(),
        builder: (context, snap) => SettingRow(
          title: 'AstatVPN $appVersion',
          subtitle: (snap.data ?? '').isEmpty ? null : 'ядро Xray ${snap.data}',
        ),
      );
}

/// Выбор приложений, которые идут мимо VPN или только через него.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key, required this.app});
  final AppState app;

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  List<InstalledApp>? _apps;
  String _query = '';
  bool _system = false;

  @override
  void initState() {
    super.initState();
    widget.app.vpn.apps().then((list) {
      list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
      if (mounted) setState(() => _apps = list);
    }).catchError((_) {
      if (mounted) setState(() => _apps = []);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final app = widget.app;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.settings;
        final selected = s.apps.toSet();
        final list = (_apps ?? [])
            .where((a) => (_system || !a.system || selected.contains(a.package)) && (_query.isEmpty || a.label.toLowerCase().contains(_query) || a.package.contains(_query)))
            .toList();
        return Scaffold(
          appBar: AppBar(title: const Text('ПРИЛОЖЕНИЯ')),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: RowsPanel(children: [
                    for (final (mode, label) in [
                      (AppFilterMode.off, 'VPN для всех приложений'),
                      (AppFilterMode.exclude, 'Выбранные идут мимо VPN'),
                      (AppFilterMode.include, 'Через VPN только выбранные'),
                    ])
                      SettingRow(title: label, trailing: Check(s.appFilter == mode), onTap: () => app.updateSettings((x) => x.appFilter = mode)),
                  ]),
                ),
                if (s.appFilter != AppFilterMode.off) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: TextField(
                      style: mono(c.text, 14),
                      decoration: const InputDecoration(hintText: 'Поиск'),
                      onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: SettingRow(title: 'Показывать системные', trailing: Check(_system), onTap: () => setState(() => _system = !_system)),
                  ),
                  Expanded(
                    child: _apps == null
                        ? Center(child: Text('загрузка…', style: mono(c.muted, 13)))
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: list.length,
                            itemBuilder: (context, i) {
                              final a = list[i];
                              final on = selected.contains(a.package);
                              return SettingRow(
                                title: a.label,
                                subtitle: a.package,
                                trailing: Check(on),
                                onTap: () => app.updateSettings((x) => on ? x.apps.remove(a.package) : x.apps.add(a.package)),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text('Изменения применяются при следующем подключении.', style: mono(c.muted, 11)),
                  ),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }
}

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.app});
  final AppState app;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  String _text = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await widget.app.vpn.logs();
    if (mounted) setState(() => _text = t);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      appBar: AppBar(title: const Text('ЖУРНАЛ')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: Row(children: [
            Expanded(child: AstatButton('ОБНОВИТЬ', ghost: true, small: true, onTap: _load)),
            const SizedBox(width: 10),
            Expanded(
              child: AstatButton(
                'СКОПИРОВАТЬ',
                small: true,
                onTap: _text.isEmpty
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: _text));
                        if (context.mounted) toast(context, 'Журнал скопирован');
                      },
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: RowsPanel(children: [
            SettingRow(
              title: 'Подробный журнал',
              subtitle: 'Ход каждого соединения с адресами сайтов. Включайте для разбора сбоя, затем подключитесь заново',
              trailing: Check(widget.app.settings.verboseLog),
              onTap: () => setState(() => widget.app.updateSettings((x) => x.verboseLog = !x.verboseLog)),
            ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SizedBox(
              width: double.infinity,
              child: SelectableText(_text.isEmpty ? 'Журнал пуст. Он заполняется во время подключения.' : _text, style: mono(_text.isEmpty ? c.muted : c.text, 11, height: 1.5)),
            ),
          ),
        ),
      ]),
    );
  }
}
