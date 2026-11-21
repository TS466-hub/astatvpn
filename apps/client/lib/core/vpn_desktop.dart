import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'models.dart';
import 'vpn.dart';

/// VPN на Windows и macOS.
///
/// Приложение работает без прав администратора. Туннель поднимает служба AstatVPN (astat-helper, ядро Xray
/// внутри): на Windows её один раз ставит установщик, на macOS — само приложение по кнопке, с запросом пароля
/// администратора. Связь со службой — строки JSON: на Windows через именованный канал `\\.\pipe\AstatVPN`,
/// на macOS через сокет `/var/run/astatvpn.sock`. Локальных портов нет ни у приложения, ни у службы: другой
/// программе на компьютере не к чему подключиться, чтобы узнать сервер, ключи или пустить свой трафик в обход правил.
///
/// Файл собирается на всех платформах; системные вызовы Windows выполняются только при Platform.isWindows.
class DesktopVpn implements Vpn {
  DesktopVpn({HelperTransport? transport, bool? mac})
      : _supported = transport != null || Platform.isWindows || Platform.isMacOS,
        _mac = mac ?? (transport == null && Platform.isMacOS),
        _transport = transport ?? (Platform.isWindows ? PipeTransport() : (Platform.isMacOS ? SocketTransport(socketPath) : _NoTransport()));

  static const helperExe = 'astat-helper.exe';

  /// Сокет службы в macOS. Каталог доступен на запись только системе.
  static const socketPath = '/var/run/astatvpn.sock';

  /// Версия службы, с которой собрано приложение (HelperVersion в core/internal/xraycore). Если в системе
  /// стоит другая, приложение предлагает поставить службу заново.
  static const helperVersion = '0.1.1';

  /// Предел одной строки запроса. Такой же на стороне службы.
  static const maxRequestBytes = 4 * 1024 * 1024;

  final HelperTransport _transport;

  /// true — служба macOS: её ставит и обновляет само приложение, и сообщения об ошибках свои.
  final bool _mac;

  /// false — система без службы (не Windows и не macOS): ждать её незачем.
  final bool _supported;
  final _status = StreamController<VpnStatus>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  StreamSubscription<TransportEvent>? _sub;
  var _nextId = 1;
  var _connected = false;
  var _downCode = TransportDown.notStarted;
  var _last = const VpnStatus();
  Completer<void>? _up;

  /// Завершается, когда канал первый раз сообщил, открыт он или нет.
  final _settled = Completer<void>();

  void _ensureStarted() {
    if (_sub != null) return;
    _sub = _transport.events.listen(_onEvent);
    _transport.start();
  }

  void _onEvent(TransportEvent event) {
    if (event is! TransportLine && !_settled.isCompleted) _settled.complete();
    switch (event) {
      case TransportUp():
        _connected = true;
        _up?.complete();
        _up = null;
      case TransportDown(:final code):
        _downCode = code;
        if (!_connected) return;
        _connected = false;
        final error = VpnException(_downMessage());
        for (final c in _pending.values) {
          c.completeError(error);
        }
        _pending.clear();
        // Служба остановилась — туннеля больше нет. Когда она вернётся, пришлёт настоящее состояние.
        if (_last.state != VpnState.disconnected) {
          _emit(const VpnStatus(error: 'Служба AstatVPN остановилась, подключение разорвано'));
        }
      case TransportLine(:final line):
        _onLine(line);
    }
  }

  void _onLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    if (decoded['event'] == 'status') {
      final data = decoded['data'];
      if (data is Map) _emit(VpnStatus.fromMap(data));
      return;
    }
    final id = decoded['id'];
    final completer = id is int ? _pending.remove(id) : null;
    if (completer == null) return;
    if (decoded['ok'] == true) {
      final result = decoded['result'];
      completer.complete(result is Map ? result.cast<String, dynamic>() : <String, dynamic>{});
    } else {
      final error = decoded['error'];
      completer.completeError(VpnException(error is String && error.isNotEmpty ? error : 'Не удалось выполнить действие'));
    }
  }

  void _emit(VpnStatus status) {
    _last = status;
    if (!_status.isClosed) _status.add(status);
  }

  Future<bool> _waitConnected(Duration timeout) async {
    if (!_supported) return false;
    _ensureStarted();
    if (_connected) return true;
    final up = _up ??= Completer<void>();
    try {
      await up.future.timeout(timeout);
    } on TimeoutException {
      // служба не ответила
    }
    return _connected;
  }

  String _downMessage() {
    if (!_supported) return 'На этой платформе подключение пока не поддерживается';
    if (_mac) {
      return _downCode == TransportDown.accessDenied
          ? 'Служба AstatVPN отвечает только тому, кто вошёл в систему за этим Mac.'
          : 'Служба AstatVPN не установлена. Нажмите «Установить службу»: потребуется пароль администратора.';
    }
    return switch (_downCode) {
      TransportDown.untrusted => 'Канал службы AstatVPN занят посторонней программой. Перезагрузите компьютер; '
          'если не поможет, переустановите приложение.',
      TransportDown.accessDenied => 'Нет доступа к службе AstatVPN. Переустановите приложение или запустите установщик ещё раз.',
      _ => 'Служба AstatVPN не установлена или не запущена. Переустановите приложение или запустите установщик ещё раз.',
    };
  }

  Future<Map<String, dynamic>> _request(String method, {Map<String, dynamic>? params, Duration timeout = const Duration(seconds: 10)}) async {
    // Если уже известно, что службы нет, не заставляем человека ждать на каждом действии:
    // перед подключением её отдельно ждёт prepare().
    final known = _settled.isCompleted && !_connected;
    if (known || !await _waitConnected(const Duration(seconds: 2))) throw VpnException(_downMessage());
    final id = _nextId++;
    final line = '${jsonEncode({'id': id, 'method': method, 'params': params ?? const <String, dynamic>{}})}\n';
    // оценка сверху без перекодирования: в UTF-8 символ занимает до трёх байт на единицу UTF-16
    if (line.length > maxRequestBytes || (line.length * 3 > maxRequestBytes && utf8.encode(line).length > maxRequestBytes)) {
      throw VpnException('Конфигурация слишком большая');
    }
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _transport.send(line);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      throw VpnException('Служба AstatVPN не отвечает');
    }
  }

  @override
  Stream<VpnStatus> get statusStream {
    _ensureStarted();
    return _status.stream;
  }

  @override
  Future<VpnStatus> status() async {
    if (!_supported) return const VpnStatus();
    try {
      // при запуске приложения не ждём службу дольше, чем нужно, чтобы узнать, есть ли она
      _ensureStarted();
      await _settled.future.timeout(const Duration(milliseconds: 1500), onTimeout: () {});
      if (!_connected) return const VpnStatus();
      final status = VpnStatus.fromMap(await _request('status', timeout: const Duration(seconds: 5)));
      _last = status;
      return status;
    } catch (_) {
      return const VpnStatus();
    }
  }

  /// На Windows разрешение не спрашивается: достаточно, чтобы служба была установлена и отвечала.
  @override
  Future<bool> prepare() async {
    if (await _waitConnected(const Duration(seconds: 4))) return true;
    throw VpnException(_downMessage());
  }

  /// Раздельное туннелирование по приложениям на Windows не поддерживается: [filter] и [apps] не используются.
  @override
  Future<void> start({required String config, required String name, required AppFilterMode filter, required List<String> apps}) async {
    // служба создаёт сетевой адаптер и ждёт, пока Windows его настроит: это занимает до 15–20 секунд
    await _request('start', params: {'config': config, 'name': name}, timeout: const Duration(seconds: 90));
  }

  @override
  Future<void> stop() async {
    await _request('stop', timeout: const Duration(seconds: 45));
  }

  @override
  Future<List<int>> ping(List<String> configs) async {
    final delays = <int>[];
    // делим на части, чтобы запрос не упёрся в предел размера
    var from = 0;
    while (from < configs.length) {
      var to = from;
      var size = 0;
      while (to < configs.length && to - from < 64 && (to == from || size + configs[to].length * 3 < maxRequestBytes ~/ 2)) {
        size += configs[to].length * 3;
        to++;
      }
      final batch = configs.sublist(from, to);
      // служба замеряет по шестнадцать серверов сразу, до восьми секунд на каждый
      final timeout = Duration(seconds: 15 + 8 * ((batch.length + 15) ~/ 16));
      final result = await _request('ping', params: {'configs': batch}, timeout: timeout);
      final got = result['delays'];
      final list = got is List ? got : const [];
      for (var i = 0; i < batch.length; i++) {
        final v = i < list.length ? list[i] : null;
        delays.add(v is num ? v.toInt() : -1);
      }
      from = to;
    }
    return delays;
  }

  @override
  Future<List<InstalledApp>> apps() async => const [];

  /// Системных настроек «постоянного VPN» на компьютере нет.
  @override
  Future<bool> openVpnSettings() async => false;

  @override
  Future<Map<String, String>> deviceInfo() async {
    try {
      return {'model': Platform.localHostname, 'osVersion': Platform.operatingSystemVersion};
    } catch (_) {
      return {};
    }
  }

  @override
  Future<String> coreVersion() async {
    try {
      final v = (await _request('version'))['core'];
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<String> logs() async {
    try {
      final v = (await _request('logs'))['text'];
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  /// true — служба отвечает. На macOS ещё и той же версии, что приложение: там её обновляет не установщик,
  /// а само приложение.
  Future<bool> serviceAvailable() async {
    if (!await _waitConnected(const Duration(seconds: 2))) return false;
    if (!_mac) return true;
    try {
      return (await _request('version'))['helper'] == helperVersion;
    } on VpnException {
      return false;
    }
  }

  /// Ставит службу: запускает `astat-helper.exe install` с запросом прав администратора (окно UAC).
  ///
  /// Для кнопки «Установить службу». Возвращает true, когда служба ответила. Если человек отказал в окне UAC
  /// или файла службы нет рядом с приложением, бросает [VpnException].
  Future<bool> installService() async {
    if (Platform.isMacOS) return _installOnMac();
    if (!Platform.isWindows) throw VpnException('На этой платформе подключение пока не поддерживается');
    final exe = File('${File(Platform.resolvedExecutable).parent.path}\\$helperExe');
    if (!exe.existsSync()) {
      throw VpnException('Рядом с приложением нет файла $helperExe. Переустановите приложение.');
    }
    // окно UAC держит вызов, пока человек не ответит: ждём в отдельном изоляте, а не в интерфейсе
    final code = await _runElevatedInBackground(exe.path, 'install');
    if (code <= 32) {
      throw VpnException(code == _errorCancelled
          ? 'Для установки службы нужно разрешение администратора.'
          : 'Не удалось запустить установку службы (код $code).');
    }
    for (var i = 0; i < 20; i++) {
      if (await _waitConnected(const Duration(seconds: 1))) return true;
    }
    throw VpnException('Служба AstatVPN не запустилась. Переустановите приложение.');
  }

  /// macOS: служба лежит внутри приложения (Contents/Resources). Команда `astat-helper install` копирует её
  /// в системный каталог и запускает через launchd; права даёт системное окно с паролем администратора.
  Future<bool> _installOnMac() async {
    final helper = File('${File(Platform.resolvedExecutable).parent.parent.path}/Resources/astat-helper');
    if (!helper.existsSync()) {
      throw VpnException('В приложении нет файла службы. Скачайте приложение заново.');
    }
    final ProcessResult result;
    try {
      result = await Process.run('/usr/bin/osascript', ['-e', macInstallScript(helper.path)]);
    } on ProcessException {
      throw VpnException('Не удалось запустить установку службы.');
    }
    if (result.exitCode != 0) {
      final text = '${result.stderr}'.trim();
      // -128: человек закрыл окно с паролем
      if (text.contains('-128')) throw VpnException('Для установки службы нужен пароль администратора.');
      final reason = RegExp(r'Ошибка: ([^\n]+)').firstMatch(text)?.group(1);
      throw VpnException(reason == null ? 'Не удалось установить службу.' : 'Не удалось установить службу: $reason');
    }
    for (var i = 0; i < 20; i++) {
      if (await serviceAvailable()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw VpnException('Служба AstatVPN не запустилась. Попробуйте установить её ещё раз.');
  }

  /// Команда AppleScript для установки службы. Путь к службе экранируется дважды: для оболочки и для AppleScript.
  static String macInstallScript(String helperPath) {
    final shell = "'${helperPath.replaceAll("'", "'\\''")}' install";
    final quoted = shell.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return 'do shell script "$quoted" with prompt "AstatVPN устанавливает службу, которая создаёт VPN-подключение." with administrator privileges';
  }

  void dispose() {
    _sub?.cancel();
    _transport.dispose();
    _status.close();
  }
}

Future<int> _runElevatedInBackground(String file, String arguments) => Isolate.run(() => _runElevated(file, arguments));

/// Канал до службы: строки туда и обратно. Отделён от [DesktopVpn], чтобы логику можно было проверить без Windows.
abstract class HelperTransport {
  Stream<TransportEvent> get events;

  /// Начинает подключаться и переподключается сам, пока не вызван [dispose].
  void start();

  /// Отправляет строку (с переводом строки на конце). Если канал закрыт, строка теряется.
  void send(String line);

  void dispose();
}

sealed class TransportEvent {}

class TransportUp extends TransportEvent {}

class TransportDown extends TransportEvent {
  TransportDown(this.code);

  /// Код ошибки Windows или одно из значений ниже.
  final int code;

  static const notStarted = 0;
  static const notFound = 2; // ERROR_FILE_NOT_FOUND: службы нет
  static const accessDenied = 5; // ERROR_ACCESS_DENIED
  static const untrusted = -2; // канал создала не служба
  static const failed = -1;
}

class TransportLine extends TransportEvent {
  TransportLine(this.line);
  final String line;
}

/// Сокет службы в macOS. Подключается заново сам, если служба перезапустилась.
class SocketTransport implements HelperTransport {
  SocketTransport(this.path);

  final String path;
  final _events = StreamController<TransportEvent>.broadcast();
  Socket? _socket;
  var _started = false;
  var _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  void start() {
    if (_started) return;
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    while (!_disposed) {
      var code = TransportDown.failed;
      var pause = const Duration(seconds: 1);
      try {
        final socket = await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0, timeout: const Duration(seconds: 3));
        if (_disposed) {
          socket.destroy();
          return;
        }
        _socket = socket;
        _events.add(TransportUp());
        final opened = DateTime.now();
        var received = false;
        try {
          await for (final line in utf8.decoder.bind(socket).transform(const LineSplitter())) {
            received = true;
            if (!_disposed) _events.add(TransportLine(line));
          }
        } catch (_) {
          // обрыв: ниже подключаемся заново
        }
        // служба закрывает подключение сразу, если его открыл не тот, кто вошёл в систему за этим Mac
        if (!received && DateTime.now().difference(opened) < const Duration(milliseconds: 500)) {
          code = TransportDown.accessDenied;
          pause = const Duration(seconds: 5);
        }
      } on SocketException catch (e) {
        final errno = e.osError?.errorCode;
        // ENOENT и ECONNREFUSED: службы нет или она не запущена; EACCES: сокет недоступен
        code = errno == 13 ? TransportDown.accessDenied : TransportDown.notFound;
      } catch (_) {
        code = TransportDown.failed;
      }
      _socket?.destroy();
      _socket = null;
      if (_disposed) return;
      _events.add(TransportDown(code));
      await Future<void>.delayed(pause);
    }
  }

  @override
  void send(String line) {
    try {
      _socket?.write(line);
    } catch (_) {
      // канал закрылся: запрос завершится по времени ожидания
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _socket?.destroy();
    _socket = null;
    _events.close();
  }
}

class _NoTransport implements HelperTransport {
  @override
  Stream<TransportEvent> get events => const Stream.empty();
  @override
  void start() {}
  @override
  void send(String line) {}
  @override
  void dispose() {}
}

/// Именованный канал Windows. Вся работа с ним идёт в фоновом изоляте: интерфейс не ждёт ни открытия,
/// ни записи, ни чтения. Если служба перезапустилась, изолят подключается заново.
class PipeTransport implements HelperTransport {
  final _events = StreamController<TransportEvent>.broadcast();
  ReceivePort? _fromIsolate;
  ReceivePort? _exit;
  SendPort? _toIsolate;
  var _started = false;
  var _disposed = false;

  @override
  Stream<TransportEvent> get events => _events.stream;

  @override
  void start() {
    if (_started) return;
    _started = true;
    _spawn();
  }

  Future<void> _spawn() async {
    if (_disposed) return;
    final port = ReceivePort();
    final exit = ReceivePort();
    _fromIsolate = port;
    _exit = exit;
    port.listen((message) {
      if (message is SendPort) {
        _toIsolate = message;
      } else if (message is List && message.isNotEmpty && !_events.isClosed) {
        switch (message[0]) {
          case 'up':
            _events.add(TransportUp());
          case 'down':
            _events.add(TransportDown(message[1] as int));
          case 'line':
            _events.add(TransportLine(message[1] as String));
        }
      }
    });
    // изолят не должен завершаться сам; если это случилось, поднимаем его заново
    exit.listen((_) {
      port.close();
      exit.close();
      _toIsolate = null;
      if (_disposed) return;
      _events.add(TransportDown(TransportDown.failed));
      Future<void>.delayed(const Duration(seconds: 2), _spawn);
    });
    try {
      await Isolate.spawn(_pipeIsolate, port.sendPort, onExit: exit.sendPort, errorsAreFatal: true, debugName: 'astat-pipe');
    } catch (_) {
      port.close();
      exit.close();
      if (!_disposed) _events.add(TransportDown(TransportDown.failed));
    }
  }

  @override
  void send(String line) => _toIsolate?.send(line);

  @override
  void dispose() {
    _disposed = true;
    _toIsolate?.send(null);
    _fromIsolate?.close();
    _exit?.close();
    _events.close();
  }
}

// ---------------------------------------------------------------------------------------------------------
// Ниже — только Windows. Функции системы объявлены здесь напрямую через dart:ffi: их немного, а пакет win32
// от версии к версии меняет имена и типы. Глобальные переменные в Dart создаются при первом обращении,
// поэтому на других платформах библиотеки не загружаются.
// ---------------------------------------------------------------------------------------------------------

const _pipeName = r'\\.\pipe\AstatVPN';

const _genericRead = 0x80000000;
const _fileWriteData = 0x0002;
const _openExisting = 3;
const _securitySqosPresent = 0x00100000; // служба не сможет действовать от нашего имени (SECURITY_ANONYMOUS)
const _invalidHandle = -1;

const _errorFileNotFound = 2;
const _errorAccessDenied = 5;
const _errorPipeBusy = 231;
const _errorCancelled = 1223; // человек закрыл окно UAC

const _seKernelObject = 6;
const _ownerSecurityInformation = 0x00000001;
const _winLocalSystemSid = 22;
const _winBuiltinAdministratorsSid = 26;

const _swHide = 0;

/// Больше этого служба одной строкой не присылает (журнал — до 500 строк по 2000 символов).
const _maxLineBytes = 16 * 1024 * 1024;

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');

final _createFile = _kernel32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
final _readFile = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');
final _writeFile = _kernel32.lookupFunction<Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
    int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');
final _peekNamedPipe = _kernel32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>),
    int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint32>)>('PeekNamedPipe');
final _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
final _getLastError = _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
final _localFree = _kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
final _getSecurityInfo = _advapi32.lookupFunction<
    Uint32 Function(IntPtr, Int32, Uint32, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>),
    int Function(int, int, int, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>, Pointer<Pointer<Void>>,
        Pointer<Pointer<Void>>)>('GetSecurityInfo');
final _isWellKnownSid = _advapi32.lookupFunction<Int32 Function(Pointer<Void>, Int32), int Function(Pointer<Void>, int)>('IsWellKnownSid');

/// Открывает канал службы. Возвращает дескриптор и 0 либо код ошибки (см. [TransportDown]).
(int handle, int error) _openPipe() {
  final name = _pipeName.toNativeUtf16();
  try {
    // Права именно такие: служба не даёт обычным программам FILE_CREATE_PIPE_INSTANCE, которое входит
    // в GENERIC_WRITE, чтобы никто не мог создать свой экземпляр канала. С GENERIC_WRITE было бы «нет доступа».
    final handle = _createFile(name, _genericRead | _fileWriteData, 0, nullptr, _openExisting, _securitySqosPresent, 0);
    if (handle == _invalidHandle) {
      final code = _getLastError();
      return (_invalidHandle, code == 0 ? _errorFileNotFound : code);
    }
    if (!_ownedBySystem(handle)) {
      _closeHandle(handle);
      return (_invalidHandle, TransportDown.untrusted);
    }
    return (handle, 0);
  } finally {
    malloc.free(name);
  }
}

/// Проверяет, что канал создала служба, а не программа, занявшая его имя, пока служба не работала:
/// иначе конфигурация с ключами сервера ушла бы постороннему. У канала службы владелец — SYSTEM
/// или группа администраторов; программа без прав администратора назначить такого владельца не может.
bool _ownedBySystem(int handle) {
  final owner = calloc<Pointer<Void>>();
  final descriptor = calloc<Pointer<Void>>();
  try {
    final rc = _getSecurityInfo(handle, _seKernelObject, _ownerSecurityInformation, owner, nullptr, nullptr, nullptr, descriptor);
    if (rc != 0 || owner.value == nullptr) return false;
    return _isWellKnownSid(owner.value, _winLocalSystemSid) != 0 || _isWellKnownSid(owner.value, _winBuiltinAdministratorsSid) != 0;
  } finally {
    if (descriptor.value != nullptr) _localFree(descriptor.value);
    calloc.free(owner);
    calloc.free(descriptor);
  }
}

bool _writeAll(int handle, Uint8List bytes) {
  final buffer = malloc<Uint8>(bytes.length);
  final written = calloc<Uint32>();
  try {
    buffer.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      if (_writeFile(handle, buffer + offset, bytes.length - offset, written, nullptr) == 0 || written.value == 0) return false;
      offset += written.value;
    }
    return true;
  } finally {
    malloc.free(buffer);
    calloc.free(written);
  }
}

/// Фоновый изолят: держит канал открытым, пишет в него строки от приложения и читает строки службы.
///
/// Чтение без ожидания: сначала PeekNamedPipe узнаёт, есть ли данные, и только тогда вызывается ReadFile.
/// Обычный ReadFile ждал бы данных и не давал бы писать в тот же дескриптор, а сам изолят не мог бы принять
/// от приложения новую строку. Между опросами изолят отдаёт управление: 5 мс сразу после запроса и 50 мс в покое.
Future<void> _pipeIsolate(SendPort toMain) async {
  final inbox = ReceivePort();
  final outgoing = Queue<String>();
  var running = true;
  inbox.listen((message) {
    if (message == null) {
      running = false;
    } else if (message is String) {
      outgoing.add(message);
    }
  });
  toMain.send(inbox.sendPort);

  const chunk = 64 * 1024;
  final buffer = calloc<Uint8>(chunk);
  final count = calloc<Uint32>();
  final available = calloc<Uint32>();
  var lastDown = TransportDown.notStarted;
  var busyRetries = 0;

  try {
    while (running) {
      final (handle, code) = _openPipe();
      if (code == _errorPipeBusy && busyRetries < 20) {
        // служба как раз принимает другое подключение: свободный экземпляр канала появится через мгновение
        busyRetries++;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      busyRetries = 0;
      if (code != 0) {
        // строки, отправленные в закрытый канал, никому не нужны: приложение уже получило ошибку
        outgoing.clear();
        if (code != lastDown) {
          lastDown = code;
          toMain.send(['down', code]);
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        continue;
      }
      lastDown = TransportDown.notStarted;
      toMain.send(['up']);

      final pending = BytesBuilder(copy: false);
      var idle = 0;
      var alive = true;
      while (running && alive) {
        var wrote = false;
        while (alive && outgoing.isNotEmpty) {
          alive = _writeAll(handle, utf8.encode(outgoing.removeFirst()));
          wrote = true;
        }
        while (alive) {
          if (_peekNamedPipe(handle, nullptr, 0, nullptr, available, nullptr) == 0) {
            alive = false;
            break;
          }
          if (available.value == 0) break;
          final want = available.value < chunk ? available.value : chunk;
          if (_readFile(handle, buffer, want, count, nullptr) == 0 || count.value == 0) {
            alive = false;
            break;
          }
          final data = Uint8List.fromList(buffer.asTypedList(count.value));
          var start = 0;
          for (var i = 0; i < data.length; i++) {
            if (data[i] != 0x0A) continue;
            pending.add(Uint8List.sublistView(data, start, i));
            final line = utf8.decode(pending.takeBytes(), allowMalformed: true).trim();
            if (line.isNotEmpty) toMain.send(['line', line]);
            start = i + 1;
          }
          if (start < data.length) pending.add(Uint8List.sublistView(data, start));
          if (pending.length > _maxLineBytes) alive = false;
        }
        if (!alive) break;
        // после запроса ответ обычно приходит сразу: полсекунды опрашиваем чаще
        idle = wrote ? 0 : idle + 1;
        await Future<void>.delayed(Duration(milliseconds: idle < 100 ? 5 : 50));
      }
      _closeHandle(handle);
      outgoing.clear();
      if (running) {
        toMain.send(['down', TransportDown.notFound]);
        lastDown = TransportDown.notFound;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
  } finally {
    calloc.free(buffer);
    calloc.free(count);
    calloc.free(available);
    inbox.close();
  }
}

/// Запускает программу с запросом прав администратора. Возвращает код ShellExecute: больше 32 — запущено,
/// иначе код ошибки Windows (1223 — человек отказал).
int _runElevated(String file, String arguments) {
  final shell32 = DynamicLibrary.open('shell32.dll');
  final shellExecute = shell32.lookupFunction<
      IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Int32),
      int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>, int)>('ShellExecuteW');
  final verb = 'runas'.toNativeUtf16();
  final path = file.toNativeUtf16();
  final args = arguments.toNativeUtf16();
  try {
    final result = shellExecute(0, verb, path, args, nullptr, _swHide);
    if (result > 32) return result;
    final code = _getLastError();
    return code == _errorCancelled || result == _errorAccessDenied ? _errorCancelled : result;
  } finally {
    malloc.free(verb);
    malloc.free(path);
    malloc.free(args);
  }
}
