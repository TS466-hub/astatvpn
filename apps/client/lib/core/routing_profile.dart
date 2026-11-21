import 'dart:convert';
import 'dart:io';

import 'share_link.dart';

enum RouteAction {
  block('Блокировать', 'Block'),
  direct('Напрямую', 'Direct'),
  proxy('Через VPN', 'Proxy');

  const RouteAction(this.label, this.field);
  final String label;
  final String field;
}

class RouteGroup {
  const RouteGroup({this.domains = const [], this.ips = const []});
  final List<String> domains;
  final List<String> ips;
  int get count => domains.length + ips.length;
}

class RoutingProfile {
  const RoutingProfile({
    required this.name,
    this.groups = const {},
    this.order = RouteAction.values,
    this.globalProxy = true,
    this.strategy = 'AsIs',
  });

  final String name;
  final Map<RouteAction, RouteGroup> groups;
  final List<RouteAction> order;
  final bool globalProxy;
  final String strategy;
  int get count => groups.values.fold(0, (total, group) => total + group.count);

  Map<String, dynamic> toJson() => {
    'Name': name,
    'GlobalProxy': globalProxy,
    'RouteOrder': order.map((a) => a.name).join('-'),
    'DomainStrategy': strategy,
    for (final entry in groups.entries) ...{
      '${entry.key.field}Sites': entry.value.domains,
      '${entry.key.field}Ip': entry.value.ips,
    },
  };

  static RoutingProfile fromJson(Map<String, dynamic> json) {
    final name = json['Name'];
    final orderValue = json['RouteOrder'];
    final order = orderValue is String && orderValue.trim().isNotEmpty
        ? orderValue
              .trim()
              .toLowerCase()
              .split(RegExp('[-_]'))
              .map(
                (part) =>
                    RouteAction.values.where((a) => a.name == part).firstOrNull,
              )
              .toList()
        : RouteAction.values;
    if (order.length != 3 ||
        order.contains(null) ||
        order.toSet().length != 3) {
      throw const FormatException('Неизвестный порядок правил (RouteOrder)');
    }
    final defaultRoute = json['GlobalProxy'];
    final strategy = json['DomainStrategy'];
    if (defaultRoute != null &&
        !['true', 'false'].contains(defaultRoute.toString().toLowerCase())) {
      throw const FormatException('Неверное значение GlobalProxy');
    }
    if (strategy != null &&
        strategy != '' &&
        !['AsIs', 'IPIfNonMatch', 'IPOnDemand'].contains(strategy)) {
      throw const FormatException('Неизвестная стратегия DomainStrategy');
    }
    return RoutingProfile(
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'Импортированный профиль',
      groups: {
        for (final action in RouteAction.values)
          action: RouteGroup(
            domains: _readRules(json, '${action.field}Sites', ip: false),
            ips: _readRules(json, '${action.field}Ip', ip: true),
          ),
      },
      order: order.cast<RouteAction>(),
      globalProxy: defaultRoute.toString().toLowerCase() != 'false',
      strategy: strategy == null || strategy == ''
          ? 'AsIs'
          : strategy as String,
    );
  }
}

const routingImportLimit = 2 * 1024 * 1024;

String routingPayload(String input) {
  final text = input.trim().replaceFirst(
    RegExp(r'^routing:\s*', caseSensitive: false),
    '',
  );
  if (text.length > routingImportLimit) {
    throw const FormatException('Профиль слишком большой');
  }
  final link = RegExp(
    r'^(?:happ|incy)://(?:auto)?routing/(?:add|onadd)/(.+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (link != null) return Uri.decodeComponent(link[1]!);
  return text;
}

RoutingProfile parseRoutingProfile(String payload) {
  final text = payload.trim().replaceFirst('\uFEFF', '');
  if (text.length > routingImportLimit) {
    throw const FormatException('Профиль слишком большой');
  }
  final decoded = text.startsWith('{') ? text : decodeBase64Text(text);
  final Object? json;
  try {
    json = decoded == null ? null : jsonDecode(decoded);
  } on FormatException {
    throw const FormatException('Не удалось прочитать JSON профиля');
  }
  if (json is! Map<String, dynamic> ||
      !json.keys.any(
        (key) =>
            key == 'GlobalProxy' ||
            RouteAction.values.any(
              (a) => key == '${a.field}Sites' || key == '${a.field}Ip',
            ),
      )) {
    throw const FormatException('Вставьте профиль маршрутизации Happ или Incy');
  }
  return RoutingProfile.fromJson(json);
}

List<String> _readRules(
  Map<String, dynamic> profile,
  String key, {
  required bool ip,
}) {
  final data = profile[key];
  if (data == null) return const [];
  if (data is! List || data.any((entry) => entry is! String)) {
    throw FormatException('В поле $key ожидается список строк');
  }
  return {
    for (final entry in data.cast<String>())
      if (entry.trim().isNotEmpty) _normalizeRule(entry.trim(), ip: ip),
  }.toList();
}

RouteGroup parseManualRules(String text) {
  final domains = <String>{};
  final ips = <String>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.toLowerCase().startsWith('geoip:') ||
        InternetAddress.tryParse(line.split('/').first) != null) {
      ips.add(_normalizeRule(line, ip: true));
    } else {
      domains.add(_normalizeRule(line, ip: false));
    }
  }
  return RouteGroup(domains: domains.toList(), ips: ips.toList());
}

String _normalizeRule(String rule, {required bool ip}) {
  if (rule.length > 2048) {
    throw const FormatException('Слишком длинное правило');
  }
  final prefix = ip ? 'geoip:' : 'geosite:';
  if (rule.toLowerCase().startsWith(prefix) &&
      RegExp(r'^[\w@.!-]+$').hasMatch(rule.substring(prefix.length))) {
    return '$prefix${rule.substring(prefix.length)}';
  }
  if (ip) {
    final parts = rule.split('/');
    final address = InternetAddress.tryParse(parts.first);
    final length = parts.length == 2 ? int.tryParse(parts.last) : null;
    if (address != null &&
        (parts.length == 1 ||
            (length != null &&
                length >= 0 &&
                length <=
                    (address.type == InternetAddressType.IPv4 ? 32 : 128)))) {
      return rule;
    }
    throw FormatException('Неверный IP-адрес или подсеть: $rule');
  }
  if (rule.startsWith('regexp:') && rule.length > 7) return rule;
  final separator = rule.indexOf(':');
  final kind = separator < 0
      ? 'domain'
      : rule.substring(0, separator).toLowerCase();
  final value = separator < 0 ? rule : rule.substring(separator + 1);
  if (['domain', 'full', 'keyword', 'plain'].contains(kind) &&
      RegExp(r'^[^\s:/\\?#*]+$').hasMatch(value) &&
      value.split('.').every((part) => part.isNotEmpty)) {
    return '${kind == 'keyword' ? 'plain' : kind}:$value';
  }
  throw FormatException('Неверный домен или категория: $rule');
}
