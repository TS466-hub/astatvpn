import 'dart:convert';

import 'models.dart';
import 'share_link.dart';

class SubscriptionException implements Exception {
  SubscriptionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Разобранный ответ сервера подписки.
class SubscriptionData {
  SubscriptionData({required this.servers, this.skipped = 0, this.title, this.usedBytes, this.totalBytes, this.expireAt, this.updateHours, this.supportUrl, this.announce});
  final List<ServerEntry> servers;

  /// Сколько строк не удалось превратить в сервер.
  final int skipped;
  final String? title;
  final int? usedBytes;
  final int? totalBytes;
  final DateTime? expireAt;
  final int? updateHours;
  final String? supportUrl;
  final String? announce;
}

const _proxyProtocols = {'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'socks', 'wireguard', 'http'};

/// Заголовки подписки бывают в виде `base64:...`. В адресах проценты не раскодируются: это часть самого адреса.
String? _headerText(String? v, {bool percent = true}) {
  if (v == null) return null;
  var s = v.trim();
  if (s.startsWith('base64:')) s = decodeBase64Text(s.substring(7)) ?? '';
  try {
    if (percent && s.contains('%')) s = Uri.decodeComponent(s);
  } catch (_) {}
  s = s.trim();
  return s.isEmpty ? null : s;
}

SubscriptionData parseSubscription(String body, [Map<String, String> headers = const {}]) {
  final h = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
  final servers = <ServerEntry>[];
  var skipped = 0;
  final text = body.trim().replaceFirst('﻿', '');
  if (text.isEmpty) throw SubscriptionException('Сервер подписки вернул пустой ответ');

  dynamic json;
  if (text.startsWith('[') || text.startsWith('{')) {
    try {
      json = jsonDecode(text);
    } catch (_) {}
  }

  if (json != null) {
    final list = json is List ? json : [json];
    for (final item in list) {
      final entry = item is Map ? _fromFullConfig(item.cast<String, dynamic>()) : null;
      if (entry == null) {
        skipped++;
      } else {
        servers.add(entry);
      }
    }
  } else {
    if (text.startsWith('<')) throw SubscriptionException('По ссылке открывается страница, а не подписка. Проверьте ссылку.');
    var lines = const LineSplitter().convert(text);
    if (!lines.any(isShareLink)) {
      final decoded = decodeBase64Text(text);
      if (decoded != null) lines = const LineSplitter().convert(decoded);
    }
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) continue;
      if (!isShareLink(line)) {
        skipped++;
        continue;
      }
      try {
        final p = parseShareLink(line);
        servers.add(ServerEntry(
          id: stableId('${p.protocol}|${p.address}|${p.port}|${p.name}'),
          name: p.name,
          protocol: p.protocol,
          address: p.address,
          port: p.port,
          outbound: p.outbound,
        ));
      } on ShareLinkException {
        skipped++;
      }
    }
  }

  if (servers.isEmpty) {
    throw SubscriptionException(skipped > 0 ? 'В подписке нет серверов, которые поддерживает приложение' : 'В подписке нет серверов');
  }
  // одинаковые идентификаторы ломают выбор сервера: различаем повторы по номеру
  final seen = <String, int>{};
  for (var i = 0; i < servers.length; i++) {
    final s = servers[i];
    final n = seen.update(s.id, (v) => v + 1, ifAbsent: () => 0);
    if (n > 0) {
      servers[i] = ServerEntry(id: '${s.id}-$n', name: s.name, protocol: s.protocol, address: s.address, port: s.port, outbound: s.outbound, full: s.full, auto: s.auto);
    }
  }

  int? used, total;
  DateTime? expire;
  final info = h['subscription-userinfo'];
  if (info != null) {
    final m = {
      for (final part in info.split(';'))
        if (part.contains('=')) part.split('=')[0].trim().toLowerCase(): int.tryParse(part.split('=')[1].trim()),
    };
    if (m['upload'] != null || m['download'] != null) used = (m['upload'] ?? 0) + (m['download'] ?? 0);
    if (used != null && used < 0) used = null;
    total = m['total'];
    if (total != null && total < 0) total = null;
    final e = m['expire'];
    // больше DateTime не вмещает: такой срок считаем не заданным
    if (e != null && e > 0 && e <= 8640000000000) expire = DateTime.fromMillisecondsSinceEpoch(e * 1000);
  }
  final interval = int.tryParse((h['profile-update-interval'] ?? '').trim());

  return SubscriptionData(
    servers: servers,
    skipped: skipped,
    title: _headerText(h['profile-title']),
    usedBytes: used,
    totalBytes: total,
    expireAt: expire,
    updateHours: interval != null && interval > 0 ? interval : null,
    supportUrl: _headerText(h['support-url'], percent: false),
    announce: _headerText(h['announce']),
  );
}

ServerEntry? _fromFullConfig(Map<String, dynamic> config) {
  // ответ сервера может быть любым: поля не того вида считаем отсутствующими
  final rawOutbounds = config['outbounds'];
  final outbounds = rawOutbounds is List ? rawOutbounds.whereType<Map>().toList() : const <Map>[];
  final proxies = outbounds.where((o) => _proxyProtocols.contains(o['protocol'])).toList();
  if (proxies.isEmpty) return null;
  final main = proxies.firstWhere((o) => o['tag'] == 'proxy', orElse: () => proxies.first);
  final (address, port) = outboundEndpoint(main.cast<String, dynamic>());
  final routing = config['routing'];
  final balancers = routing is Map ? routing['balancers'] : null;
  final auto = balancers is List && balancers.isNotEmpty && proxies.length > 1;
  var protocol = (main['protocol'] ?? '').toString();
  if (protocol == 'hysteria') protocol = 'hysteria2';
  final remarks = config['remarks'];
  final name = remarks is String ? remarks.trim() : '';
  return ServerEntry(
    id: stableId('full|${auto ? 'auto' : '$protocol|$address|$port'}|$name'),
    name: name.isEmpty ? (address.isEmpty ? 'Сервер' : address) : name,
    protocol: auto ? 'auto' : protocol,
    address: auto ? '' : address,
    port: auto ? 0 : port,
    full: config,
    auto: auto,
  );
}

/// Адрес и порт сервера из исходящего канала Xray (плоский вид, `vnext` и `servers`).
(String, int) outboundEndpoint(Map<String, dynamic> outbound) {
  final settings = outbound['settings'];
  final Map s = settings is Map ? settings : const {};
  Map? node;
  for (final key in ['vnext', 'servers']) {
    final l = s[key];
    if (l is List && l.isNotEmpty && l.first is Map) node = l.first as Map;
  }
  node ??= s;
  final address = node['address'];
  final raw = node['port'];
  final port = raw is int ? raw : (raw is double && raw.isFinite ? raw.toInt() : int.tryParse('$raw') ?? 0);
  return (address is String ? address : '', port > 0 && port <= 65535 ? port : 0);
}
