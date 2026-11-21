package shop.autohitech.astatvpn

import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.core.content.ContextCompat

/** Плитка использует последнюю конфигурацию, переданную системной VPN-службе. */
class VpnTileService : TileService() {
    private var displayedState: String? = null
    private val listener: (Map<String, Any?>) -> Unit = { updateTile() }

    override fun onStartListening() {
        super.onStartListening()
        displayedState = null
        VpnBus.addListener(listener)
        updateTile()
    }

    override fun onStopListening() {
        VpnBus.removeListener(listener)
        super.onStopListening()
    }

    override fun onDestroy() {
        VpnBus.removeListener(listener)
        super.onDestroy()
    }

    private fun updateTile() {
        val state = VpnBus.state
        if (state == displayedState) return
        val tile = qsTile ?: return
        tile.state = when (state) {
            "connected" -> Tile.STATE_ACTIVE
            "connecting", "stopping" -> Tile.STATE_UNAVAILABLE
            else -> Tile.STATE_INACTIVE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (state) {
                "connected" -> "Подключено"
                "connecting" -> "Подключение"
                "stopping" -> "Отключение"
                else -> "Отключено"
            }
        }
        tile.updateTile()
        displayedState = state
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun { toggleVpn() } else toggleVpn()
    }

    private fun toggleVpn() {
        try {
            val intent = Intent(this, AstatVpnService::class.java)
            when (VpnBus.state) {
                "connected" -> startService(intent.setAction(AstatVpnService.ACTION_STOP))
                "disconnected" -> {
                    if (VpnService.prepare(this) != null || Store.load(this) == null) {
                        openApp()
                    } else {
                        ContextCompat.startForegroundService(this, intent.setAction(AstatVpnService.ACTION_START))
                    }
                }
            }
        } catch (_: Exception) {
            openApp()
        }
    }

    @Suppress("DEPRECATION")
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        } else {
            startActivityAndCollapse(intent)
        }
    }
}
