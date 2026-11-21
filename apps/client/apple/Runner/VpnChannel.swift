#if os(iOS)
import Flutter
import UIKit
#else
import Cocoa
import FlutterMacOS
#endif
import NetworkExtension

/// Связь экрана с системным VPN на iOS и macOS: те же каналы и те же ответы, что на Android.
final class VpnChannel: NSObject, FlutterStreamHandler {
    private var manager: NETunnelProviderManager?
    private var sink: FlutterEventSink?
    private var timer: Timer?
    private var rx: Int64 = 0
    private var tx: Int64 = 0
    private var lastError: String?
    private var serverName: String?
    private var observer: NSObjectProtocol?
    private let work = DispatchQueue(label: "astat.vpn.core")

    static func register(with messenger: FlutterBinaryMessenger) -> VpnChannel {
        let channel = VpnChannel()
        FlutterMethodChannel(name: "astat/vpn", binaryMessenger: messenger).setMethodCallHandler(channel.handle)
        FlutterEventChannel(name: "astat/vpn/events", binaryMessenger: messenger).setStreamHandler(channel)
        channel.observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak channel] note in
            guard let channel, let connection = note.object as? NEVPNConnection, connection === channel.manager?.connection else { return }
            channel.statusChanged()
        }
        channel.load { _ in channel.statusChanged() }
        return channel
    }

    // MARK: состояние

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        events(snapshot())
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private var state: String {
        switch manager?.connection.status {
        case .connecting, .reasserting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "stopping"
        default: return "disconnected"
        }
    }

    private func snapshot() -> [String: Any?] {
        let connected = state == "connected"
        let since = connected ? Int64((manager?.connection.connectedDate ?? Date()).timeIntervalSince1970 * 1000) : 0
        return ["state": state, "since": since, "error": lastError, "rx": connected ? rx : 0, "tx": connected ? tx : 0, "name": serverName]
    }

    private func statusChanged() {
        switch state {
        case "connected":
            lastError = nil
            startTrafficTimer()
        case "disconnected":
            stopTrafficTimer()
            rx = 0
            tx = 0
            // расширение оставляет причину сбоя в общей папке
            if let text = try? String(contentsOf: AstatShared.errorFile, encoding: .utf8), !text.isEmpty {
                lastError = text
                try? FileManager.default.removeItem(at: AstatShared.errorFile)
            }
        default:
            break
        }
        sink?(snapshot())
    }

    private func startTrafficTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.askTraffic() }
    }

    private func stopTrafficTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func askTraffic() {
        guard let session = manager?.connection as? NETunnelProviderSession, session.status == .connected else { return }
        try? session.sendProviderMessage(Data("traffic".utf8)) { [weak self] reply in
            guard let self, let reply, let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.rx = (json["rx"] as? NSNumber)?.int64Value ?? self.rx
                self.tx = (json["tx"] as? NSNumber)?.int64Value ?? self.tx
                if self.state == "connected" { self.sink?(self.snapshot()) }
            }
        }
    }

    // MARK: настройка VPN в системе

    private var tunnelBundleId: String { (Bundle.main.bundleIdentifier ?? "") + AstatShared.tunnelSuffix }

    /// Находит нашу настройку VPN среди сохранённых в системе или готовит новую (ещё не сохранённую).
    private func load(_ done: @escaping (NETunnelProviderManager) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let found = managers?.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == self.tunnelBundleId }
                let manager = found ?? NETunnelProviderManager()
                self.manager = manager
                self.serverName = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["name"] as? String
                done(manager)
            }
        }
    }

    /// Сохраняет настройку VPN. При первом сохранении система спрашивает у человека разрешение.
    private func save(_ manager: NETunnelProviderManager, config: String?, name: String?, done: @escaping (Error?) -> Void) {
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleId
        proto.serverAddress = "AstatVPN"
        if let config {
            proto.providerConfiguration = ["config": config, "name": name ?? ""]
        }
        manager.protocolConfiguration = proto
        manager.localizedDescription = "AstatVPN"
        manager.isEnabled = true
        manager.saveToPreferences { error in
            if let error {
                DispatchQueue.main.async { done(error) }
                return
            }
            // после сохранения настройку нужно перечитать, иначе запуск завершается ошибкой
            manager.loadFromPreferences { error in DispatchQueue.main.async { done(error) } }
        }
    }

    // MARK: вызовы из приложения

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "status":
            result(snapshot())
        case "prepare":
            load { manager in
                // настройка уже сохранена и разрешение дано
                if manager.protocolConfiguration != nil, manager.isEnabled {
                    result(true)
                    return
                }
                self.save(manager, config: nil, name: nil) { error in
                    guard let error else {
                        result(true)
                        return
                    }
                    if (error as NSError).domain == NEVPNErrorDomain, (error as NSError).code == NEVPNError.configurationReadWriteFailed.rawValue {
                        // человек отказал в системном запросе
                        result(false)
                    } else {
                        result(FlutterError(code: "prepare", message: "Система не дала настроить VPN: \(error.localizedDescription)", details: nil))
                    }
                }
            }
        case "start":
            guard let config = args["config"] as? String, !config.isEmpty else {
                result(FlutterError(code: "config", message: "Нет конфигурации подключения", details: nil))
                return
            }
            let name = args["name"] as? String ?? ""
            load { manager in
                self.save(manager, config: config, name: name) { error in
                    if let error {
                        result(FlutterError(code: "start", message: "Система не дала запустить VPN: \(error.localizedDescription)", details: nil))
                        return
                    }
                    self.serverName = name
                    self.lastError = nil
                    try? FileManager.default.removeItem(at: AstatShared.errorFile)
                    do {
                        try manager.connection.startVPNTunnel()
                        result(nil)
                    } catch {
                        result(FlutterError(code: "start", message: "Система не дала запустить VPN: \(error.localizedDescription)", details: nil))
                    }
                }
            }
        case "stop":
            manager?.connection.stopVPNTunnel()
            result(nil)
        case "ping":
            guard state == "disconnected" else {
                result(FlutterError(code: "busy", message: "Замер задержки работает при выключенном VPN", details: nil))
                return
            }
            let configs = args["configs"] as? [String] ?? []
            work.async {
                let delays = try? Core.ping(configs)
                DispatchQueue.main.async {
                    if let delays { result(delays) } else { result(FlutterError(code: "ping", message: "Не удалось измерить задержку", details: nil)) }
                }
            }
        case "apps":
            // выбор приложений для VPN есть только на Android
            result([[String: Any]]())
        case "openVpnSettings":
            result(false)
        case "deviceInfo":
            result(Self.deviceInfo())
        case "coreVersion":
            work.async {
                let version = Core.version()
                DispatchQueue.main.async { result(version) }
            }
        case "logs":
            work.async {
                let text = AstatShared.readLog()
                DispatchQueue.main.async { result(text) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func deviceInfo() -> [String: String] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        var size = 0
        // модель устройства: на iOS это hw.machine (iPhone16,1), на Mac — hw.model (Mac15,6)
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        sysctlbyname(key, nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(key, &buffer, &size, nil, 0)
        return ["model": String(cString: buffer), "osVersion": os]
    }
}
