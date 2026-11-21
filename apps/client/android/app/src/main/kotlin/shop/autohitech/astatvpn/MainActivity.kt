package shop.autohitech.astatvpn

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private companion object {
        const val REQUEST_VPN = 4101
        const val REQUEST_NOTIFICATIONS = 4102
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pendingPrepare: MethodChannel.Result? = null
    private var sink: EventChannel.EventSink? = null
    private val listener: (Map<String, Any?>) -> Unit = { sink?.success(it) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        EventChannel(messenger, "astat/vpn/events").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                sink = events
                VpnBus.addListener(listener)
                events.success(VpnBus.snapshot())
            }

            override fun onCancel(arguments: Any?) {
                VpnBus.removeListener(listener)
                sink = null
            }
        })

        MethodChannel(messenger, "astat/vpn").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(VpnBus.snapshot())
                "prepare" -> prepare(result)
                "start" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrEmpty()) {
                        result.error("config", "Нет конфигурации подключения", null)
                    } else {
                        Store.save(this, Store.Saved(config, call.argument<String>("name") ?: "", call.argument<String>("filter") ?: "off", call.argument<List<String>>("apps") ?: emptyList()))
                        try {
                            ContextCompat.startForegroundService(this, Intent(this, AstatVpnService::class.java).setAction(AstatVpnService.ACTION_START))
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("start", "Система не дала запустить VPN. Откройте приложение и попробуйте ещё раз.", null)
                        }
                    }
                }
                "stop" -> {
                    if (VpnBus.state != "disconnected") {
                        try { startService(Intent(this, AstatVpnService::class.java).setAction(AstatVpnService.ACTION_STOP)) } catch (_: Exception) {}
                    }
                    result.success(null)
                }
                "ping" -> {
                    val configs = call.argument<List<String>>("configs") ?: emptyList()
                    if (VpnBus.state != "disconnected") {
                        result.error("busy", "Замер задержки работает при выключенном VPN", null)
                    } else {
                        io.execute {
                            try {
                                val delays = Core.ping(this, configs)
                                main.post { result.success(delays) }
                            } catch (e: Throwable) {
                                main.post { result.error("ping", "Не удалось измерить задержку", null) }
                            }
                        }
                    }
                }
                "apps" -> io.execute {
                    val list = installedApps()
                    main.post { result.success(list) }
                }
                "openVpnSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_VPN_SETTINGS))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "deviceInfo" -> result.success(mapOf("model" to "${Build.MANUFACTURER} ${Build.MODEL}".trim(), "osVersion" to Build.VERSION.RELEASE))
                "coreVersion" -> io.execute {
                    val v = Core.version()
                    main.post { result.success(v) }
                }
                "logs" -> io.execute {
                    val text = try { Core.logs(this) } catch (_: Exception) { "" }
                    main.post { result.success(text) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            // уведомление с кнопкой «Отключить» необязательно: отказ подключению не мешает
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_NOTIFICATIONS)
        }
        val intent = try { VpnService.prepare(this) } catch (e: Exception) {
            result.error("prepare", "Система не поддерживает VPN или он запрещён на этом устройстве", null)
            return
        }
        if (intent == null) {
            result.success(true)
            return
        }
        pendingPrepare?.success(false)
        pendingPrepare = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_VPN)
        } catch (e: Exception) {
            pendingPrepare = null
            result.error("prepare", "Не удалось открыть системный запрос на VPN", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_VPN) {
            pendingPrepare?.success(resultCode == Activity.RESULT_OK)
            pendingPrepare = null
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        return pm.getInstalledApplications(0)
            .filter { it.packageName != packageName && pm.checkPermission(Manifest.permission.INTERNET, it.packageName) == PackageManager.PERMISSION_GRANTED }
            .map {
                mapOf(
                    "package" to it.packageName,
                    "label" to (pm.getApplicationLabel(it)?.toString() ?: it.packageName),
                    "system" to ((it.flags and ApplicationInfo.FLAG_SYSTEM) != 0 && pm.getLaunchIntentForPackage(it.packageName) == null),
                )
            }
    }
}
