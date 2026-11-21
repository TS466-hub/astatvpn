import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const astatHost = 'app.autohitech.shop';
const astatApiBase = 'https://$astatHost/api/v1';
const astatSite = 'https://$astatHost';

class ApiException implements Exception {
  ApiException(this.message, {this.code, this.status = 0});
  final String message;
  final String? code;
  final int status;
  bool get unauthorized => status == 401;
  @override
  String toString() => message;
}

/// Сведения об аккаунте ASTAT, нужные приложению.
class AstatAccount {
  AstatAccount({required this.name, required this.state, this.planName, this.expiresAt, this.daysLeft = 0, this.subUrl, this.usedBytes = 0, this.limitBytes = 0, this.deviceLimit = 0, this.trialAvailable = false});
  final String name;

  /// active | expired | none и другие состояния подписки с сервера.
  final String state;
  final String? planName;
  final DateTime? expiresAt;
  final int daysLeft;
  final String? subUrl;
  final int usedBytes;
  final int limitBytes;
  final int deviceLimit;
  final bool trialAvailable;

  static AstatAccount fromMe(Map<String, dynamic> me) {
    final sub = ((me['subscription'] as Map?) ?? {}).cast<String, dynamic>();
    final first = (me['firstName'] ?? '').toString();
    final user = (me['username'] ?? '').toString();
    return AstatAccount(
      name: first.isNotEmpty ? first : (user.isNotEmpty ? '@$user' : 'Аккаунт'),
      state: (sub['state'] ?? 'none').toString(),
      planName: sub['planName'] as String?,
      expiresAt: sub['expiresAt'] == null ? null : DateTime.tryParse(sub['expiresAt'].toString()),
      daysLeft: (sub['daysLeft'] as num?)?.toInt() ?? 0,
      subUrl: sub['subUrl'] as String?,
      usedBytes: (sub['trafficUsedBytes'] as num?)?.toInt() ?? 0,
      limitBytes: (sub['trafficLimitBytes'] as num?)?.toInt() ?? 0,
      deviceLimit: ((sub['deviceLimit'] as num?)?.toInt() ?? 0) + ((sub['extraDevices'] as num?)?.toInt() ?? 0),
      trialAvailable: me['trialAvailable'] == true,
    );
  }
}

class AstatApi {
  AstatApi({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<dynamic> _request(String method, String path, {Object? body, String? token}) async {
    final headers = {
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
    http.Response res;
    try {
      final uri = Uri.parse('$astatApiBase$path');
      final future = method == 'GET' ? _client.get(uri, headers: headers) : _client.post(uri, headers: headers, body: body == null ? null : jsonEncode(body));
      res = await future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw ApiException('Сервер не отвечает. Проверьте интернет и попробуйте ещё раз.');
    } on SocketException {
      throw ApiException('Нет связи с сервером. Проверьте интернет.');
    } on http.ClientException {
      throw ApiException('Нет связи с сервером. Проверьте интернет.');
    } on HandshakeException {
      throw ApiException('Не удалось установить защищённое соединение с сервером.');
    }
    dynamic data;
    try {
      data = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (res.statusCode >= 400) {
      final err = data is Map ? data['error'] : null;
      throw ApiException(
        err is Map && err['message'] is String ? err['message'] as String : 'Ошибка сервера (${res.statusCode})',
        code: err is Map ? err['code']?.toString() : null,
        status: res.statusCode,
      );
    }
    return data;
  }

  Future<String> login(String phone, String password) async => (await _request('POST', '/auth/phone/login', body: {'phone': phone, 'password': password}))['accessToken'] as String;

  /// Заказывает звонок с кодом. `purpose`: register или reset.
  Future<({String id, int retryInSec})> startCall(String phone, String purpose) async {
    final r = await _request('POST', '/auth/phone/start', body: {'phone': phone, 'purpose': purpose});
    return (id: r['id'] as String, retryInSec: (r['retryInSec'] as num?)?.toInt() ?? 60);
  }

  Future<String> finishCall(String purpose, String id, String code, String password) async =>
      (await _request('POST', '/auth/phone/$purpose', body: {'id': id, 'code': code, 'password': password}))['accessToken'] as String;

  /// Вход через Telegram: ссылка на бота и ключ, по которому проверяется подтверждение.
  Future<({String token, String? url, int expiresInSec})> telegramStart() async {
    final r = await _request('POST', '/auth/tglink/start', body: <String, dynamic>{});
    return (token: r['token'] as String, url: r['url'] as String?, expiresInSec: (r['expiresInSec'] as num?)?.toInt() ?? 600);
  }

  /// pending | expired | токен доступа.
  Future<({String status, String? accessToken})> telegramCheck(String token) async {
    final r = await _request('GET', '/auth/tglink/$token');
    return (status: r['status'] as String, accessToken: r['accessToken'] as String?);
  }

  Future<AstatAccount> me(String token) async => AstatAccount.fromMe(((await _request('GET', '/me', token: token)) as Map).cast<String, dynamic>());

  Future<bool> phoneAuthEnabled() async {
    try {
      return (await _request('GET', '/config'))['phoneAuthEnabled'] == true;
    } catch (_) {
      return true;
    }
  }
}
