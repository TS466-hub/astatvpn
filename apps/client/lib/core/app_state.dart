import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'astat_api.dart';
import 'models.dart';
import 'routing_profile.dart';
import 'share_link.dart';
import 'storage.dart';
import 'subscription.dart';
import 'vpn.dart';
import 'vpn_desktop.dart';
import 'xray_config.dart';

const appVersion = '0.1.0';
const _localProfileId = 'local';
const _astatProfileId = 'astat';

TunPlatform get tunPlatform {
  if (Platform.isAndroid) return TunPlatform.android;
  if (Platform.isIOS) return TunPlatform.ios;
  if (Platform.isWindows) return TunPlatform.windows;
  if (Platform.isMacOS) return TunPlatform.macos;
  return TunPlatform.linux;
}

/// Достаёт адрес подписки из ссылок вида `happ://add/https://...`, `v2raytun://import/...`, `astatvpn://add?url=...`.
String normalizeImport(String input) {
  var text = input.trim();
  final m = RegExp(r'^[a-z0-9.+-]+://(?:add|import|install-config|install-sub|import-remote-profile|subscribe)/?[?/]?(.*)$', caseSensitive: false).firstMatch(text);
  if (m != null && !isShareLink(text)) {
    var rest = m.group(1) ?? '';
    final q = RegExp(r'(?:^|[?&])url=([^&#]+)').firstMatch(rest);
    if (q != null) rest = q.group(1)!;
    try {
      if (rest.contains('%3A') || rest.contains('%3a')) rest = Uri.decodeComponent(rest);
    } catch (_) {}
    if (rest.startsWith('http://') || rest.startsWith('https://')) text = rest;
  }
  return text;
}

class AppState extends ChangeNotifier {
  AppState({Storage? storage, AstatApi? api, Vpn? vpn, http.Client? client})
      : storage = storage ?? Storage(),
        api = api ?? AstatApi(),
        vpn = vpn ?? Vpn(),
        _http = client ?? http.Client();

  final Storage storage;
  final AstatApi api;
  final Vpn vpn;
  final http.Client _http;

  StoredState data = StoredState();
  String? token;
  AstatAccount? account;
  VpnStatus status = const VpnStatus();
  bool ready = false;
  bool pinging = false;
  bool busy = false;

  /// Скорость в байтах в секунду.
  int rxSpeed = 0, txSpeed = 0;
  String? lastError;

  /// Windows: системная служба не установлена или не отвечает, без неё подключиться нельзя.
  bool needsService = false;
  Map<String, String> _device = {};
  StreamSubscription<VpnStatus>? _sub;
  DateTime? _lastSample;
  int _lastRx = 0, _lastTx = 0;
  (String, String)? _connectedSelection;
  String? _connectedRouting;
  String? get _routingSignature => settings.routingProfile == null ? null : jsonEncode(settings.routingProfile!.toJson());

  (String, String)? get _selection {
    final p = profile;
    final s = server;
    return p == null || s == null ? null : (p.id, s.id);
  }

  bool get canSelectServer => !busy && (status.state == VpnState.connected || status.state == VpnState.disconnected);

  bool get needsReconnect => status.state == VpnState.connected && _selection != null && (_selection != _connectedSelection || _routingSignature != _connectedRouting);

  AppSettings get settings => data.settings;
  List<Profile> get profiles => data.profiles;
  bool get signedIn => token != null;

  Profile? get profile {
    for (final p in profiles) {
      if (p.id == data.profileId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  ServerEntry? get server {
    final p = profile;
    if (p == null || p.servers.isEmpty) return null;
    for (final s in p.servers) {
      if (s.id == data.serverId) return s;
    }
    return p.servers.first;
  }

  Future<void> init() async {
    data = await storage.load();
    token = await storage.readToken();
    status = await vpn.status();
    if (status.state != VpnState.disconnected && (status.serverName == null || status.serverName == server?.name)) {
      _connectedSelection = _selection;
      _connectedRouting = _routingSignature;
    }
    _sub = vpn.statusStream.listen(_onStatus);
    ready = true;
    notifyListeners();
    unawaited(_startup());
  }

  Future<void> _startup() async {
    _device = await vpn.deviceInfo();
    // На macOS службу ставит само приложение: если её нет или она старой версии, сразу показываем кнопку установки.
    final v = vpn;
    if (v is DesktopVpn && Platform.isMacOS) {
      needsService = !await v.serviceAvailable();
      notifyListeners();
    }
    if (token != null) await syncAccount();
    if (settings.autoUpdate) await refreshDue();
    if (settings.autoConnect && !needsService && status.state == VpnState.disconnected && server != null) await connect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _save() => unawaited(storage.save(data));

  void clearError() {
    lastError = null;
    notifyListeners();
  }

  void _onStatus(VpnStatus s) {
    final now = DateTime.now();
    if (s.state == VpnState.connected && _lastSample != null) {
      final ms = now.difference(_lastSample!).inMilliseconds;
      if (ms > 0 && s.rx >= _lastRx && s.tx >= _lastTx) {
        rxSpeed = ((s.rx - _lastRx) * 1000 / ms).round();
        txSpeed = ((s.tx - _lastTx) * 1000 / ms).round();
      }
    } else {
      rxSpeed = txSpeed = 0;
    }
    _lastSample = s.state == VpnState.connected ? now : null;
    _lastRx = s.rx;
    _lastTx = s.tx;
    if (s.error != null && s.error != status.error) lastError = s.error;
    status = s;
    notifyListeners();
  }

  // ---------- подключение ----------

  Future<void> connect() => _connect();

  Future<void> _connect({bool reconnect = false}) async {
    if (busy || status.state != (reconnect ? VpnState.connected : VpnState.disconnected)) return;
    final s = server;
    if (s == null) {
      lastError = 'Сначала добавьте подписку';
      notifyListeners();
      return;
    }
    final selection = _selection;
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      if (!await vpn.prepare()) {
        lastError = 'Без разрешения на VPN подключиться нельзя';
        return;
      }
      final routingSignature = _routingSignature;
      final config = jsonEncode(buildXrayConfig(s, settings, tunPlatform));
      if (reconnect) {
        await vpn.stop();
        await _waitFor(VpnState.disconnected);
        if (status.state != VpnState.disconnected) {
          lastError = 'Не удалось отключить VPN для переподключения';
          return;
        }
      }
      await vpn.start(config: config, name: s.name, filter: settings.appFilter, apps: settings.apps);
      _connectedSelection = selection;
      _connectedRouting = routingSignature;
    } on VpnException catch (e) {
      lastError = e.message;
      final v = vpn;
      if (v is DesktopVpn) needsService = !await v.serviceAvailable();
    } on FormatException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = 'Не удалось подключиться';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Windows: ставит системную службу (появится запрос прав администратора) и подключается.
  Future<void> installService() async {
    final v = vpn;
    if (v is! DesktopVpn || busy) return;
    busy = true;
    lastError = null;
    notifyListeners();
    try {
      await v.installService();
      needsService = false;
    } on VpnException catch (e) {
      lastError = e.message;
    } finally {
      busy = false;
      notifyListeners();
    }
    if (!needsService && server != null) await connect();
  }

  Future<void> disconnect() async {
    try {
      await vpn.stop();
    } on VpnException catch (e) {
      lastError = e.message;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (!canSelectServer) return;
    if (status.state == VpnState.disconnected) {
      await connect();
    } else {
      await disconnect();
    }
  }

  Future<void> reconnect() => _connect(reconnect: true);

  ServerEntry? rememberedServer(Profile p) {
    final id = profile?.id == p.id ? server?.id : p.lastServerId;
    return p.servers.where((s) => s.id == id).firstOrNull;
  }

  void selectProfile(Profile p) {
    if (!canSelectServer) return;
    _setSelection(p, rememberedServer(p) ?? p.servers.firstOrNull);
  }

  Future<void> selectServer(Profile p, ServerEntry s, {bool reconnectImmediately = true}) async {
    if (!canSelectServer) return;
    final changed = _selection != (p.id, s.id);
    _setSelection(p, s);
    if (changed && reconnectImmediately && status.state == VpnState.connected) await reconnect();
  }

  void _setSelection(Profile p, ServerEntry? s) {
    final previous = profile;
    final previousServer = server;
    if (previous != null && previousServer != null) previous.lastServerId = previousServer.id;
    data.profileId = p.id;
    data.serverId = s?.id;
    p.lastServerId = s?.id;
    _save();
    notifyListeners();
  }

  Future<void> _waitFor(VpnState state) async {
    for (var i = 0; i < 50 && status.state != state; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  void updateSettings(void Function(AppSettings s) change) {
    change(settings);
    _save();
    notifyListeners();
  }

  Future<RoutingProfile> importRoutingProfile(String input) async {
    final payload = routingPayload(input);
    final uri = Uri.tryParse(payload);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return parseRoutingProfile(payload);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('Для импорта по ссылке нужен HTTPS-адрес');
    }
    final parts = uri.pathSegments;
    final source = uri.host == 'github.com' && parts.length >= 5 && parts[2] == 'blob'
        ? Uri.https('raw.githubusercontent.com', '/${parts[0]}/${parts[1]}/${parts.skip(3).join('/')}')
        : uri;
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', source)).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) throw FormatException('Сервер профиля ответил кодом ${response.statusCode}');
      if ((response.contentLength ?? 0) > routingImportLimit) throw const FormatException('Профиль слишком большой');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > routingImportLimit) throw const FormatException('Профиль слишком большой');
        bytes.add(chunk);
      }
      return parseRoutingProfile(routingPayload(utf8.decode(bytes.takeBytes())));
    } on TimeoutException {
      throw const FormatException('Сервер профиля не отвечает');
    } on http.ClientException {
      throw const FormatException('Не удалось загрузить профиль по ссылке');
    } finally {
      client.close();
    }
  }

  // ---------- подписки ----------

  void toggleCollapsed(Profile p) {
    p.collapsed = !p.collapsed;
    _save();
    notifyListeners();
  }

  Map<String, String> get _subHeaders => {
        'user-agent': 'AstatVPN/$appVersion (${Platform.operatingSystem})',
        'accept': '*/*',
        'x-hwid': data.deviceId,
        'x-device-os': _osName,
        'x-ver-os': _device['osVersion'] ?? Platform.operatingSystemVersion.split(' ').first,
        'x-device-model': _device['model'] ?? Platform.localHostname,
      };

  String get _osName => switch (Platform.operatingSystem) {
        'android' => 'Android',
        'ios' => 'iOS',
        'windows' => 'Windows',
        'macos' => 'macOS',
        _ => 'Linux',
      };

  Future<SubscriptionData> _fetch(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('https') || uri.isScheme('http')) || uri.host.isEmpty) throw SubscriptionException('Это не ссылка на подписку');
    http.Response res;
    try {
      res = await _http.get(uri, headers: _subHeaders).timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw SubscriptionException('Сервер подписки не отвечает');
    } on HandshakeException {
      throw SubscriptionException('Не удалось установить защищённое соединение с сервером подписки');
    } catch (_) {
      throw SubscriptionException('Нет связи с сервером подписки. Проверьте интернет.');
    }
    if (res.headers['x-hwid-limit'] == 'true') throw SubscriptionException('Достигнут лимит устройств в подписке. Удалите лишнее устройство в личном кабинете.');
    if (res.statusCode == 404 || res.statusCode == 403) throw SubscriptionException('Подписка не найдена или отключена');
    if (res.statusCode >= 400) throw SubscriptionException('Сервер подписки ответил ошибкой ${res.statusCode}');
    return parseSubscription(utf8.decode(res.bodyBytes, allowMalformed: true), res.headers);
  }

  void _apply(Profile p, SubscriptionData d) {
    final old = {for (final s in p.servers) s.id: s.delayMs};
    for (final s in d.servers) {
      s.delayMs = old[s.id];
    }
    p.servers = d.servers;
    p.updatedAt = DateTime.now();
    p.usedBytes = d.usedBytes;
    p.totalBytes = d.totalBytes;
    p.expireAt = d.expireAt;
    if (d.updateHours != null) p.updateHours = d.updateHours!;
    p.supportUrl = d.supportUrl;
    p.announce = d.announce;
    p.lastError = null;
    if (d.title != null && p.kind == ProfileKind.url) p.name = d.title!;
  }

  /// Добавляет подписку по ссылке или серверы из вставленного текста. Возвращает сообщение для человека.
  Future<String> addFromText(String input) async {
    final text = normalizeImport(input);
    if (text.isEmpty) throw SubscriptionException('Вставьте ссылку на подписку или сервер');
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final existing = profiles.where((p) => p.url == text).firstOrNull;
      final d = await _fetch(text);
      final p = existing ?? Profile(id: stableId('$text|${DateTime.now().microsecondsSinceEpoch}'), name: d.title ?? Uri.parse(text).host, kind: ProfileKind.url, url: text);
      _apply(p, d);
      if (existing == null) profiles.add(p);
      _setSelection(p, p.servers.first);
      return existing == null ? 'Подписка добавлена: ${p.servers.length} серверов' : 'Подписка обновлена';
    }
    final d = parseSubscription(text);
    var local = profiles.where((p) => p.id == _localProfileId).firstOrNull;
    if (local == null) {
      local = Profile(id: _localProfileId, name: 'Мои серверы', kind: ProfileKind.local);
      profiles.add(local);
    }
    final known = {for (final s in local.servers) s.id};
    final fresh = d.servers.where((s) => !known.contains(s.id)).toList();
    local.servers = [...local.servers, ...fresh];
    local.updatedAt = DateTime.now();
    if (fresh.isNotEmpty) {
      _setSelection(local, fresh.first);
    }
    if (fresh.isEmpty) return 'Эти серверы уже добавлены';
    return d.skipped > 0 ? 'Добавлено серверов: ${fresh.length}. Не распознано: ${d.skipped}' : 'Добавлено серверов: ${fresh.length}';
  }

  Future<bool> refreshProfile(Profile p) async {
    if (p.url == null) return true;
    try {
      _apply(p, await _fetch(p.url!));
      return true;
    } on SubscriptionException catch (e) {
      p.lastError = e.message;
      return false;
    } finally {
      _save();
      notifyListeners();
    }
  }

  Future<void> refreshDue() async {
    for (final p in List.of(profiles)) {
      if (p.needsUpdate) await refreshProfile(p);
    }
  }

  void removeProfile(Profile p) {
    profiles.remove(p);
    if (data.profileId == p.id) {
      data.profileId = null;
      data.serverId = null;
    }
    _save();
    notifyListeners();
  }

  void removeServer(Profile p, ServerEntry s) {
    p.servers = p.servers.where((x) => x.id != s.id).toList();
    if (p.servers.isEmpty && p.kind == ProfileKind.local) profiles.remove(p);
    _save();
    notifyListeners();
  }

  /// Замер задержки. Идёт через ядро по пять серверов, поэтому результат отражает настоящее подключение, а не просто ответ порта.
  Future<void> pingProfile(Profile p) async {
    if (pinging) return;
    if (status.state != VpnState.disconnected) {
      lastError = 'Замер задержки работает при выключенном VPN';
      notifyListeners();
      return;
    }
    pinging = true;
    notifyListeners();
    try {
      final list = p.servers.where((s) => !s.auto).toList();
      // ядро замеряет все серверы одновременно; части нужны только для очень длинных списков
      const step = 64;
      for (var i = 0; i < list.length; i += step) {
        final chunk = list.sublist(i, i + step > list.length ? list.length : i + step);
        final result = await vpn.ping(chunk.map((s) => jsonEncode(buildProbeConfig(s))).toList());
        for (var k = 0; k < chunk.length && k < result.length; k++) {
          chunk[k].delayMs = result[k];
        }
        notifyListeners();
      }
      _save();
    } on VpnException catch (e) {
      lastError = e.message;
    } finally {
      pinging = false;
      notifyListeners();
    }
  }

  // ---------- аккаунт ASTAT ----------

  Future<void> setToken(String value) async {
    token = value;
    await storage.writeToken(value);
    notifyListeners();
    await syncAccount();
  }

  Future<void> signOut() async {
    token = null;
    account = null;
    await storage.writeToken(null);
    final p = profiles.where((p) => p.id == _astatProfileId).firstOrNull;
    if (p != null) removeProfile(p);
    notifyListeners();
  }

  /// Обновляет сведения об аккаунте и подтягивает его подписку в список.
  Future<void> syncAccount() async {
    final t = token;
    if (t == null) return;
    try {
      account = await api.me(t);
    } on ApiException catch (e) {
      if (e.unauthorized) {
        token = null;
        account = null;
        await storage.writeToken(null);
        lastError = 'Сессия истекла. Войдите в аккаунт заново.';
      }
      notifyListeners();
      return;
    }
    final url = account!.subUrl;
    var p = profiles.where((p) => p.id == _astatProfileId).firstOrNull;
    if (url == null || url.isEmpty) {
      if (p != null) removeProfile(p);
      notifyListeners();
      return;
    }
    if (p == null) {
      p = Profile(id: _astatProfileId, name: 'AstatVPN', kind: ProfileKind.astat, url: url);
      profiles.insert(0, p);
      data.profileId ??= p.id;
    }
    final changed = p.url != url;
    p.url = url;
    _save();
    notifyListeners();
    if (changed || p.servers.isEmpty || p.needsUpdate) await refreshProfile(p);
  }
}
