package shop.autohitech.astatvpn

import android.os.Handler
import android.os.Looper
import java.util.concurrent.CopyOnWriteArraySet

/** Общее состояние подключения: служба пишет, экран читает. */
object VpnBus {
    @Volatile var state = "disconnected"; private set
    @Volatile var since = 0L; private set
    @Volatile var error: String? = null; private set
    @Volatile var rx = 0L; private set
    @Volatile var tx = 0L; private set
    @Volatile var name: String? = null; private set

    private val main = Handler(Looper.getMainLooper())
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

    fun snapshot(): Map<String, Any?> = mapOf("state" to state, "since" to since, "error" to error, "rx" to rx, "tx" to tx, "name" to name)

    fun addListener(l: (Map<String, Any?>) -> Unit) = listeners.add(l)
    fun removeListener(l: (Map<String, Any?>) -> Unit) = listeners.remove(l)

    @Synchronized
    fun set(state: String, name: String? = this.name, error: String? = null) {
        if (state == "connected" && this.state != "connected") since = System.currentTimeMillis()
        if (state != "connected") { since = 0; rx = 0; tx = 0 }
        this.state = state
        this.name = name
        this.error = error
        emit()
    }

    @Synchronized
    fun traffic(rx: Long, tx: Long) {
        if (state != "connected") return
        this.rx = rx
        this.tx = tx
        emit()
    }

    private fun emit() {
        val s = snapshot()
        main.post { listeners.forEach { it(s) } }
    }
}
