import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Всё, что приложение хранит между запусками.
class StoredState {
  StoredState({List<Profile>? profiles, AppSettings? settings, this.profileId, this.serverId, String? deviceId})
      : profiles = profiles ?? [],
        settings = settings ?? AppSettings(),
        deviceId = deviceId ?? _randomId();

  List<Profile> profiles;
  AppSettings settings;
  String? profileId;
  String? serverId;

  /// Случайный идентификатор установки для учёта устройств в подписке. Не связан с железом и сбрасывается при переустановке.
  final String deviceId;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'settings': settings.toJson(),
        if (profileId != null) 'profileId': profileId,
        if (serverId != null) 'serverId': serverId,
        'deviceId': deviceId,
      };

  static StoredState fromJson(Map<String, dynamic> j) => StoredState(
        profiles: ((j['profiles'] as List?) ?? []).map((e) => Profile.fromJson((e as Map).cast<String, dynamic>())).toList(),
        settings: AppSettings.fromJson(((j['settings'] as Map?) ?? {}).cast<String, dynamic>()),
        profileId: j['profileId'] as String?,
        serverId: j['serverId'] as String?,
        deviceId: j['deviceId'] as String?,
      );
}

String _randomId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

class Storage {
  static const _tokenKey = 'astat_token';
  // На macOS приложение раздаётся без подписи Apple: защищённая связка ключей таким приложениям недоступна,
  // поэтому токен хранится в обычной связке ключей пользователя.
  final _secure = const FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  File? _file;

  Future<File> _stateFile() async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return _file = File('${dir.path}/state.json');
  }

  Future<StoredState> load() async {
    try {
      final f = await _stateFile();
      if (!await f.exists()) return StoredState();
      return StoredState.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
    } catch (_) {
      // повреждённый файл не должен мешать запуску
      return StoredState();
    }
  }

  Future<void> _pending = Future.value();

  /// Запись через временный файл: обрыв питания не оставит половину файла. Записи идут строго по очереди.
  Future<void> save(StoredState state) {
    final text = jsonEncode(state.toJson());
    return _pending = _pending.then((_) async {
      try {
        final f = await _stateFile();
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        await tmp.rename(f.path);
      } catch (_) {}
    });
  }

  Future<String?> readToken() async {
    try {
      return await _secure.read(key: _tokenKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> writeToken(String? token) async {
    try {
      if (token == null) {
        await _secure.delete(key: _tokenKey);
      } else {
        await _secure.write(key: _tokenKey, value: token);
      }
    } catch (_) {}
  }
}
