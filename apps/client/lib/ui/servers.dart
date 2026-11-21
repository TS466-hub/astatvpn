import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'home.dart';
import 'theme.dart';
import 'widgets.dart';

class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final profiles = app.profiles;
    return PageBody(children: [
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(children: [
          Expanded(child: AstatButton('+ ДОБАВИТЬ', small: true, onTap: () => showAddDialog(context, app))),
          const SizedBox(width: 10),
          Expanded(
            child: AstatButton(
              'ЗАМЕРИТЬ',
              ghost: true,
              small: true,
              loading: app.pinging,
              onTap: profiles.isEmpty
                  ? null
                  : () async {
                      for (final p in List.of(profiles)) {
                        await app.pingProfile(p);
                      }
                      if (context.mounted && app.lastError != null) toast(context, app.lastError!);
                    },
            ),
          ),
        ]),
      ),
      if (profiles.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 60),
          child: Text('Серверов пока нет.\nДобавьте подписку или войдите в аккаунт ASTAT.', textAlign: TextAlign.center, style: mono(c.muted, 13, height: 1.6)),
        ),
      for (final p in profiles) ...[
        _ProfileHeader(
          profile: p,
          selected: app.profile?.id == p.id ? app.server : null,
          onToggle: () => app.toggleCollapsed(p),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (p.url != null) _IconAction(label: 'Обновить', glyph: '↻', onTap: () => _refresh(context, p)),
            if (p.kind != ProfileKind.astat) _IconAction(label: 'Удалить', glyph: '×', onTap: () => _confirmRemove(context, p)),
          ]),
        ),
        if (p.lastError != null)
          Padding(padding: const EdgeInsets.only(bottom: 8, left: 2), child: Text('Не удалось обновить: ${p.lastError}', style: mono(c.text, 12, height: 1.45))),
        if (!p.collapsed)
          RowsPanel(children: [
            for (final s in p.servers)
              _ServerRow(
                server: s,
                selected: app.profile?.id == p.id && app.server?.id == s.id,
                onTap: () => app.selectServer(p, s),
                onLongPress: p.kind == ProfileKind.local ? () => _confirmRemoveServer(context, p, s) : null,
              ),
          ]),
      ],
    ]);
  }

  Future<void> _refresh(BuildContext context, Profile p) async {
    final ok = await app.refreshProfile(p);
    if (context.mounted) toast(context, ok ? 'Подписка обновлена' : (p.lastError ?? 'Не удалось обновить'));
  }

  Future<void> _confirmRemove(BuildContext context, Profile p) async {
    final yes = await _confirm(context, 'Удалить «${p.name}»?', 'Серверы этой подписки пропадут из приложения. Сама подписка у провайдера останется.');
    if (yes) app.removeProfile(p);
  }

  Future<void> _confirmRemoveServer(BuildContext context, Profile p, ServerEntry s) async {
    final yes = await _confirm(context, 'Удалить «${s.name}»?', 'Сервер пропадёт из списка.');
    if (yes) app.removeServer(p, s);
  }
}

Future<bool> _confirm(BuildContext context, String title, String text) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
      actions: [
        Row(children: [
          Expanded(child: AstatButton('ОТМЕНА', ghost: true, small: true, onTap: () => Navigator.of(ctx).pop(false))),
          const SizedBox(width: 10),
          Expanded(child: AstatButton('УДАЛИТЬ', small: true, onTap: () => Navigator.of(ctx).pop(true))),
        ]),
      ],
    ),
  );
  return r == true;
}

/// Заголовок подписки: нажатие сворачивает и разворачивает её список серверов.
class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.selected, required this.onToggle, required this.trailing});
  final Profile profile;

  /// Выбранный сервер, если он из этой подписки: в свёрнутом виде показывается под заголовком.
  final ServerEntry? selected;
  final VoidCallback onToggle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final collapsed = profile.collapsed;
    final count = profile.servers.length;
    final hint = [plural(count, 'сервер', 'сервера', 'серверов'), if (selected != null) 'выбран ${selected!.name}'].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 2, 8),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            expanded: !collapsed,
            label: '${profile.name}, ${collapsed ? 'развернуть' : 'свернуть'}',
            excludeSemantics: true,
            child: InkWell(
              onTap: onToggle,
              borderRadius: BorderRadius.circular(radius),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(collapsed ? '[+]' : '[-]', style: mono(c.text, 11, weight: FontWeight.w700)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(profile.name.toUpperCase(),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.muted, 11, weight: FontWeight.w700, spacing: 1.4)),
                    ),
                  ]),
                  if (collapsed)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, left: 32),
                      child: Text(hint, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.muted, 11)),
                    ),
                ]),
              ),
            ),
          ),
        ),
        trailing,
      ]),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({required this.label, required this.glyph, required this.onTap});
  final String label;
  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Tooltip(
          message: label,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(radius),
            child: SizedBox(width: 40, height: 32, child: Center(child: Text(glyph, style: mono(context.c.text, 18, weight: FontWeight.w500, height: 1)))),
          ),
        ),
      );
}

class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.server, required this.selected, required this.onTap, this.onLongPress});
  final ServerEntry server;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = server.delayMs;
    final delay = server.auto ? 'авто' : (d == null ? '' : (d < 0 ? 'нет ответа' : '$d мс'));
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          color: selected ? c.surface2 : null,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(children: [
            Text(selected ? '>' : ' ', style: mono(c.text, 14, weight: FontWeight.w800)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(server.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(c.text, 14, weight: selected ? FontWeight.w700 : FontWeight.w500)),
                if (!server.auto) Padding(padding: const EdgeInsets.only(top: 3), child: Text(server.protocol, style: mono(c.muted, 11))),
              ]),
            ),
            if (delay.isNotEmpty) Text(delay, style: mono(d != null && d < 0 ? c.muted : c.text, 12, weight: FontWeight.w500)),
          ]),
        ),
      ),
    );
  }
}
