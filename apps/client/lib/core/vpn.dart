import 'dart:async';

import 'package:flutter/services.dart';

import 'models.dart';

enum VpnState { disconnected, connecting, connected, stopping }

class VpnStatus {
  const VpnStatus({this.state = VpnState.disconnected, this.since, this.error, this.rx = 0, this.tx = 0, this.serverName});
  final VpnState state;
  final DateTime? since;

  /// Причина последнего сбоя, если подключение не удалось или оборвалось.
  final String? error;
  final int rx;
  final int tx;
  final String? serverName;

  static VpnStatus fromMap(Map<dynamic, dynamic> m) => VpnStatus(
        state: VpnState.values.firstWhere((s) => s.name == m['state'], orElse: () => VpnState.disconnected),
        since: m['since'] is num && (m['since'] as num) > 0 ? DateTime.fromMillisecondsSinceEpoch((m['since'] as num).toInt()) : null,
        error: m['error'] as String?,
        rx: (m['rx'] as num?)?.toInt() ?? 0,
        tx: (m['tx'] as num?)?.toInt() ?? 0,
        serverName: m['name'] as String?,
      );
}

class VpnException implements Exception {
  VpnException(this.message);
  final String message;
  @override
  String toString() => message;
}

class InstalledApp {
  InstalledApp(this.package, this.label, this.system);
  final String package;
  final String label;
  final bool system;
}

/// Связь с системной VPN-службой. Вся работа с ядром Xray идёт на стороне платформы.
class Vpn {
  static const _channel = MethodChannel('astat/vpn');
  static const _events = EventChannel('astat/vpn/events');

  Stream<VpnStatus>? _stream;
  Stream<VpnStatus> get statusStream =>
      _stream ??= _events.receiveBroadcastStream().map((e) => VpnStatus.fromMap(e as Map)).handleError((_) {}).asBroadcastStream();

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      throw VpnException('На этой платформе подключение пока не поддерживается');
    } on PlatformException catch (e) {
      throw VpnException(e.message ?? 'Не удалось выполнить действие');
    }
  }

  Future<VpnStatus> status() async {
    try {
      final m = await _channel.invokeMethod<Map>('status');
      return m == null ? const VpnStatus() : VpnStatus.fromMap(m);
    } catch (_) {
      return const VpnStatus();
    }
  }

  /// Запрашивает у системы разрешение на VPN. false — человек отказал.
  Future<bool> prepare() async => (await _call<bool>('prepare')) ?? false;

  Future<void> start({required String config, required String name, required AppFilterMode filter, required List<String> apps}) =>
      _call<void>('start', {'config': config, 'name': name, 'filter': filter.name, 'apps': apps});

  Future<void> stop() => _call<void>('stop');

  /// Задержка через каждый сервер в мс (-1 — не отвечает). Работает только при выключенном VPN.
  Future<List<int>> ping(List<String> configs) async {
    final r = await _call<List>('ping', {'configs': configs});
    return (r ?? []).map((e) => (e as num).toInt()).toList();
  }

  Future<List<InstalledApp>> apps() async {
    final r = await _call<List>('apps');
    return (r ?? []).map((e) => InstalledApp((e as Map)['package'] as String, e['label'] as String, e['system'] == true)).toList();
  }

  /// Открывает системные настройки VPN (там включается постоянный VPN и запрет интернета без него).
  Future<bool> openVpnSettings() async {
    try {
      return (await _channel.invokeMethod<bool>('openVpnSettings')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, String>> deviceInfo() async {
    try {
      final m = await _channel.invokeMethod<Map>('deviceInfo');
      return {for (final e in (m ?? {}).entries) e.key.toString(): e.value.toString()};
    } catch (_) {
      return {};
    }
  }

  Future<String> coreVersion() async {
    try {
      return (await _channel.invokeMethod<String>('coreVersion')) ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<String> logs() async {
    try {
      return (await _channel.invokeMethod<String>('logs')) ?? '';
    } catch (_) {
      return '';
    }
  }
}
