import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_state.dart';
import '../core/astat_api.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> openLogin(BuildContext context, AppState app) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LoginScreen(app: app)));

enum _Mode { login, register, reset }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.app});
  final AppState app;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  _Mode _mode = _Mode.login;
  bool _busy = false;
  String? _error;

  /// Идентификатор заказанного звонка: после него вводится код.
  String? _callId;
  int _retryIn = 0;
  Timer? _retryTimer;

  /// Ключ входа через Telegram, пока ждём подтверждения в боте.
  String? _tgToken;
  String? _tgUrl;
  Timer? _tgTimer;
  DateTime? _tgDeadline;

  AstatApi get _api => widget.app.api;

  @override
  void dispose() {
    _retryTimer?.cancel();
    _tgTimer?.cancel();
    _phone.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _done(String token) async {
    await widget.app.setToken(token);
    if (!mounted) return;
    Navigator.of(context).pop();
    toast(context, widget.app.account?.subUrl == null ? 'Вы вошли. Подписки пока нет: оформите её в личном кабинете.' : 'Вы вошли, подписка добавлена');
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Что-то пошло не так. Попробуйте ещё раз.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- Telegram ----------

  Future<void> _telegram() => _run(() async {
        final link = await _api.telegramStart();
        if (link.url == null) throw ApiException('Вход через Telegram сейчас недоступен');
        _tgToken = link.token;
        _tgUrl = link.url;
        _tgDeadline = DateTime.now().add(Duration(seconds: link.expiresInSec));
        _tgTimer?.cancel();
        _tgTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollTelegram());
        await launchUrl(Uri.parse(link.url!), mode: LaunchMode.externalApplication).catchError((_) => false);
      });

  Future<void> _pollTelegram() async {
    final token = _tgToken;
    if (token == null) return;
    if (DateTime.now().isAfter(_tgDeadline!)) {
      _cancelTelegram('Время ожидания вышло. Нажмите «Войти через Telegram» ещё раз.');
      return;
    }
    try {
      final r = await _api.telegramCheck(token);
      if (r.status == 'ok' && r.accessToken != null) {
        _tgTimer?.cancel();
        _tgToken = null;
        await _done(r.accessToken!);
      } else if (r.status == 'expired') {
        _cancelTelegram('Ссылка устарела. Нажмите «Войти через Telegram» ещё раз.');
      }
    } catch (_) {
      // сеть могла моргнуть, следующая попытка через две секунды
    }
  }

  void _cancelTelegram([String? message]) {
    _tgTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _tgToken = null;
      _error = message;
    });
  }

  // ---------- номер телефона ----------

  Future<void> _submitPhone() => _run(() async {
        final phone = _phone.text.trim();
        if (phone.replaceAll(RegExp(r'\D'), '').length < 10) throw ApiException('Введите номер телефона полностью');
        if (_mode == _Mode.login) {
          if (_password.text.isEmpty) throw ApiException('Введите пароль');
          await _done(await _api.login(phone, _password.text));
          return;
        }
        if (_callId == null) {
          await _startCall(phone);
          return;
        }
        if (!RegExp(r'^\d{4}$').hasMatch(_code.text.trim())) throw ApiException('Введите 4 цифры');
        if (_password.text.length < 8) throw ApiException('Пароль должен быть не короче 8 символов');
        await _done(await _api.finishCall(_mode.name, _callId!, _code.text.trim(), _password.text));
      });

  Future<void> _startCall(String phone) async {
    final r = await _api.startCall(phone, _mode.name);
    _retryTimer?.cancel();
    setState(() {
      _callId = r.id;
      _retryIn = r.retryInSec;
      _code.clear();
    });
    _retryTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _retryIn <= 0) {
        t.cancel();
        return;
      }
      setState(() => _retryIn--);
    });
  }

  void _switch(_Mode mode) => setState(() {
        _mode = mode;
        _callId = null;
        _error = null;
        _password.clear();
        _code.clear();
      });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final waitingTg = _tgToken != null;
    return Scaffold(
      appBar: AppBar(title: const Text('ВХОД')),
      body: PageBody(children: [
        const SectionTitle('Через Telegram'),
        if (!waitingTg)
          AstatButton('ВОЙТИ ЧЕРЕЗ TELEGRAM', loading: _busy && _mode == _Mode.login && _callId == null && _phone.text.isEmpty, onTap: _busy ? null : _telegram)
        else
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Подтвердите вход в боте. Приложение продолжит само, как только бот ответит.', style: mono(c.text, 13, height: 1.5)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: AstatButton('ОТКРЫТЬ БОТА', small: true, onTap: () => launchUrl(Uri.parse(_tgUrl!), mode: LaunchMode.externalApplication))),
                const SizedBox(width: 10),
                Expanded(child: AstatButton('ОТМЕНА', ghost: true, small: true, onTap: _cancelTelegram)),
              ]),
            ]),
          ),
        SectionTitle(switch (_mode) { _Mode.login => 'По номеру телефона', _Mode.register => 'Регистрация по номеру', _Mode.reset => 'Новый пароль' }),
        TextField(
          controller: _phone,
          enabled: _callId == null,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d+\-() ]'))],
          style: mono(c.text, 15),
          decoration: const InputDecoration(labelText: 'Номер телефона', hintText: '+7 900 000-00-00'),
        ),
        if (_callId != null) ...[
          const SizedBox(height: 12),
          Text('Вам позвонят. Отвечать не нужно: введите последние 4 цифры входящего номера.', style: mono(c.muted, 12, height: 1.5)),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: mono(c.text, 20, weight: FontWeight.w700, spacing: 8),
            decoration: const InputDecoration(labelText: 'Последние 4 цифры', counterText: ''),
          ),
        ],
        if (_mode == _Mode.login || _callId != null) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofillHints: [_mode == _Mode.login ? AutofillHints.password : AutofillHints.newPassword],
            style: mono(c.text, 15),
            decoration: InputDecoration(labelText: _mode == _Mode.login ? 'Пароль' : 'Новый пароль, от 8 символов'),
            onSubmitted: (_) => _submitPhone(),
          ),
        ],
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: mono(c.text, 13, height: 1.45))),
        const SizedBox(height: 14),
        AstatButton(
          switch (_mode) {
            _Mode.login => 'ВОЙТИ',
            _ => _callId == null ? 'ПОЛУЧИТЬ ЗВОНОК' : (_mode == _Mode.register ? 'ЗАРЕГИСТРИРОВАТЬСЯ' : 'СОХРАНИТЬ ПАРОЛЬ'),
          },
          loading: _busy,
          onTap: waitingTg ? null : _submitPhone,
        ),
        if (_callId != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: AstatButton(
              _retryIn > 0 ? 'ПОЗВОНИТЬ СНОВА ЧЕРЕЗ ${_retryIn ~/ 60}:${(_retryIn % 60).toString().padLeft(2, '0')}' : 'ПОЗВОНИТЬ СНОВА',
              ghost: true,
              small: true,
              onTap: _retryIn > 0 || _busy ? null : () => _run(() => _startCall(_phone.text.trim())),
            ),
          ),
        const SizedBox(height: 18),
        Wrap(alignment: WrapAlignment.center, spacing: 18, runSpacing: 8, children: [
          if (_mode != _Mode.login) _Link('Уже есть аккаунт', () => _switch(_Mode.login)),
          if (_mode != _Mode.register) _Link('Регистрация', () => _switch(_Mode.register)),
          if (_mode != _Mode.reset) _Link('Забыли пароль?', () => _switch(_Mode.reset)),
        ]),
      ]),
    );
  }
}

class _Link extends StatelessWidget {
  const _Link(this.text, this.onTap);
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(text, style: mono(context.c.text, 13).copyWith(decoration: TextDecoration.underline, decorationColor: context.c.muted)),
        ),
      );
}
