package shop.autohitech.astatvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.TrafficStats
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import androidx.core.app.NotificationCompat
import java.util.concurrent.Executors

/**
 * Системный VPN. Трафик приложений попадает в интерфейс TUN, его дескриптор передаётся ядру Xray напрямую.
 * Локальных прокси и портов управления нет: другим приложениям не к чему подключиться на localhost.
 */
class AstatVpnService : VpnService() {
    companion object {
        const val ACTION_START = "shop.autohitech.astatvpn.START"
        const val ACTION_STOP = "shop.autohitech.astatvpn.STOP"
        private const val CHANNEL = "vpn"
        private const val NOTIFICATION_ID = 1
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var tun: ParcelFileDescriptor? = null
    private var active = false
    private var dns = ""
    private var baseRx = 0L
    private var baseTx = 0L
    private var ticks = 0
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    private val tick = object : Runnable {
        override fun run() {
            if (!active) return
            val uid = Process.myUid()
            VpnBus.traffic((TrafficStats.getUidRxBytes(uid) - baseRx).coerceAtLeast(0), (TrafficStats.getUidTxBytes(uid) - baseTx).coerceAtLeast(0))
            // ядро могло остановиться само: не показываем «подключено», когда туннеля уже нет
            if (++ticks % 5 == 0) worker.execute { if (active && !Core.running()) shutdown("Подключение оборвалось. Попробуйте подключиться ещё раз.") }
            main.postDelayed(this, 1000)
        }
    }

    override fun onCreate() {
        super.onCreate()
        Core.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            worker.execute { shutdown(null) }
            return START_NOT_STICKY
        }
        // Запуск из приложения, системой (постоянный VPN) или после перезапуска процесса: настройки берём из сохранённого
        showNotification(Store.load(this)?.name)
        worker.execute { connect() }
        return START_STICKY
    }

    override fun onRevoke() {
        // человек включил другой VPN или отозвал разрешение
        worker.execute { shutdown(null) }
    }

    override fun onDestroy() {
        worker.execute { teardown() }
        worker.shutdown()
        Core.attach(null)
        if (VpnBus.state != "disconnected") VpnBus.set("disconnected")
        super.onDestroy()
    }

    private fun connect() {
        if (active) teardown()
        val saved = Store.load(this)
        if (saved == null) {
            shutdown("Нет сохранённого подключения. Откройте приложение и выберите сервер.")
            return
        }
        VpnBus.set("connecting", name = saved.name)
        try {
            Geo.ensure(this)
            dns = Core.underlyingDns(this)

            val builder = Builder()
                .setSession("AstatVPN")
                .setMtu(1500)
                .addAddress("172.19.0.2", 30)
                .addRoute("0.0.0.0", 0)
                // Адрес внутри туннеля: запросы перехватывает ядро и отправляет через VPN, провайдер их не видит.
                // IPv6 не настраиваем нарочно: Android в таком случае блокирует его целиком, и он не идёт мимо VPN.
                .addDnsServer("172.19.0.1")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
            when (saved.filter) {
                "exclude" -> saved.apps.forEach { try { builder.addDisallowedApplication(it) } catch (_: PackageManager.NameNotFoundException) {} }
                "include" -> {
                    var added = 0
                    saved.apps.forEach { try { builder.addAllowedApplication(it); added++ } catch (_: PackageManager.NameNotFoundException) {} }
                    if (added == 0) throw IllegalStateException("В списке «только выбранные приложения» нет установленных приложений")
                }
            }
            packageManager.getLaunchIntentForPackage(packageName)?.let {
                builder.setConfigureIntent(PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            }
            val pfd = builder.establish() ?: throw IllegalStateException("Нет разрешения на VPN. Откройте приложение и подключитесь заново.")
            tun = pfd

            Core.setDns(dns)
            Core.start(this, saved.config, pfd.fd)
            active = true

            val uid = Process.myUid()
            baseRx = TrafficStats.getUidRxBytes(uid)
            baseTx = TrafficStats.getUidTxBytes(uid)
            ticks = 0
            watchNetwork()
            VpnBus.set("connected", name = saved.name)
            showNotification(saved.name)
            main.post(tick)
        } catch (e: Throwable) {
            shutdown(explain(e))
        }
    }

    private fun explain(e: Throwable): String {
        val text = (e.message ?: e.toString()).take(300)
        return if (e is IllegalStateException && !text.contains("xray", true) && text.firstOrNull()?.isUpperCase() == true) text else "Не удалось запустить подключение: $text"
    }

    /** Останавливает ядро и освобождает туннель. Только из потока worker. */
    private fun teardown() {
        active = false
        main.removeCallbacks(tick)
        networkCallback?.let { cb -> try { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(cb) } catch (_: Exception) {} }
        networkCallback = null
        Core.stop()
        try { tun?.close() } catch (_: Exception) {}
        tun = null
    }

    private fun shutdown(error: String?) {
        if (VpnBus.state != "disconnected") VpnBus.set("stopping")
        teardown()
        VpnBus.set("disconnected", error = error)
        main.post {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    /** При переходе между Wi-Fi и мобильной сетью меняется DNS-сервер: без обновления ядро перестаёт находить сервер по имени. */
    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val cb = object : ConnectivityManager.NetworkCallback() {
            private fun refresh() = worker.execute {
                if (!active) return@execute
                val next = Core.underlyingDns(this@AstatVpnService)
                if (next != dns) {
                    dns = next
                    Core.setDns(next)
                }
            }
            override fun onAvailable(network: Network) = refresh()
            override fun onLost(network: Network) = refresh()
            override fun onLinkPropertiesChanged(network: Network, lp: LinkProperties) = refresh()
        }
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        try {
            cm.registerNetworkCallback(request, cb)
            networkCallback = cb
        } catch (_: Exception) {}
    }

    private fun showNotification(server: String?) {
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Подключение", NotificationManager.IMPORTANCE_LOW).apply { setShowBadge(false) })
        }
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val stop = PendingIntent.getService(this, 1, Intent(this, AstatVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val n: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentTitle("AstatVPN включён")
            .setContentText(server?.takeIf { it.isNotBlank() } ?: "Подключение")
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .addAction(0, "Отключить", stop)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }
}
