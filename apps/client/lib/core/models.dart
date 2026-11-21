import 'dart:convert';

/// Один сервер из подписки. Либо отдельный исходящий канал (из ссылки), либо готовая конфигурация Xray (из JSON-подписки).
class ServerEntry {
  ServerEntry({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    this.outbound,
    this.full,
    this.delayMs,
    this.auto = false,
  });

  final String id;
  final String name;
  final String protocol;
  final String address;
  final int port;
  final Map<String, dynamic>? outbound;
  final Map<String, dynamic>? full;

  /// Конфигурация с балансировщиком: сервер выбирается сам.
  final bool auto;

  /// Задержка в мс; -1 — не отвечает; null — не проверялся.
  int? delayMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol,
        'address': address,
        'port': port,
        if (outbound != null) 'outbound': outbound,
        if (full != null) 'full': full,
        if (delayMs != null) 'delayMs': delayMs,
        if (auto) 'auto': true,
      };

  static ServerEntry fromJson(Map<String, dynamic> j) => ServerEntry(
        id: j['id'] as String,
        name: j['name'] as String,
        protocol: j['protocol'] as String,
        address: j['address'] as String,
        port: (j['port'] as num).toInt(),
        outbound: (j['outbound'] as Map?)?.cast<String, dynamic>(),
        full: (j['full'] as Map?)?.cast<String, dynamic>(),
        delayMs: (j['delayMs'] as num?)?.toInt(),
        auto: j['auto'] == true,
      );
}

enum ProfileKind { astat, url, local }

/// Подписка: ссылка и полученный по ней список серверов.
class Profile {
  Profile({
    required this.id,
    required this.name,
    required this.kind,
    this.url,
    List<ServerEntry>? servers,
    this.updatedAt,
    this.usedBytes,
    this.totalBytes,
    this.expireAt,
    this.updateHours = 12,
    this.supportUrl,
    this.announce,
    this.lastError,
    this.collapsed = false,
    this.lastServerId,
  }) : servers = servers ?? [];

  final String id;
  String name;
  final ProfileKind kind;
  String? url;
  List<ServerEntry> servers;
  DateTime? updatedAt;
  int? usedBytes;

  /// 0 — безлимит.
  int? totalBytes;
  DateTime? expireAt;
  int updateHours;
  String? supportUrl;
  String? announce;
  String? lastError;

  /// Список серверов свёрнут на вкладке «Серверы».
  bool collapsed;
  String? lastServerId;

  bool get needsUpdate => url != null && (updatedAt == null || DateTime.now().difference(updatedAt!).inMinutes >= updateHours * 60);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        if (url != null) 'url': url,
        'servers': servers.map((s) => s.toJson()).toList(),
        // время хранится в UTC: смена часового пояса на устройстве не сдвигает срок подписки
        if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
        if (usedBytes != null) 'usedBytes': usedBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        if (expireAt != null) 'expireAt': expireAt!.toUtc().toIso8601String(),
        'updateHours': updateHours,
        if (supportUrl != null) 'supportUrl': supportUrl,
        if (announce != null) 'announce': announce,
        if (lastError != null) 'lastError': lastError,
        if (collapsed) 'collapsed': true,
        if (lastServerId != null) 'lastServerId': lastServerId,
      };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        name: j['name'] as String,
        kind: ProfileKind.values.firstWhere((k) => k.name == j['kind'], orElse: () => ProfileKind.url),
        url: j['url'] as String?,
        servers: ((j['servers'] as List?) ?? []).map((e) => ServerEntry.fromJson((e as Map).cast<String, dynamic>())).toList(),
        updatedAt: _time(j['updatedAt']),
        usedBytes: (j['usedBytes'] as num?)?.toInt(),
        totalBytes: (j['totalBytes'] as num?)?.toInt(),
        expireAt: _time(j['expireAt']),
        updateHours: (j['updateHours'] as num?)?.toInt() ?? 12,
        supportUrl: j['supportUrl'] as String?,
        announce: j['announce'] as String?,
        lastError: j['lastError'] as String?,
        lastServerId: j['lastServerId'] as String?,
        collapsed: j['collapsed'] == true,
      );
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toLocal() : null;

enum AppFilterMode { off, exclude, include }

enum ThemeChoice { system, dark, light }

class AppSettings {
  AppSettings({
    this.ruDirect = true,
    this.appFilter = AppFilterMode.off,
    List<String>? apps,
    this.autoConnect = false,
    this.theme = ThemeChoice.dark,
    this.autoUpdate = true,
    this.verboseLog = false,
  }) : apps = apps ?? [];

  /// Российские сайты и адреса идут мимо VPN. Действует на серверы из ссылок; в готовых конфигурациях правила задаёт подписка.
  bool ruDirect;
  AppFilterMode appFilter;
  List<String> apps;
  bool autoConnect;
  ThemeChoice theme;
  bool autoUpdate;

  /// Подробный журнал ядра: ход каждого соединения с адресами сайтов. Только для разбора сбоя.
  bool verboseLog;

  Map<String, dynamic> toJson() => {
        'ruDirect': ruDirect,
        'appFilter': appFilter.name,
        'apps': apps,
        'autoConnect': autoConnect,
        'theme': theme.name,
        'autoUpdate': autoUpdate,
        'verboseLog': verboseLog,
      };

  static AppSettings fromJson(Map<String, dynamic> j) => AppSettings(
        ruDirect: j['ruDirect'] != false,
        appFilter: AppFilterMode.values.firstWhere((m) => m.name == j['appFilter'], orElse: () => AppFilterMode.off),
        apps: ((j['apps'] as List?) ?? []).map((e) => e.toString()).toList(),
        autoConnect: j['autoConnect'] == true,
        theme: ThemeChoice.values.firstWhere((m) => m.name == j['theme'], orElse: () => ThemeChoice.dark),
        autoUpdate: j['autoUpdate'] != false,
        verboseLog: j['verboseLog'] == true,
      );
}

/// Короткий устойчивый идентификатор: одинаковые серверы после обновления подписки сохраняют выбор и замеры.
String stableId(String text) {
  // начальное значение FNV-1a без старшего бита: иначе для пустой строки выходило отрицательное число со знаком «-»
  var h = 0xcbf29ce484222325 & 0x7fffffffffffffff;
  for (final b in utf8.encode(text)) {
    h ^= b;
    h = (h * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return h.toRadixString(36);
}
