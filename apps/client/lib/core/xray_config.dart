import 'dart:convert';

import 'models.dart';
import 'routing_profile.dart';

/// Сборка конфигурации Xray.
///
/// Что здесь сделано иначе, чем в Happ, v2rayNG и похожих клиентах:
///  - нет локального SOCKS/HTTP-прокси: любой другой программе на устройстве нечего сканировать на localhost,
///    узнать через него выходной адрес или обойти раздельное туннелирование нельзя;
///  - нет API ядра, статистики и метрик на локальных портах (через них утекали ключи и адреса серверов);
///  - весь трафик приходит из системного VPN прямо во вход `tun`;
///  - DNS-запросы приложений перехватываются и уходят через туннель, а не к провайдеру.
enum TunPlatform { android, ios, windows, macos, linux }

const tunTag = 'tun';
const _dnsTag = 'dns-internal';
const _directDns = '77.88.8.8';

/// Каналы, которые никуда не подключаются: мерить по ним задержку сервера нельзя.
const _localProtocols = {'freedom', 'blackhole', 'dns', 'loopback'};

const _ruDomains = [
  'domain:ru',
  'domain:su',
  'domain:xn--p1ai',
  'domain:xn--p1acf',
  'domain:xn--80adxhks',
  'domain:vk.com',
  'domain:vk.me',
  'domain:userapi.com',
  'domain:vkuser.net',
  'domain:yandex.net',
  'domain:yandex.com',
  'domain:yastatic.net',
  'domain:ya.cc',
  'domain:mycdn.me',
  'domain:okcdn.ru',
  'domain:ozone.ru',
  'domain:wbbasket.ru',
  'domain:wbstatic.net',
  'domain:avito.st',
  'domain:sberbank.com',
  'domain:tbank-online.com',
  'domain:tinkoff.com',
  'domain:gosuslugi.com',
  'domain:max.ru',
  'domain:t2.ru',
];

Map<String, dynamic> _tunInbound(TunPlatform platform) {
  final settings = <String, dynamic>{'mtu': 1500};
  switch (platform) {
    case TunPlatform.android:
    case TunPlatform.ios:
      // Интерфейс создаёт система (на iOS — расширение системного VPN), ядро получает готовый
      // дескриптор. Имя обязательно: без него ядро перебирает сетевые интерфейсы, а Android это
      // запрещает, и подключение не запускается.
      settings['name'] = 'tun0';
    case TunPlatform.windows:
      settings.addAll({
        'name': 'AstatVPN',
        'desc': 'AstatVPN',
        'gateway': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'dns': ['172.19.0.2'],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
        // без этого Windows спрашивает DNS у провайдера в обход туннеля
        'autoSystemWfpBlockLeak': ['dns', 'misconfigtun'],
      });
    case TunPlatform.macos:
      // Туннель поднимает служба: ядро само создаёт интерфейс utun и маршруты, имя интерфейса задаёт служба.
      // Системный DNS на время подключения направляет в туннель тоже служба (на адрес шлюза).
      settings.addAll({
        'gateway': ['172.19.0.1/30'],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
      });
    case TunPlatform.linux:
      settings.addAll({
        'name': 'astat0',
        'gateway': ['172.19.0.1/30', 'fdfe:dcba:9876::1/126'],
        'autoSystemRoutingTable': ['0.0.0.0/0', '::/0'],
        'autoOutboundsInterface': 'auto',
        'autoSystemDnsToGateway': true,
      });
  }
  return {
    'tag': tunTag,
    'protocol': 'tun',
    'settings': settings,
    // домен нужен только для правил; адрес назначения остаётся тем, что выбрало приложение
    'sniffing': {
      'enabled': true,
      'destOverride': ['http', 'tls', 'quic'],
      'routeOnly': true,
    },
  };
}

Map<String, dynamic> _clone(Map<String, dynamic> m) => (jsonDecode(jsonEncode(m)) as Map).cast<String, dynamic>();

/// Готовая конфигурация для запуска ядра.
Map<String, dynamic> buildXrayConfig(ServerEntry server, AppSettings settings, TunPlatform platform) {
  final config = server.full != null ? _fromFull(_clone(server.full!)) : _fromOutbound(_clone(server.outbound!), settings);
  final profile = settings.routingProfile;
  if (profile != null) _applyRoutingProfile(config, profile);
  config['inbounds'] = [_tunInbound(platform)];
  config['log'] = {'loglevel': settings.verboseLog ? 'info' : 'warning'};
  return config;
}

/// То же, но для замера задержки: без входов, только исходящие каналы.
Map<String, dynamic> buildProbeConfig(ServerEntry server) {
  final config = server.full != null ? _fromFull(_clone(server.full!)) : _fromOutbound(_clone(server.outbound!), AppSettings(ruDirect: false));
  config['inbounds'] = <dynamic>[];
  config['log'] = {'loglevel': 'none'};
  // замер идёт вне VPN: правила и DNS под туннель здесь только мешают
  config.remove('dns');
  config.remove('observatory');
  config.remove('burstObservatory');
  final outbounds = (config['outbounds'] as List).cast<Map>();
  // без тега proxy берём первый канал, который действительно ведёт к серверу, а не прямой или служебный
  final first = outbounds.firstWhere(
    (o) => o['tag'] == 'proxy',
    orElse: () => outbounds.firstWhere((o) => !_localProtocols.contains(o['protocol']), orElse: () => outbounds.first),
  );
  config['outbounds'] = [first];
  config['routing'] = {'rules': <dynamic>[]};
  return config;
}

Map<String, dynamic> _fromOutbound(Map<String, dynamic> proxy, AppSettings settings) {
  proxy['tag'] = 'proxy';
  final ru = settings.ruDirect && settings.routingProfile == null;
  return {
    'dns': {
      'tag': _dnsTag,
      'queryStrategy': 'UseIPv4',
      'servers': [
        if (ru) {'address': _directDns, 'domains': _ruDomains, 'skipFallback': true},
        '1.1.1.1',
        '8.8.8.8',
      ],
    },
    'outbounds': [
      proxy,
      {'tag': 'direct', 'protocol': 'freedom'},
      {'tag': 'block', 'protocol': 'blackhole'},
      {'tag': 'dns-out', 'protocol': 'dns'},
    ],
    'routing': {
      'domainStrategy': 'IPIfNonMatch',
      'rules': [
        {
          'type': 'field',
          'inboundTag': [tunTag],
          'port': 53,
          'outboundTag': 'dns-out',
        },
        if (ru)
          {
            'type': 'field',
            'inboundTag': [_dnsTag],
            'ip': [_directDns],
            'outboundTag': 'direct',
          },
        {
          'type': 'field',
          'ip': ['geoip:private'],
          'outboundTag': 'direct',
        },
        if (ru) ...[
          {'type': 'field', 'domain': _ruDomains, 'outboundTag': 'direct'},
          {
            'type': 'field',
            'ip': ['geoip:ru'],
            'outboundTag': 'direct',
          },
        ],
      ],
    },
  };
}

/// Конфигурация из подписки рассчитана на клиент с локальным прокси. Переносим её на вход `tun` и убираем всё,
/// что открывает локальные порты.
Map<String, dynamic> _fromFull(Map<String, dynamic> config) {
  // Ответ подписки может быть любым: поля не того вида считаем отсутствующими.
  // Служебные каналы ядра (API, метрики) убираются вместе со своими входами и правилами.
  final serviceOut = <String>{'api', 'Metrics'};
  for (final key in ['api', 'metrics']) {
    final section = config[key];
    if (section is Map && section['tag'] is String) serviceOut.add(section['tag'] as String);
  }
  final removedTags = <String>{};
  final inbounds = config['inbounds'];
  for (final inbound in inbounds is List ? inbounds : const []) {
    if (inbound is Map && inbound['tag'] is String) removedTags.add(inbound['tag'] as String);
  }
  for (final key in ['inbounds', 'api', 'stats', 'metrics', 'reverse', 'remarks', 'meta', 'env']) {
    config.remove(key);
  }

  final rawOutbounds = config['outbounds'];
  final outbounds = (rawOutbounds is List ? rawOutbounds : const []).whereType<Map>().map((o) => o.cast<String, dynamic>()).toList();
  var dnsOut = outbounds.where((o) => o['protocol'] == 'dns').map((o) => o['tag']).whereType<String>().firstOrNull;
  if (dnsOut == null) {
    dnsOut = 'dns-out';
    outbounds.add({'tag': dnsOut, 'protocol': 'dns'});
  }
  // прямой канал: по возможности с привычным тегом, иначе первый, на который можно сослаться
  final freedoms = outbounds.where((o) => o['protocol'] == 'freedom' && o['tag'] is String).toList();
  var directTag = (freedoms.where((o) => o['tag'] == 'direct').firstOrNull ?? freedoms.firstOrNull)?['tag'] as String?;
  if (directTag == null) {
    directTag = 'direct';
    outbounds.add({'tag': directTag, 'protocol': 'freedom'});
  }
  config['outbounds'] = outbounds;

  // Без своих серверов имён ядро спрашивает системный резолвер, а он смотрит в туннель: запрос ходит по кругу.
  final rawDns = config['dns'];
  final dns = rawDns is Map ? rawDns.cast<String, dynamic>() : <String, dynamic>{};
  final rawServers = dns['servers'];
  final servers = rawServers is List ? rawServers.toList() : <dynamic>[];
  var usesDirectDns = false;
  for (var i = 0; i < servers.length; i++) {
    final s = servers[i];
    if (s == 'localhost') {
      servers[i] = _directDns;
      usesDirectDns = true;
    } else if (s is Map && s['address'] == 'localhost') {
      servers[i] = {...s, 'address': _directDns};
      usesDirectDns = true;
    }
  }
  if (servers.isEmpty) servers.addAll(['1.1.1.1', '8.8.8.8']);
  dns['servers'] = servers;
  final dnsTag = dns['tag'];
  if (dnsTag is! String || dnsTag.isEmpty) dns['tag'] = _dnsTag;
  config['dns'] = dns;

  final rawRouting = config['routing'];
  final routing = rawRouting is Map ? rawRouting.cast<String, dynamic>() : <String, dynamic>{};
  final rawRules = routing['rules'];
  final source = (rawRules is List ? rawRules : const []).whereType<Map>().map((r) => r.cast<String, dynamic>()).toList();
  // Входы, которые вели только к служебным каналам: трафика приложений в них не было, на tun их переносить нельзя.
  // Иначе правило «вход метрик → канал метрик» превратилось бы в «весь трафик из tun».
  final serviceIn = <String>{'api'};
  for (final rule in source) {
    if (serviceOut.contains(rule['outboundTag'])) serviceIn.addAll(_tags(rule['inboundTag']) ?? const []);
  }
  final rules = <Map<String, dynamic>>[];
  for (final rule in source) {
    if (serviceOut.contains(rule['outboundTag'])) continue;
    if (rule['inboundTag'] != null) {
      final tags = _tags(rule['inboundTag']);
      if (tags == null) continue;
      final mapped = <String>{
        for (final t in tags)
          if (!serviceIn.contains(t)) removedTags.contains(t) ? tunTag : t,
      };
      if (mapped.isEmpty) continue;
      rule['inboundTag'] = mapped.toList();
    }
    rules.add(rule);
  }
  routing['rules'] = [
    {
      'type': 'field',
      'inboundTag': [tunTag],
      'port': 53,
      'outboundTag': dnsOut,
    },
    if (usesDirectDns)
      {
        'type': 'field',
        'inboundTag': [dns['tag']],
        'ip': [_directDns],
        'outboundTag': directTag,
      },
    ...rules,
  ];
  config['routing'] = routing;
  return config;
}

void _applyRoutingProfile(Map<String, dynamic> config, RoutingProfile profile) {
  final routing = config['routing'] as Map<String, dynamic>;
  final rules = (routing['rules'] as List).cast<Map<String, dynamic>>();
  final outbounds = (config['outbounds'] as List).cast<Map<String, dynamic>>();

  String ensureTag(String protocol) {
    final existing = outbounds.where((o) => o['protocol'] == protocol && o['tag'] is String && o['tag'] != '').firstOrNull;
    if (existing != null) return existing['tag'] as String;
    final tag = _unusedOutboundTag(outbounds, protocol);
    outbounds.add({'protocol': protocol, 'tag': tag});
    return tag;
  }

  final direct = <String, String>{'outboundTag': ensureTag('freedom')};
  final proxy = _profileProxyRoute(routing, rules, outbounds);
  final targets = {
    RouteAction.direct: direct,
    RouteAction.block: {'outboundTag': ensureTag('blackhole')},
    RouteAction.proxy: proxy,
  };
  Map<String, dynamic> rule(Map<String, dynamic> match, Map<String, String> target) => {
        'type': 'field',
        'inboundTag': [tunTag],
        ...match,
        ...target,
      };

  routing['domainStrategy'] = profile.strategy;
  routing['rules'] = [
    rules.first, // Перехват DNS на входе TUN.
    for (final action in profile.order)
      if (profile.groups[action] case final group?) ...[
        if (group.domains.isNotEmpty)
          rule({
            'domain': [for (final domain in group.domains) _bundledGeosite(domain)],
          }, targets[action]!),
        if (group.ips.isNotEmpty) rule({'ip': group.ips}, targets[action]!),
      ],
    rule({'network': 'tcp,udp'}, profile.globalProxy ? proxy : direct),
    ...rules.skip(1), // Служебный DNS и остальные внутренние правила подписки.
  ];
}

String _bundledGeosite(String domain) {
  // Профили на базе Loyalsoldier используют RU; в базе v2fly та же категория имеет другое имя.
  if (domain.toLowerCase() == 'geosite:ru') return 'geosite:category-ru';
  return domain;
}

Map<String, String> _profileProxyRoute(
  Map<String, dynamic> routing,
  List<Map<String, dynamic>> rules,
  List<Map<String, dynamic>> outbounds,
) {
  // Для «Авто» сохраняем балансировщик из общего правила подписки.
  final balancers = routing['balancers'];
  final tags = balancers is List ? balancers.whereType<Map>().map((b) => b['tag']).whereType<String>().toSet() : <String>{};
  for (final rule in rules) {
    final tag = rule['balancerTag'];
    if (tag is String &&
        tags.contains(tag) &&
        rule.keys.every({'type', 'inboundTag', 'network', 'balancerTag'}.contains) &&
        (rule['inboundTag'] == null || (_tags(rule['inboundTag'])?.contains(tunTag) ?? false))) {
      return {'balancerTag': tag};
    }
  }
  final proxies = outbounds.where((o) => !_localProtocols.contains(o['protocol']));
  final proxy = proxies.where((o) => o['tag'] == 'proxy').firstOrNull ?? proxies.firstOrNull;
  if (proxy == null) throw const FormatException('У сервера нет VPN-канала для правил маршрутизации');
  if (proxy['tag'] is! String || proxy['tag'] == '') proxy['tag'] = _unusedOutboundTag(outbounds, 'proxy');
  return {'outboundTag': proxy['tag'] as String};
}

String _unusedOutboundTag(List<Map<String, dynamic>> outbounds, String suffix) {
  final used = outbounds.map((outbound) => outbound['tag']).toSet();
  var tag = 'astat-routing-$suffix';
  for (var i = 2; used.contains(tag); i++) {
    tag = 'astat-routing-$suffix-$i';
  }
  return tag;
}

/// Список тегов в правиле Xray: массив или строка через запятую.
List<String>? _tags(Object? value) {
  if (value is List) return value.map((e) => e.toString()).toList();
  if (value is String) return value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  return null;
}
