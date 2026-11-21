import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/subscription.dart';
import '../core/vpn.dart';
import 'ascii.dart';
import 'login.dart';
import 'theme.dart';
import 'widgets.dart';

enum _HomeMenu { servers, subscriptions }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.app});
  final AppState app;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _serverMenuKey = GlobalKey();
  final _subscriptionMenuKey = GlobalKey();
  _HomeMenu? _menu;

  AppState get app => widget.app;

  void _toggleMenu(_HomeMenu menu) {
    setState(() => _menu = _menu == menu ? null : menu);
    if (_menu != null) _revealMenu(menu);
  }

  void _revealMenu(_HomeMenu menu, {bool fromSubscription = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _menu != menu) return;
      final key = menu == _HomeMenu.servers ? _serverMenuKey : _subscriptionMenuKey;
      final menuContext = key.currentContext;
      if (menuContext == null) return;
      Scrollable.ensureVisible(
        menuContext,
        alignmentPolicy: fromSubscription ? ScrollPositionAlignmentPolicy.explicit : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  void _chooseProfile(Profile profile) {
    final openServers = app.rememberedServer(profile) == null && profile.servers.isNotEmpty;
    app.selectProfile(profile);
    setState(() => _menu = openServers ? _HomeMenu.servers : null);
    if (openServers) _revealMenu(_HomeMenu.servers, fromSubscription: true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final state = app.status.state;
    final server = app.server;
    final profile = app.profile;
    final mode = switch (state) {
      VpnState.connected => GlobeMode.active,
      VpnState.connecting || VpnState.stopping => GlobeMode.working,
      VpnState.disconnected => app.busy ? GlobeMode.working : GlobeMode.idle,
    };
    final title = switch (state) {
      VpnState.connected => 'ПОДКЛЮЧЕНО',
      VpnState.connecting => 'ПОДКЛЮЧЕНИЕ',
      VpnState.stopping => 'ОТКЛЮЧЕНИЕ',
      VpnState.disconnected => 'НЕ ПОДКЛЮЧЕНО',
    };

    return PageBody(children: [
      Semantics(
        button: true,
        label: state == VpnState.disconnected ? 'Подключить' : 'Отключить',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: server == null ? null : app.toggle,
          child: SizedBox(height: 270, child: AsciiGlobe(mode: mode)),
        ),
      ),
      const SizedBox(height: 6),
      Text(title, textAlign: TextAlign.center, style: mono(c.text, 17, weight: FontWeight.w800, spacing: 2)),
      const SizedBox(height: 6),
      // Не фиксированная высота: с крупным шрифтом системы строка выше 20 точек, и текст обрезался снизу.
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 20),
        child: state == VpnState.connected
            ? _Timer(since: app.status.since)
            : Text(server == null ? 'добавьте подписку, чтобы начать' : 'нажмите на глобус или кнопку', textAlign: TextAlign.center, style: mono(c.muted, 12)),
      ),
      const SizedBox(height: 14),
      if (state == VpnState.connected)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(children: [
            Expanded(child: _Speed(label: 'ЗАГРУЗКА', value: app.rxSpeed, total: app.status.rx)),
            const SizedBox(width: 10),
            Expanded(child: _Speed(label: 'ОТДАЧА', value: app.txSpeed, total: app.status.tx)),
          ]),
        ),
      if (app.lastError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Panel(
            onTap: app.clearError,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('!', style: mono(c.text, 14, weight: FontWeight.w800)),
              const SizedBox(width: 10),
              Expanded(child: Text(app.lastError!, style: mono(c.text, 13, height: 1.45))),
            ]),
          ),
        ),
      if (app.needsService)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: AstatButton('УСТАНОВИТЬ СЛУЖБУ', loading: app.busy, onTap: app.installService),
        ),
      if (app.needsReconnect) ...[
        if (app.status.serverName case final name?)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('Сейчас: $name', textAlign: TextAlign.center, style: mono(c.muted, 12)),
          ),
        AstatButton('ПЕРЕПОДКЛЮЧИТЬ', loading: app.busy, onTap: app.reconnect),
        const SizedBox(height: 10),
      ],
      if (server != null || state != VpnState.disconnected)
        AstatButton(
          state == VpnState.disconnected ? 'ПОДКЛЮЧИТЬ' : 'ОТКЛЮЧИТЬ',
          ghost: state != VpnState.disconnected || app.needsService,
          loading: app.busy || state == VpnState.connecting || state == VpnState.stopping,
          onTap: app.toggle,
        ),
      if (server == null) ..._onboarding(context),
      if (profile != null) ...[
        const SectionTitle('Сервер'),
        Panel(
          onTap: () => _toggleMenu(_HomeMenu.servers),
          child: Semantics(
            expanded: _menu == _HomeMenu.servers,
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(server?.name ?? 'Нет серверов', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.text, 15, weight: FontWeight.w700)),
                  if (server != null) ...[
                    const SizedBox(height: 4),
                    Text(_serverHint(server), style: mono(c.muted, 12)),
                  ],
                ]),
              ),
              _MenuChevron(expanded: _menu == _HomeMenu.servers),
            ]),
          ),
        ),
        if (_menu == _HomeMenu.servers && profile.servers.isNotEmpty)
          _ChoiceList(key: _serverMenuKey, children: [
            for (final choice in profile.servers)
              _ChoiceRow(
                title: choice.name,
                subtitle: _serverHint(choice),
                selected: server?.id == choice.id,
                onTap: !app.canSelectServer ? null : () {
                  app.selectServer(profile, choice, reconnectImmediately: false);
                  setState(() => _menu = null);
                },
              ),
          ]),
        SectionTitle(profile.kind == ProfileKind.local ? 'Подписки' : 'Подписка'),
        _SubscriptionCard(
          profile: profile,
          expanded: _menu == _HomeMenu.subscriptions,
          onTap: () => _toggleMenu(_HomeMenu.subscriptions),
        ),
        if (_menu == _HomeMenu.subscriptions)
          _ChoiceList(key: _subscriptionMenuKey, children: [
            for (final choice in app.profiles)
              _ChoiceRow(
                title: choice.name,
                subtitle: plural(choice.servers.length, 'сервер', 'сервера', 'серверов'),
                selected: profile.id == choice.id,
                onTap: !app.canSelectServer ? null : () => _chooseProfile(choice),
              ),
          ]),
      ],
    ]);
  }

  String _serverHint(ServerEntry s) {
    if (s.auto) return 'самый быстрый сервер выбирается сам';
    final delay = s.delayMs == null ? '' : (s.delayMs! < 0 ? ' · не отвечает' : ' · ${s.delayMs} мс');
    return '${s.protocol}$delay';
  }

  List<Widget> _onboarding(BuildContext context) => [
        AstatButton('ВОЙТИ В АККАУНТ ASTAT', onTap: () => openLogin(context, app)),
        const SizedBox(height: 10),
        AstatButton('ДОБАВИТЬ ПОДПИСКУ ПО ССЫЛКЕ', ghost: true, onTap: () => showAddDialog(context, app)),
        const SizedBox(height: 14),
        Text(
          'Войдите в аккаунт, и подписка появится сама. Подойдёт и ссылка любого другого сервиса: VLESS, Hysteria2, Trojan, Shadowsocks, VMess.',
          textAlign: TextAlign.center,
          style: mono(context.c.muted, 12, height: 1.5),
        ),
      ];
}

class _Timer extends StatefulWidget {
  const _Timer({required this.since});
  final DateTime? since;

  @override
  State<_Timer> createState() => _TimerState();
}

class _TimerState extends State<_Timer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = widget.since;
    final d = since == null ? Duration.zero : DateTime.now().difference(since);
    return Text(formatDuration(d.isNegative ? Duration.zero : d), textAlign: TextAlign.center, style: mono(context.c.muted, 14, weight: FontWeight.w500, spacing: 1));
  }
}

class _Speed extends StatelessWidget {
  const _Speed({required this.label, required this.value, required this.total});
  final String label;
  final int value;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: mono(c.muted, 10, weight: FontWeight.w700, spacing: 1.2)),
        const SizedBox(height: 6),
        Text('${formatBytes(value)}/с', style: mono(c.text, 16, weight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('всего ${formatBytes(total)}', style: mono(c.muted, 11)),
      ]),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({required this.profile, required this.expanded, required this.onTap});
  final Profile profile;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final lines = <String>[];
    final exp = profile.expireAt;
    if (exp != null) {
      final days = exp.difference(DateTime.now()).inHours / 24;
      lines.add(days <= 0 ? 'срок истёк' : 'осталось ${plural(days.ceil(), 'день', 'дня', 'дней')}');
    }
    if (profile.usedBytes != null) {
      final total = profile.totalBytes ?? 0;
      lines.add(total > 0 ? '${formatBytes(profile.usedBytes!)} из ${formatBytes(total)}' : '${formatBytes(profile.usedBytes!)}, без лимита');
    }
    if (lines.isEmpty && profile.updatedAt != null) lines.add('серверов: ${profile.servers.length}');
    return Panel(
      onTap: onTap,
      child: Semantics(
        expanded: expanded,
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.text, 15, weight: FontWeight.w700)),
              if (lines.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(lines.join(' · '), style: mono(c.muted, 12))),
              if (profile.announce != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(profile.announce!, style: mono(c.text, 12, height: 1.45))),
              if (profile.lastError != null)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('Не удалось обновить: ${profile.lastError}', style: mono(c.text, 12, height: 1.45))),
            ]),
          ),
          _MenuChevron(expanded: expanded),
        ]),
      ),
    );
  }
}

class _MenuChevron extends StatelessWidget {
  const _MenuChevron({required this.expanded});
  final bool expanded;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Icon(expanded ? Icons.expand_less : Icons.expand_more, color: context.c.muted, size: 20),
      );
}

class _ChoiceList extends StatelessWidget {
  const _ChoiceList({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Panel(
          padding: EdgeInsets.zero,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 224),
            child: ListView.separated(
              primary: false,
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: children.length,
              itemBuilder: (_, index) => children[index],
              separatorBuilder: (_, _) => Divider(height: 1, color: context.c.border),
            ),
          ),
        ),
      );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.title, required this.subtitle, required this.selected, required this.onTap});
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: SettingRow(
          title: title,
          subtitle: subtitle,
          onTap: onTap,
          trailing: selected ? Icon(Icons.check, size: 16, color: context.c.text) : null,
        ),
      );
}

/// Окно добавления подписки или сервера. Сразу подставляет ссылку из буфера обмена, если она там есть.
Future<void> showAddDialog(BuildContext context, AppState app) async {
  final controller = TextEditingController();
  // На iOS чтение буфера без действия человека вызывает системный запрос «разрешить вставку» и задерживает
  // окно: там ссылку вставляют обычной командой «Вставить» в поле.
  if (!Platform.isIOS) {
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain).timeout(const Duration(seconds: 1)))?.text?.trim() ?? '';
      final candidate = normalizeImport(clip);
      if (candidate.startsWith('http') || RegExp(r'^(vless|vmess|trojan|ss|hysteria2|hy2|socks)://').hasMatch(candidate)) controller.text = clip;
    } catch (_) {}
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      var loading = false;
      String? error;
      return StatefulBuilder(builder: (ctx, setState) {
        Future<void> submit() async {
          setState(() {
            loading = true;
            error = null;
          });
          try {
            final message = await app.addFromText(controller.text);
            if (ctx.mounted) Navigator.of(ctx).pop();
            if (context.mounted) toast(context, message);
          } on SubscriptionException catch (e) {
            setState(() => error = e.message);
          } catch (_) {
            setState(() => error = 'Не удалось добавить');
          } finally {
            if (ctx.mounted) setState(() => loading = false);
          }
        }

        return AlertDialog(
          title: const Text('Добавить'),
          // с открытой клавиатурой на небольшом экране содержимое не помещается: пусть прокручивается, а не наезжает на кнопки
          scrollable: true,
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Text('Ссылка на подписку или на отдельный сервер. Можно вставить несколько серверов, каждый с новой строки.'),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                minLines: 2,
                maxLines: 5,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                style: mono(ctx.c.text, 13),
                decoration: const InputDecoration(hintText: 'https://… или vless://…'),
              ),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: mono(ctx.c.text, 12, height: 1.45))),
            ]),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
          actions: [
            Row(children: [
              Expanded(child: AstatButton('ОТМЕНА', ghost: true, small: true, onTap: loading ? null : () => Navigator.of(ctx).pop())),
              const SizedBox(width: 10),
              Expanded(child: AstatButton('ДОБАВИТЬ', small: true, loading: loading, onTap: submit)),
            ]),
          ],
        );
      });
    },
  );
}
