package ai.ironedge.salix_ai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * v7.0.0+32 — ChatStreamService PERSISTENTE
 *
 * Bug Roger 29/abr: mesmo com v6, o app ainda morria ao trancar a tela
 * porque o FG service so subia durante _send(). Em v7 ele fica vivo
 * 24/7, com notif de baixa importancia "SALIX ativa em segundo plano".
 *
 * Mudancas v6 -> v7:
 *   1. onStartCommand retorna START_STICKY (era START_NOT_STICKY) — se o
 *      OS matar por OOM, o sistema vai recriar.
 *   2. Acoes:
 *        ACTION_START_PERSISTENT -> sobe FG, notif idle.
 *        ACTION_BUMP_STREAMING   -> atualiza notif "SALIX esta respondendo...".
 *        ACTION_BUMP_IDLE        -> volta para "SALIX ativa em segundo plano".
 *        ACTION_STOP             -> derruba (so logout/debug).
 *   3. WakeLock e renovado por Handler.postDelayed a cada 9 minutos
 *      (release+acquire 10min) ao inves de timeout unico — assim a CPU
 *      nao dorme em sessoes longas.
 *   4. onTaskRemoved: agenda restart por intent atrasado para o servico
 *      voltar mesmo se user dar swipe out na app.
 *   5. BootReceiver (separado) chama ACTION_START_PERSISTENT no boot.
 *
 * Coexiste com WakeWordService (services separados, channels separados,
 * locks separados, foregroundServiceType separados). Nao interfere no
 * Samsung battery opt do v4.1.0+29.
 */
class ChatStreamService : Service() {

    companion object {
        const val CHANNEL_ID  = "salix_chat_stream_v7"
        const val NOTIF_ID    = 4282
        const val ACTION_START_PERSISTENT = "ai.ironedge.salix_ai.CHAT_STREAM_START_PERSISTENT"
        const val ACTION_BUMP_STREAMING   = "ai.ironedge.salix_ai.CHAT_STREAM_BUMP_STREAMING"
        const val ACTION_BUMP_IDLE        = "ai.ironedge.salix_ai.CHAT_STREAM_BUMP_IDLE"
        const val ACTION_STOP             = "ai.ironedge.salix_ai.CHAT_STREAM_STOP"

        private const val TAG = "SalixChatStream"

        // WakeLock renovado a cada 9min (lock 10min); evita Samsung StrictMode.
        private const val WAKELOCK_HOLD_MS   = 10L * 60L * 1000L
        private const val WAKELOCK_RENEW_MS  =  9L * 60L * 1000L

        @Volatile var running: Boolean = false
        @Volatile var streaming: Boolean = false
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val renewRunnable = object : Runnable {
        override fun run() {
            renewWakeLock()
            mainHandler.postDelayed(this, WAKELOCK_RENEW_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        // Sempre primeiro: chamar startForeground em <5s para satisfazer SLA.
        // Mesmo que a acao seja STOP, fazemos startForeground para nao tomar
        // ForegroundServiceDidNotStartInTimeException.
        try {
            val notif = buildNotification(currentNotifText())
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIF_ID, notif)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "startForeground failed: ${t.javaClass.simpleName}: ${t.message}")
            // Mesmo se falhar, tentamos seguir; se OS matar a gente, START_STICKY
            // recria.
        }

        when (action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForegroundCompat()
                running = false
                streaming = false
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_BUMP_STREAMING -> {
                streaming = true
                refreshNotification()
                ensureLocks()
                return START_STICKY
            }
            ACTION_BUMP_IDLE -> {
                streaming = false
                refreshNotification()
                // Em idle a gente mantem locks (CPU + WiFi) leves: WiFi liberamos,
                // wakelock continua para garantir que processos em background
                // (resume_partial, retries de upload) sigam vivos.
                releaseWifiLock()
                return START_STICKY
            }
            else -> {
                // ACTION_START_PERSISTENT ou intent sem acao (boot receiver, primeira
                // chamada, restart pelo OS). Sobe locks e fica idle.
                ensureLocks()
                refreshNotification()
                running = true
                Log.i(TAG, "ChatStreamService persistent started; streaming=$streaming")
                return START_STICKY
            }
        }
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // User deu swipe-out no app. Agendamos restart imediato para
        // o servico voltar ao FG. NAO usamos AlarmManager porque queremos
        // resposta em <500ms — basta um startService imediato.
        try {
            val restart = Intent(applicationContext, ChatStreamService::class.java).apply {
                action = ACTION_START_PERSISTENT
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(restart)
            } else {
                applicationContext.startService(restart)
            }
            Log.i(TAG, "onTaskRemoved -> ChatStreamService respawned")
        } catch (t: Throwable) {
            Log.w(TAG, "respawn after onTaskRemoved failed: ${t.message}")
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        streaming = false
        try { mainHandler.removeCallbacks(renewRunnable) } catch (_: Throwable) {}
        releaseLocks()
        Log.i(TAG, "ChatStreamService destroyed")
        super.onDestroy()
    }

    // -------------------------------------------------------------------------
    // Locks
    // -------------------------------------------------------------------------

    private fun ensureLocks() {
        if (wakeLock == null) {
            try {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "salix:chat_stream_v7").apply {
                    setReferenceCounted(false)
                    acquire(WAKELOCK_HOLD_MS)
                }
                mainHandler.removeCallbacks(renewRunnable)
                mainHandler.postDelayed(renewRunnable, WAKELOCK_RENEW_MS)
            } catch (t: Throwable) {
                Log.w(TAG, "wakeLock acquire failed: ${t.message}")
                wakeLock = null
            }
        }
        if (streaming && wifiLock == null) {
            try {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "salix:chat_stream_v7:wifi").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (t: Throwable) {
                Log.w(TAG, "wifiLock acquire failed: ${t.message}")
                wifiLock = null
            }
        }
    }

    private fun renewWakeLock() {
        try {
            val wl = wakeLock
            if (wl != null) {
                if (wl.isHeld) try { wl.release() } catch (_: Throwable) {}
            }
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "salix:chat_stream_v7").apply {
                setReferenceCounted(false)
                acquire(WAKELOCK_HOLD_MS)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wakeLock renew failed: ${t.message}")
        }
    }

    private fun releaseLocks() {
        try { wakeLock?.release() } catch (_: Throwable) {}
        wakeLock = null
        releaseWifiLock()
        try { mainHandler.removeCallbacks(renewRunnable) } catch (_: Throwable) {}
    }

    private fun releaseWifiLock() {
        try { wifiLock?.release() } catch (_: Throwable) {}
        wifiLock = null
    }

    // -------------------------------------------------------------------------
    // Notification helpers
    // -------------------------------------------------------------------------

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "SALIX em segundo plano",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "SALIX permanece ativa em segundo plano para responder mesmo com a tela bloqueada."
                    setShowBadge(false)
                    enableVibration(false)
                    setSound(null, null)
                }
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun currentNotifText(): String =
        if (streaming) "SALIX está respondendo…" else "SALIX ativa em segundo plano"

    private fun refreshNotification() {
        try {
            val notif = buildNotification(currentNotifText())
            val nm = getSystemService(NotificationManager::class.java)
            nm?.notify(NOTIF_ID, notif)
        } catch (t: Throwable) {
            Log.w(TAG, "refreshNotification failed: ${t.message}")
        }
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SALIX AI")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(openPending)
            .build()
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }
}
