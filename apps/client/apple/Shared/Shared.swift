import Foundation
import LibXray

/// Общее для приложения и расширения туннеля: где лежат журнал и причина последнего сбоя, как вызвать ядро.
enum AstatShared {
    /// Идентификатор расширения туннеля: идентификатор приложения с этим окончанием.
    static let tunnelSuffix = ".tunnel"

    /// Общая папка приложения и расширения. Идентификатор группы задан в Info.plist (ключ AstatAppGroup),
    /// потому что на iOS и macOS он записывается по-разному.
    static var container: URL {
        let group = (Bundle.main.object(forInfoDictionaryKey: "AstatAppGroup") as? String) ?? ""
        if !group.isEmpty, !group.hasPrefix("."), let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
            return url
        }
        return FileManager.default.temporaryDirectory
    }

    static var logFile: URL { container.appendingPathComponent("core.log") }
    static var errorFile: URL { container.appendingPathComponent("last-error.txt") }

    static func readLog(limit: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Вызов ядра Xray (libXray): один вход, запрос и ответ в JSON.
enum Core {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func call(_ method: String, payload: [String: Any]? = nil) throws -> [String: Any] {
        var request: [String: Any] = ["apiVersion": 3, "method": method]
        if let payload { request["payload"] = payload }
        let body = try JSONSerialization.data(withJSONObject: request)
        let raw = LibXrayInvoke(String(decoding: body, as: UTF8.self))
        guard let response = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw Failure(message: "неизвестная ошибка ядра")
        }
        if response["success"] as? Bool != true {
            let text = (response["error"] as? String) ?? ""
            throw Failure(message: text.isEmpty ? "неизвестная ошибка ядра" : text)
        }
        return response
    }

    static func version() -> String {
        let data = (try? call("xrayVersion"))?["data"] as? [String: Any]
        return (data?["version"] as? String) ?? ""
    }

    /// Задержка через каждый сервер, мс; -1 — не отвечает.
    static func ping(_ configs: [String]) throws -> [Int] {
        let response = try call("pingBatch", payload: [
            "configs": configs.map { ["xrayJson": $0] },
            "timeout": 4,
            "url": "https://www.gstatic.com/generate_204",
        ])
        let results = ((response["data"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return configs.indices.map { i in
            guard i < results.count, results[i]["success"] as? Bool == true, let delay = (results[i]["delay"] as? NSNumber)?.intValue, (1...9999).contains(delay) else { return -1 }
            return delay
        }
    }
}
