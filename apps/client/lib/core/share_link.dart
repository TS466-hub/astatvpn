import 'dart:convert';

/// Ссылку нельзя превратить в рабочее подключение. Текст показывается человеку.
class ShareLinkException implements Exception {
  ShareLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Сервер, разобранный из ссылки: один исходящий канал Xray с тегом `proxy`.
class ParsedLink {
  ParsedLink({required this.name, required this.protocol, required this.address, required this.port, required this.outbound});
  final String name;
  final String protocol;
  final String address;
  final int port;
  final Map<String, dynamic> outbound;
}

const shareSchemes = ['vless://', 'vmess://', 'trojan://', 'ss://', 'hysteria2://', 'hy2://', 'socks://'];

bool isShareLink(String line) {
  final t = line.trimLeft();
  return shareSchemes.any(t.startsWith);
}

/// Base64 в обычном и URL-алфавите, с выравниванием и без. Возвращает null, если это не base64-текст.
String? decodeBase64Text(String text) {
  var s = text.trim().replaceAll(RegExp(r'\s+'), '');
  if (s.isEmpty || !RegExp(r'^[A-Za-z0-9+/_=-]+$').hasMatch(s)) return null;
  s = s.replaceAll('-', '+').replaceAll('_', '/').replaceAll('=', '');
  if (s.isEmpty || s.length % 4 == 1) return null;
  s = s.padRight(s.length + (4 - s.length % 4) % 4, '=');
  try {
    return utf8.decode(base64.decode(s), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

ParsedLink parseShareLink(String raw) {
  try {
    return _parse(raw);
  } on ShareLinkException {
    rethrow;
  } catch (_) {
    // какой бы ни была строка, наружу выходит только ShareLinkException
    throw ShareLinkException('Ссылка повреждена');
  }
}

ParsedLink _parse(String raw) {
  final text = raw.trim();
  final scheme = text.contains('://') ? text.substring(0, text.indexOf('://')).toLowerCase() : '';
  switch (scheme) {
    case 'vless':
      return _vless(text);
    case 'vmess':
      return _vmess(text);
    case 'trojan':
      return _trojan(text);
    case 'ss':
      return _shadowsocks(text);
    case 'hysteria2':
    case 'hy2':
      return _hysteria2(text);
    case 'socks':
      return _socks(text);
    default:
      throw ShareLinkException('Неизвестный тип ссылки');
  }
}

// ---------- общие части ----------

Uri _uri(String text) {
  try {
    final u = Uri.parse(text);
    _checkHost(u.host);
    return u;
  } on FormatException {
    throw ShareLinkException('Ссылка повреждена');
  }
}

/// Uri пропускает в адрес пробелы и нелатинские буквы, заменяя их на `%XX`: ядро такой адрес не откроет.
void _checkHost(String host) {
  if (host.isEmpty) throw ShareLinkException('В ссылке нет адреса сервера');
  final ok = host.contains(':') ? RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(host) : RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host);
  if (!ok || host.length > 253) throw ShareLinkException('Адрес сервера в ссылке записан неверно');
}

int _port(Uri u, [int fallback = 443]) {
  final p = u.hasPort ? u.port : fallback;
  if (p <= 0 || p > 65535) throw ShareLinkException('Неверный порт');
  return p;
}

String _decode(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

String _name(Uri u, String fallback) {
  final n = _decode(u.fragment).trim();
  return n.isEmpty ? fallback : n;
}

Map<String, String> _query(Uri u) {
  try {
    return u.queryParameters;
  } catch (_) {
    throw ShareLinkException('Параметры ссылки повреждены');
  }
}

bool _truthy(String? v) => v == '1' || v == 'true';

/// Xray больше не умеет отключать проверку сертификата. Вместо молчаливой небезопасной работы отказываем с объяснением.
void _rejectInsecure(Map<String, String> q, {required bool pinned}) {
  if ((_truthy(q['allowInsecure']) || _truthy(q['insecure'])) && !pinned) {
    throw ShareLinkException('Сервер просит отключить проверку сертификата. Это небезопасно, подключение не создано.');
  }
}

/// Отпечатки сертификата: SHA-256 в шестнадцатеричном виде, можно с двоеточиями, несколько через запятую.
String _pin(String v) {
  final pins = v.split(',').map((e) => e.replaceAll(':', '').replaceAll(' ', '').toLowerCase()).where((e) => e.isNotEmpty).toList();
  for (final p in pins) {
    // ядро с другим значением не запустится
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(p)) throw ShareLinkException('Отпечаток сертификата в ссылке записан неверно');
  }
  return pins.join(',');
}

Map<String, dynamic> _jsonObject(String text, String error) {
  try {
    final parsed = jsonDecode(text);
    if (parsed is Map<String, dynamic>) return parsed;
  } catch (_) {}
  throw ShareLinkException(error);
}

Map<String, dynamic> _stream(Map<String, String> q, {required String scheme, required String host, bool forceTls = false}) {
  var network = (q['type'] ?? 'raw').toLowerCase();
  if (network == 'tcp') network = 'raw';
  if (network == 'websocket') network = 'ws';
  if (network == 'gun') network = 'grpc';
  if (network == 'splithttp') network = 'xhttp';
  if (network == 'mkcp') network = 'kcp';
  final stream = <String, dynamic>{'network': network};

  final path = q['path'] ?? '';
  final hostHeader = q['host'] ?? '';
  switch (network) {
    case 'raw':
      if (q['headerType'] == 'http') {
        stream['rawSettings'] = {
          'header': {
            'type': 'http',
            'request': {
              if (path.isNotEmpty) 'path': path.split(','),
              if (hostHeader.isNotEmpty) 'headers': {'Host': hostHeader.split(',')},
            },
          },
        };
      }
    case 'ws':
      stream['wsSettings'] = {if (path.isNotEmpty) 'path': path, if (hostHeader.isNotEmpty) 'host': hostHeader};
    case 'grpc':
      final mode = q['mode'] ?? '';
      stream['grpcSettings'] = {
        if ((q['authority'] ?? '').isNotEmpty) 'authority': q['authority'],
        'serviceName': q['serviceName'] ?? '',
        if (mode == 'multi') 'multiMode': true,
      };
    case 'httpupgrade':
      stream['httpupgradeSettings'] = {if (path.isNotEmpty) 'path': path, if (hostHeader.isNotEmpty) 'host': hostHeader};
    case 'xhttp':
      final settings = <String, dynamic>{
        if (hostHeader.isNotEmpty) 'host': hostHeader,
        if (path.isNotEmpty) 'path': path,
        if ((q['mode'] ?? '').isNotEmpty) 'mode': q['mode'],
      };
      final extra = q['extra'] ?? '';
      if (extra.isNotEmpty) settings['extra'] = _jsonObject(extra, 'Параметры XHTTP в ссылке повреждены');
      stream['xhttpSettings'] = settings;
    case 'kcp':
      final mtu = int.tryParse(q['mtu'] ?? '');
      final tti = int.tryParse(q['tti'] ?? '');
      if (mtu != null || tti != null) stream['kcpSettings'] = {'mtu': ?mtu, 'tti': ?tti};
    default:
      throw ShareLinkException('Транспорт «$network» не поддерживается');
  }

  final fm = q['fm'] ?? '';
  if (fm.isNotEmpty) stream['finalmask'] = _jsonObject(fm, 'Параметры маскировки в ссылке повреждены');

  var security = (q['security'] ?? '').toLowerCase();
  if (security.isEmpty) security = forceTls ? 'tls' : 'none';
  if (forceTls && security == 'none') security = 'tls';
  stream['security'] = security;

  final fp = q['fp'] ?? '';
  var sni = q['sni'] ?? q['peer'] ?? '';
  if (sni.isEmpty && network == 'ws' && hostHeader.isNotEmpty) sni = hostHeader;
  if (sni.isEmpty && (scheme == 'vless' || scheme == 'vmess')) sni = host;

  if (security == 'tls') {
    final pin = _pin(q['pcs'] ?? q['pinSHA256'] ?? '');
    _rejectInsecure(q, pinned: pin.isNotEmpty);
    final alpn = (q['alpn'] ?? '').split(',').where((e) => e.isNotEmpty).toList();
    stream['tlsSettings'] = {
      if (sni.isNotEmpty) 'serverName': sni,
      if (fp.isNotEmpty) 'fingerprint': fp,
      if (alpn.isNotEmpty) 'alpn': alpn,
      if ((q['ech'] ?? '').isNotEmpty) 'echConfigList': q['ech'],
      if (pin.isNotEmpty) 'pinnedPeerCertSha256': pin,
      if ((q['vcn'] ?? '').isNotEmpty) 'verifyPeerCertByName': q['vcn'],
    };
  } else if (security == 'reality') {
    final pbk = q['pbk'] ?? '';
    if (pbk.isEmpty) throw ShareLinkException('В ссылке Reality нет публичного ключа');
    // то, с чем ядро не запустится, отклоняем сразу: ключ — 32 байта в base64url, shortId — до 8 байт в hex
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(pbk)) throw ShareLinkException('Публичный ключ Reality в ссылке записан неверно');
    if (!RegExp(r'^([0-9a-fA-F]{2}){0,8}$').hasMatch(q['sid'] ?? '')) throw ShareLinkException('Параметр shortId в ссылке Reality записан неверно');
    if (network != 'raw' && network != 'xhttp' && network != 'grpc') throw ShareLinkException('Reality не работает с транспортом «$network»');
    stream['realitySettings'] = {
      if (sni.isNotEmpty) 'serverName': sni,
      'fingerprint': fp.isEmpty ? 'chrome' : fp,
      'password': pbk,
      'publicKey': pbk,
      'shortId': q['sid'] ?? '',
      if ((q['spx'] ?? '').startsWith('/')) 'spiderX': q['spx'],
      if ((q['pqv'] ?? '').isNotEmpty) 'mldsa65Verify': q['pqv'],
    };
  } else if (security != 'none') {
    throw ShareLinkException('Защита «$security» не поддерживается');
  }
  return stream;
}

Map<String, dynamic> _outbound(String protocol, Map<String, dynamic> settings, Map<String, dynamic>? stream) => {
      'tag': 'proxy',
      'protocol': protocol,
      'settings': settings,
      'streamSettings': ?stream,
    };

// ---------- протоколы ----------

ParsedLink _vless(String text) {
  final u = _uri(text);
  final q = _query(u);
  final id = _decode(u.userInfo);
  if (id.isEmpty) throw ShareLinkException('В ссылке нет идентификатора пользователя');
  final port = _port(u);
  final enc = q['encryption'] ?? '';
  final settings = {
    'address': u.host,
    'port': port,
    'id': id,
    'encryption': enc.isEmpty ? 'none' : enc,
    if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
  };
  return ParsedLink(
    name: _name(u, u.host),
    protocol: 'vless',
    address: u.host,
    port: port,
    outbound: _outbound('vless', settings, _stream(q, scheme: 'vless', host: u.host)),
  );
}

ParsedLink _vmess(String text) {
  final body = text.substring('vmess://'.length);
  // старый формат: vmess://base64(JSON)
  final legacy = body.contains('@') ? null : decodeBase64Text(body.split('#').first);
  if (legacy != null) {
    Map<String, dynamic> j;
    try {
      j = jsonDecode(legacy) as Map<String, dynamic>;
    } catch (_) {
      throw ShareLinkException('Ссылка VMess повреждена');
    }
    String s(String k) => (j[k] ?? '').toString();
    final host = s('add');
    final port = int.tryParse(s('port')) ?? 0;
    if (host.isEmpty || port <= 0 || port > 65535 || s('id').isEmpty) throw ShareLinkException('Ссылка VMess неполная');
    _checkHost(host);
    final net = s('net').isEmpty ? 'raw' : s('net');
    final q = <String, String>{
      'type': net,
      if (s('host').isNotEmpty) 'host': s('host'),
      if (s('path').isNotEmpty) (net == 'grpc' ? 'serviceName' : 'path'): s('path'),
      if (s('type').isNotEmpty && s('type') != 'none') 'headerType': s('type'),
      if (s('tls').isNotEmpty && s('tls') != 'none') 'security': s('tls'),
      if (s('sni').isNotEmpty) 'sni': s('sni'),
      if (s('alpn').isNotEmpty) 'alpn': s('alpn'),
      if (s('fp').isNotEmpty) 'fp': s('fp'),
    };
    final settings = {'address': host, 'port': port, 'id': s('id'), 'security': s('scy').isEmpty ? 'auto' : s('scy')};
    return ParsedLink(
      name: s('ps').isEmpty ? host : s('ps'),
      protocol: 'vmess',
      address: host,
      port: port,
      outbound: _outbound('vmess', settings, _stream(q, scheme: 'vmess', host: host)),
    );
  }
  final u = _uri(text);
  final q = _query(u);
  final id = _decode(u.userInfo);
  if (id.isEmpty) throw ShareLinkException('В ссылке нет идентификатора пользователя');
  final port = _port(u);
  final settings = {'address': u.host, 'port': port, 'id': id, 'security': (q['encryption'] ?? '').isEmpty ? 'auto' : q['encryption']};
  return ParsedLink(
    name: _name(u, u.host),
    protocol: 'vmess',
    address: u.host,
    port: port,
    outbound: _outbound('vmess', settings, _stream(q, scheme: 'vmess', host: u.host)),
  );
}

ParsedLink _trojan(String text) {
  final u = _uri(text);
  final q = _query(u);
  final password = _decode(u.userInfo);
  if (password.isEmpty) throw ShareLinkException('В ссылке нет пароля');
  final port = _port(u);
  return ParsedLink(
    name: _name(u, u.host),
    protocol: 'trojan',
    address: u.host,
    port: port,
    outbound: _outbound('trojan', {'address': u.host, 'port': port, 'password': password}, _stream(q, scheme: 'trojan', host: u.host, forceTls: true)),
  );
}

ParsedLink _shadowsocks(String text) {
  var body = text.substring('ss://'.length);
  var fragment = '';
  final hash = body.indexOf('#');
  if (hash >= 0) {
    fragment = body.substring(hash + 1);
    body = body.substring(0, hash);
  }
  final legacy = !body.contains('@');
  if (legacy) {
    // совсем старый формат: ss://base64(method:password@host:port)
    final decoded = decodeBase64Text(body.split('?').first);
    if (decoded == null) throw ShareLinkException('Ссылка Shadowsocks повреждена');
    body = decoded;
  }
  final at = body.lastIndexOf('@');
  if (at <= 0) throw ShareLinkException('Ссылка Shadowsocks повреждена');
  var userInfo = body.substring(0, at);
  final u = _uri('ss://x@${body.substring(at + 1)}');
  if ((_query(u)['plugin'] ?? '').isNotEmpty) throw ShareLinkException('Shadowsocks с плагином не поддерживается');
  if (legacy) {
    // здесь шифр и пароль записаны как есть: проценты в пароле — обычные знаки
  } else if (!userInfo.contains(':')) {
    userInfo = decodeBase64Text(_decode(userInfo)) ?? '';
  } else {
    userInfo = userInfo.split(':').map(_decode).join(':');
  }
  final sep = userInfo.indexOf(':');
  if (sep <= 0) throw ShareLinkException('В ссылке Shadowsocks нет шифра или пароля');
  final port = _port(u, 8388);
  final name = _decode(fragment).trim();
  return ParsedLink(
    name: name.isEmpty ? u.host : name,
    protocol: 'shadowsocks',
    address: u.host,
    port: port,
    outbound: _outbound('shadowsocks', {'address': u.host, 'port': port, 'method': userInfo.substring(0, sep), 'password': userInfo.substring(sep + 1)}, null),
  );
}

ParsedLink _socks(String text) {
  final u = _uri(text);
  final port = _port(u, 1080);
  final settings = <String, dynamic>{'address': u.host, 'port': port};
  if (u.userInfo.isNotEmpty) {
    final raw = _decode(u.userInfo);
    final plain = raw.contains(':') ? raw : (decodeBase64Text(raw) ?? '');
    final sep = plain.indexOf(':');
    if (sep <= 0) throw ShareLinkException('Логин и пароль SOCKS повреждены');
    settings['user'] = plain.substring(0, sep);
    settings['pass'] = plain.substring(sep + 1);
  }
  return ParsedLink(name: _name(u, u.host), protocol: 'socks', address: u.host, port: port, outbound: _outbound('socks', settings, null));
}

/// Диапазоны портов Hysteria2 (`443,5000-6000`): Uri такие адреса не разбирает.
List<List<int>> _hyPorts(String text) {
  final out = <List<int>>[];
  for (final item in text.split(',')) {
    final parts = item.split('-');
    final from = int.tryParse(parts.first);
    final to = int.tryParse(parts.length > 1 ? parts[1] : parts.first);
    if (parts.length > 2 || from == null || to == null || from <= 0 || to > 65535 || from > to) throw ShareLinkException('Неверный порт Hysteria2');
    out.add([from, to]);
  }
  return out;
}

ParsedLink _hysteria2(String text) {
  final schemeEnd = text.indexOf('://') + 3;
  final rest = text.substring(schemeEnd);
  final cut = rest.indexOf(RegExp(r'[/?#]'));
  final authority = cut < 0 ? rest : rest.substring(0, cut);
  final suffix = cut < 0 ? '' : rest.substring(cut);
  final at = authority.lastIndexOf('@');
  final user = at >= 0 ? authority.substring(0, at + 1) : '';
  final hostPort = at >= 0 ? authority.substring(at + 1) : authority;
  var host = hostPort;
  var portText = '443';
  if (hostPort.startsWith('[')) {
    final close = hostPort.indexOf(']');
    if (close < 0) throw ShareLinkException('Ссылка Hysteria2 повреждена');
    host = hostPort.substring(0, close + 1);
    final tail = hostPort.substring(close + 1);
    if (tail.isNotEmpty) {
      if (!tail.startsWith(':')) throw ShareLinkException('Ссылка Hysteria2 повреждена');
      portText = tail.substring(1);
    }
  } else if (hostPort.contains(':')) {
    final i = hostPort.indexOf(':');
    host = hostPort.substring(0, i);
    portText = hostPort.substring(i + 1);
  }
  var ports = _hyPorts(portText);
  final u = _uri('hysteria2://$user$host:${ports.first.first}$suffix');
  final q = _query(u);
  for (final key in ['ports', 'mport']) {
    if ((q[key] ?? '').isNotEmpty) ports = _hyPorts(q[key]!);
  }
  final sec = (q['security'] ?? '').toLowerCase();
  if (sec.isNotEmpty && sec != 'tls') throw ShareLinkException('Hysteria2 работает только с TLS');

  final stream = _stream({...q, 'type': 'raw'}..remove('headerType'), scheme: 'hysteria2', host: u.host, forceTls: true);
  stream['network'] = 'hysteria';
  stream['hysteriaSettings'] = {'version': 2, 'auth': _decode(u.userInfo)};

  final udpMasks = <Map<String, dynamic>>[];
  final obfs = q['obfs'] ?? '';
  if (obfs.isNotEmpty && obfs != 'none') {
    final password = q['obfs-password'] ?? '';
    if (obfs != 'salamander' || password.length < 4) throw ShareLinkException('Маскировка Hysteria2 «$obfs» не поддерживается');
    udpMasks.add({
      'type': 'salamander',
      'settings': {'password': password},
    });
  }
  final hopping = ports.length > 1 || ports.first[0] != ports.first[1];
  if (hopping) {
    final interval = int.tryParse(q['hop-interval'] ?? '') ?? 30;
    udpMasks.add({
      'type': 'udphop',
      'settings': {
        'mode': 'intervalLocal,intervalRemote',
        'remotePorts': ports.map((r) => r[0] == r[1] ? '${r[0]}' : '${r[0]}-${r[1]}').join(','),
        'interval': interval < 5 ? 5 : interval,
      },
    });
  }
  final mask = <String, dynamic>{
    if (udpMasks.isNotEmpty) 'udp': udpMasks,
    if ((q['up'] ?? '').isNotEmpty || (q['down'] ?? '').isNotEmpty)
      'quicParams': {'congestion': 'brutal', if ((q['up'] ?? '').isNotEmpty) 'brutalUp': q['up'], if ((q['down'] ?? '').isNotEmpty) 'brutalDown': q['down']},
  };
  if (mask.isNotEmpty) stream['finalmask'] = mask;

  final port = ports.first.first;
  return ParsedLink(
    name: _name(u, u.host),
    protocol: 'hysteria2',
    address: u.host,
    port: port,
    outbound: _outbound('hysteria', {'version': 2, 'address': u.host, 'port': port}, stream),
  );
}
