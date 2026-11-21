package shop.autohitech.astatvpn

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.net.Inet4Address

/** Обёртка над ядром Xray (libXray). Все вызовы идут из одного потока службы или из потока замеров. */
object Core {
    private const val FALLBACK_DNS = "77.88.8.8:53"

    /** Служба, через которую сокеты ядра выводятся мимо туннеля. Без службы защищать нечего. */
    @Volatile private var service = WeakReference<AstatVpnService>(null)
    private var registered = false

    private val protector = object : DialerController {
        override fun protectFd(fd: Long): Boolean = service.get()?.protect(fd.toInt()) ?: true
    }

    fun attach(s: AstatVpnService?) { service = WeakReference(s) }

    @Synchronized
    private fun register() {
        if (registered) return
        LibXray.registerDialerController(protector)
        LibXray.registerListenerController(protector)
        registered = true
    }

    private fun call(method: String, payload: JSONObject? = null): JSONObject {
        val req = JSONObject().put("apiVersion", 3).put("method", method)
        if (payload != null) req.put("payload", payload)
        return JSONObject(LibXray.invoke(req.toString()))
    }

    private fun check(res: JSONObject) {
        if (!res.optBoolean("success")) throw IllegalStateException(res.optString("error").ifBlank { "неизвестная ошибка ядра" })
    }

    /** DNS-сервер текущей сети без VPN: через него ядро узнаёт адрес сервера по имени. */
    fun underlyingDns(context: Context): String {
        val cm = context.getSystemService(ConnectivityManager::class.java) ?: return FALLBACK_DNS
        val networks = listOfNotNull(cm.activeNetwork) + cm.allNetworks
        for (n in networks) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) || !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            val servers = cm.getLinkProperties(n)?.dnsServers ?: continue
            servers.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }?.let { return "${it.hostAddress}:53" }
            servers.firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }?.let { return "[${it.hostAddress?.substringBefore('%')}]:53" }
        }
        return FALLBACK_DNS
    }

    fun setDns(server: String) {
        register()
        try { LibXray.setDNS(protector, server) } catch (_: Exception) { LibXray.setDNS(protector, FALLBACK_DNS) }
    }

    fun start(context: Context, config: String, tunFd: Int) {
        register()
        val json = JSONObject(config)
        json.put("env", JSONObject().put("xray.tun.fd", tunFd.toString()).put("xray.location.asset", Geo.dir(context).absolutePath))
        val log = logFile(context)
        log.writeText("")
        // уровень задаёт приложение (обычный или подробный), остальное в разделе log из конфигурации не берём
        val level = json.optJSONObject("log")?.optString("loglevel").takeIf { it == "info" } ?: "warning"
        json.put("log", JSONObject().put("loglevel", level).put("access", "none").put("error", log.absolutePath))
        check(call("runXray", JSONObject().put("xrayJson", json.toString())))
    }

    fun stop() {
        try { call("stopXray") } catch (_: Exception) {}
        try { LibXray.resetDNS() } catch (_: Exception) {}
    }

    fun running(): Boolean = try { call("getXrayState").optJSONObject("data")?.optBoolean("running") ?: false } catch (_: Exception) { false }

    fun version(): String = try { call("xrayVersion").optJSONObject("data")?.optString("version") ?: "" } catch (_: Exception) { "" }

    /** Задержка через каждый сервер, мс; -1 — не отвечает. Все конфигурации замеряются одновременно. */
    fun ping(context: Context, configs: List<String>): List<Int> {
        setDns(underlyingDns(context))
        try {
            val items = JSONArray()
            configs.forEach { items.put(JSONObject().put("xrayJson", it)) }
            val res = call("pingBatch", JSONObject().put("configs", items).put("timeout", 4).put("url", "https://www.gstatic.com/generate_204"))
            check(res)
            val results = res.optJSONObject("data")?.optJSONArray("results") ?: JSONArray()
            return configs.indices.map { i ->
                val r = results.optJSONObject(i)
                if (r != null && r.optBoolean("success") && r.optLong("delay") in 1..9999) r.optLong("delay").toInt() else -1
            }
        } finally {
            try { LibXray.resetDNS() } catch (_: Exception) {}
        }
    }

    fun logFile(context: Context) = File(context.cacheDir, "core.log")

    fun logs(context: Context): String {
        val f = logFile(context)
        if (!f.exists()) return ""
        val max = 64 * 1024L
        return f.inputStream().use { s ->
            if (f.length() > max) s.skip(f.length() - max)
            s.readBytes().toString(Charsets.UTF_8)
        }
    }
}

/** Геобазы лежат в APK, а ядру нужны обычные файлы: копируем их один раз после установки или обновления. */
object Geo {
    private val files = listOf("geoip.dat", "geosite.dat")

    fun dir(context: Context) = File(context.filesDir, "geo")

    @Synchronized
    fun ensure(context: Context) {
        val dir = dir(context)
        val marker = File(dir, "version")
        val version = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (marker.exists() && marker.readText() == version && files.all { File(dir, it).length() > 0 }) return
        dir.mkdirs()
        for (name in files) {
            val tmp = File(dir, "$name.tmp")
            context.assets.open("geo/$name").use { input -> tmp.outputStream().use { input.copyTo(it) } }
            if (!tmp.renameTo(File(dir, name))) throw IllegalStateException("не удалось подготовить базы адресов")
        }
        marker.writeText(version)
    }
}

/** Последнее подключение: нужно, когда службу запускает система (постоянный VPN, перезапуск после сбоя). */
object Store {
    class Saved(val config: String, val name: String, val filter: String, val apps: List<String>)

    private fun file(context: Context) = File(context.noBackupFilesDir, "vpn.json")

    fun save(context: Context, s: Saved) {
        val json = JSONObject().put("config", s.config).put("name", s.name).put("filter", s.filter).put("apps", JSONArray(s.apps))
        val tmp = File(context.noBackupFilesDir, "vpn.json.tmp")
        tmp.writeText(json.toString())
        tmp.renameTo(file(context))
    }

    fun load(context: Context): Saved? = try {
        val j = JSONObject(file(context).readText())
        val apps = j.optJSONArray("apps") ?: JSONArray()
        Saved(j.getString("config"), j.optString("name"), j.optString("filter", "off"), (0 until apps.length()).map { apps.getString(it) })
    } catch (_: Exception) { null }
}
