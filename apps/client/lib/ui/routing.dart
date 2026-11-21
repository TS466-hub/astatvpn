import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/routing_profile.dart';
import '../core/vpn.dart';
import 'widgets.dart';

class RoutingScreen extends StatelessWidget {
  const RoutingScreen({super.key, required this.app});
  final AppState app;

  Future<void> _edit(
    BuildContext context,
    RoutingProfile profile, {
    String? id,
  }) async {
    final edited = await Navigator.of(context).push<RoutingProfile>(
      MaterialPageRoute(builder: (_) => _RoutingEditor(profile: profile)),
    );
    if (edited == null || !context.mounted) return;
    final key =
        id ?? stableId(DateTime.now().microsecondsSinceEpoch.toString());
    app.updateSettings((s) => s.routingProfiles[key] = edited);
  }

  Future<void> _import(BuildContext context) async {
    final profile = await showDialog<RoutingProfile>(
      context: context,
      builder: (_) => _ImportRoutingDialog(app: app),
    );
    if (profile != null && context.mounted) await _edit(context, profile);
  }

  Future<void> _delete(BuildContext context, String id, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Удалить «$name»?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    app.updateSettings((s) {
      s.routingProfiles.remove(id);
      if (s.routingProfileId == id) s.routingProfileId = null;
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final settings = app.settings;
      return Scaffold(
        appBar: AppBar(title: const Text('Маршрутизация')),
        body: PageBody(
          children: [
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _import(context),
                  icon: const Icon(Icons.download),
                  label: const Text('Импорт'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      _edit(context, const RoutingProfile(name: '')),
                  icon: const Icon(Icons.add),
                  label: const Text('Создать профиль'),
                ),
              ],
            ),
            const SectionTitle('Как направлять трафик'),
            RowsPanel(
              children: [
                SettingRow(
                  title: 'Стандартные правила',
                  subtitle: 'Настройки приложения и текущей подписки',
                  trailing: Check(settings.routingProfile == null),
                  onTap: () =>
                      app.updateSettings((s) => s.routingProfileId = null),
                ),
                for (final MapEntry(key: id, value: profile)
                    in settings.routingProfiles.entries)
                  SettingRow(
                    title: profile.name,
                    subtitle:
                        '${plural(profile.count, 'запись', 'записи', 'записей')} · остальное ${profile.globalProxy ? 'через VPN' : 'напрямую'}',
                    onTap: () =>
                        app.updateSettings((s) => s.routingProfileId = id),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Check(settings.routingProfileId == id),
                        PopupMenuButton<String>(
                          tooltip: 'Действия с профилем',
                          onSelected: (action) async {
                            if (action == 'edit') {
                              await _edit(context, profile, id: id);
                            } else {
                              await _delete(context, id, profile.name);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'edit',
                              child: Text('Редактировать'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Удалить'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (app.needsReconnect) ...[
              const SizedBox(height: 16),
              const Text('Переподключите VPN, чтобы применить изменения.'),
              const SizedBox(height: 8),
              AstatButton(
                'ПЕРЕПОДКЛЮЧИТЬ',
                loading: app.busy,
                onTap: () async {
                  await app.reconnect();
                  if (context.mounted && app.lastError != null) {
                    toast(context, app.lastError!);
                  }
                },
              ),
            ] else if (app.status.state == VpnState.disconnected &&
                settings.routingProfile != null) ...[
              const SizedBox(height: 16),
              const Text('Профиль будет применён при следующем подключении.'),
            ],
          ],
        ),
      );
    },
  );
}

class _ImportRoutingDialog extends StatefulWidget {
  const _ImportRoutingDialog({required this.app});
  final AppState app;

  @override
  State<_ImportRoutingDialog> createState() => _ImportRoutingDialogState();
}

class _ImportRoutingDialogState extends State<_ImportRoutingDialog> {
  final _input = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await widget.app.importRoutingProfile(_input.text);
      if (mounted) Navigator.pop(context, profile);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Импорт из Happ или Incy'),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Вставьте ссылку на профиль, JSON или Base64. Перед сохранением можно проверить и изменить правила.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 3,
            maxLines: 6,
            inputFormatters: [
              LengthLimitingTextInputFormatter(routingImportLimit),
            ],
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Ссылка или содержимое профиля',
              errorText: _error,
              errorMaxLines: 4,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Используются DNS текущего подключения и встроенные GEO-базы AstatVPN.',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: _loading ? null : _preview,
        child: Text(_loading ? 'Загрузка…' : 'Предпросмотр'),
      ),
    ],
  );
}

class _RoutingEditor extends StatefulWidget {
  const _RoutingEditor({required this.profile});
  final RoutingProfile profile;

  @override
  State<_RoutingEditor> createState() => _RoutingEditorState();
}

class _RoutingEditorState extends State<_RoutingEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final Map<RouteAction, TextEditingController> _rules;
  late bool _globalProxy;
  late List<RouteAction> _order;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _name = TextEditingController(text: profile.name);
    _globalProxy = profile.globalProxy;
    _order = List.of(profile.order);
    _rules = {
      for (final action in RouteAction.values)
        action: TextEditingController(
          text: [
            for (final rule
                in profile.groups[action]?.domains ?? const <String>[])
              rule.startsWith('domain:') ? rule.substring(7) : rule,
            ...?profile.groups[action]?.ips,
          ].join('\n'),
        ),
    };
  }

  @override
  void dispose() {
    _name.dispose();
    for (final controller in _rules.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    if (_name.text.trim().isEmpty) {
      toast(context, 'Введите название профиля');
      return;
    }
    final groups = <RouteAction, RouteGroup>{};
    for (final entry in _rules.entries) {
      try {
        groups[entry.key] = parseManualRules(entry.value.text);
      } on FormatException catch (e) {
        toast(context, '${entry.key.label}: ${e.message}');
        return;
      }
    }
    Navigator.pop(
      context,
      RoutingProfile(
        name: _name.text.trim(),
        globalProxy: _globalProxy,
        order: _order,
        strategy: widget.profile.strategy,
        groups: groups,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Профиль маршрутизации')),
    bottomNavigationBar: SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: AstatButton('СОХРАНИТЬ', onTap: _save),
            ),
          ),
        ],
      ),
    ),
    body: Form(
      key: _form,
      child: PageBody(
        children: [
          const SizedBox(height: 12),
          TextFormField(
            controller: _name,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Название'),
            validator: (text) =>
                text == null || text.trim().isEmpty ? 'Введите название' : null,
          ),
          const SectionTitle('Трафик без совпадений'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('Через VPN')),
              ButtonSegment(value: false, label: Text('Напрямую')),
            ],
            selected: {_globalProxy},
            onSelectionChanged: (value) =>
                setState(() => _globalProxy = value.single),
          ),
          const SectionTitle('Правила по приоритету'),
          const Text(
            'Первое совпадение определяет маршрут. По одному домену, IP, подсети или GEO-категории на строку.',
          ),
          for (var i = 0; i < _order.length; i++) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _order[i].label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (i > 0)
                  IconButton(
                    tooltip: 'Повысить приоритет: ${_order[i].label}',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: () => setState(() {
                      final action = _order.removeAt(i);
                      _order.insert(i - 1, action);
                    }),
                  ),
              ],
            ),
            TextFormField(
              key: ValueKey(_order[i]),
              controller: _rules[_order[i]],
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                hintText: 'example.com\n192.0.2.0/24',
                errorMaxLines: 3,
              ),
              validator: (text) {
                try {
                  parseManualRules(text ?? '');
                  return null;
                } on FormatException catch (e) {
                  return e.message;
                }
              },
            ),
          ],
        ],
      ),
    ),
  );
}
