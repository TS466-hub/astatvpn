import Foundation
import NetworkExtension

/// Расширение системного VPN. Система отдаёт сюда все пакеты устройства, ядро Xray читает их прямо
/// из интерфейса туннеля. Локальных прокси и портов управления нет, как и на Android.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var interfaceName: String?
    // счётчики интерфейса 32-битные: считаем приращения, чтобы не обнулиться на 4 ГБ
    private var lastIn: UInt32 = 0
    private var lastOut: UInt32 = 0
    private var totalIn: Int64 = 0
    private var totalOut: Int64 = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        try? FileManager.default.removeItem(at: AstatShared.errorFile)
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration?["config"] as? String, !config.isEmpty
        else {
            completionHandler(fail("Нет конфигурации подключения. Откройте приложение и подключитесь заново."))
            return
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = 1500
        let v4 = NEIPv4Settings(addresses: ["172.19.0.2"], subnetMasks: ["255.255.255.252"])
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4
        // IPv6 тоже заводим в туннель: иначе в сетях с IPv6 он шёл бы мимо VPN
        let v6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::2"], networkPrefixLengths: [126])
        v6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = v6
        // адрес внутри туннеля: запросы DNS перехватывает ядро и отправляет по своим правилам
        let dns = NEDNSSettings(servers: ["172.19.0.1"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(self.fail("Система не приняла настройки туннеля: \(error.localizedDescription)"))
                return
            }
            do {
                try self.startCore(config)
                completionHandler(nil)
            } catch {
                completionHandler(self.fail("Ядро не запустилось: \(error.localizedDescription)"))
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        try? Core.call("stopXray")
        completionHandler()
    }

    /// Приложение спрашивает счётчики трафика, пока туннель включён.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard String(decoding: messageData, as: UTF8.self) == "traffic" else {
            completionHandler?(nil)
            return
        }
        updateTraffic()
        completionHandler?(try? JSONSerialization.data(withJSONObject: ["rx": totalIn, "tx": totalOut]))
    }

    private func startCore(_ config: String) throws {
        guard var json = try JSONSerialization.jsonObject(with: Data(config.utf8)) as? [String: Any] else {
            throw Core.Failure(message: "конфигурация повреждена")
        }
        guard let tun = Self.findTunnel() else {
            throw Core.Failure(message: "не найден интерфейс туннеля")
        }
        interfaceName = tun.name
        guard let assets = Bundle.main.url(forResource: "geoip", withExtension: "dat")?.deletingLastPathComponent().path else {
            throw Core.Failure(message: "в приложении нет геобаз")
        }
        // уровень задаёт приложение (обычный или подробный), остальное в разделе log из конфигурации не берём
        let level = ((json["log"] as? [String: Any])?["loglevel"] as? String) == "info" ? "info" : "warning"
        FileManager.default.createFile(atPath: AstatShared.logFile.path, contents: Data())
        json["log"] = ["loglevel": level, "access": "none", "error": AstatShared.logFile.path]
        json["env"] = ["xray.tun.fd": String(tun.fd), "xray.location.asset": assets]
        let body = try JSONSerialization.data(withJSONObject: json)
        try Core.call("runXray", payload: ["xrayJson": String(decoding: body, as: UTF8.self)])
    }

    /// Причина сбоя остаётся в общей папке: приложение покажет её человеку.
    private func fail(_ message: String) -> NSError {
        try? message.write(to: AstatShared.errorFile, atomically: true, encoding: .utf8)
        return NSError(domain: "AstatVPN", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Система не отдаёт дескриптор туннеля напрямую: ищем среди открытых тот, что принадлежит utun.
    private static func findTunnel() -> (fd: Int32, name: String)? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd in Int32(0)...1024 {
            var length = socklen_t(buffer.count)
            // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2
            if getsockopt(fd, 2, 2, &buffer, &length) == 0 {
                let name = String(cString: buffer)
                if name.hasPrefix("utun") { return (fd, name) }
            }
        }
        return nil
    }

    private func updateTraffic() {
        guard let name = interfaceName else { return }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name) == name, let raw = entry.pointee.ifa_data
            else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            // для интерфейса туннеля «входящие» — то, что ядро отдало устройству (загрузка)
            totalIn += Int64(data.ifi_ibytes &- lastIn)
            totalOut += Int64(data.ifi_obytes &- lastOut)
            lastIn = data.ifi_ibytes
            lastOut = data.ifi_obytes
            return
        }
    }
}
