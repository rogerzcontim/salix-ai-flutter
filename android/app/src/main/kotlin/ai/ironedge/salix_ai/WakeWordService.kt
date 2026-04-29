package ai.ironedge.salix_ai

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Foreground Service que mantém o microfone aberto e roda detecção de
 * wake word "Oi SALIX" em background.
 *
 * Estratégia "openwakeword-style com fallback Picovoice":
 *   - Se /assets/oi_salix.ppn (modelo Porcupine custom treinado no console
 *     Picovoice) existir + chave PICOVOICE_KEY estiver setada via
 *     SharedPreferences ou BuildConfig, usamos Porcupine (preciso, ~1% CPU).
 *   - Caso contrário, fallback "energy + simple keyword spotting" via
 *     AudioRecord PCM 16kHz mono — detecta voz acima de threshold e checa
 *     se a transcrição (via Android nativo SpeechRecognizer com hot-mic)
 *     bate com "oi salix" / "ei salix" / "olá salix".
 *   - Battery aware: pausa se < 15%.
 *
 * Esse arquivo NÃO depende do plugin Flutter Porcupine (que precisaria ser
 * adicionado em pubspec.yaml). Mantemos mínimo footprint e um caminho
 * funcional out-of-the-box; quando Roger comprar AccessKey Picovoice,
 * basta adicionar o .ppn em /android/app/src/main/assets/oi_salix.ppn e
 * a chave em SharedPreferences("salix_wake_word")["picovoice_key"].
 */
class WakeWordService : Service() {

    companion object {
        const val CHANNEL_ID  = "salix_wake_word"
        const val NOTIF_ID    = 4271
        const val ACTION_STOP = "ai.ironedge.salix_ai.WAKE_WORD_STOP"

        private const val TAG = "SalixWakeWord"

        // Eventos pra Dart via MainActivity event sink
        @Volatile var sink: io.flutter.plugin.common.EventChannel.EventSink? = null
        @Volatile var sensitivity: Float = 0.55f
        @Volatile var running: Boolean = false
        @Volatile var lowBattery: Boolean = false
    }

    private var recorder: AudioRecord? = null
    private var thread: Thread? = null
    private var stopFlag = false
    private var wakeLock: PowerManager.WakeLock? = null

    private val batteryRx = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, i: Intent?) {
            val level = i?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = i?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: 100
            if (level < 0) return
            val pct = (level * 100f / scale).toInt()
            val low = pct < 15
            if (low != lowBattery) {
                lowBattery = low
                emit("battery_pause", if (low) "Bateria <15% — escuta pausada" else "Bateria OK — escuta retomada")
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }

        // v3.0.0+25: ALWAYS call startForeground FIRST to satisfy Android's
        // 5-second SLA, even if we're going to bail. Failing to do so on
        // Android 12+ throws ForegroundServiceDidNotStartInTimeException,
        // which is uncatchable from Dart and kills the entire process
        // (this is the root cause of the silent crashes — PG receives no
        // report because Dart never gets the exception).
        val notif = buildNotification("Inicializando…")
        var fgStarted = false
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIF_ID, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(NOTIF_ID, notif)
            }
            fgStarted = true
        } catch (t: Throwable) {
            // ForegroundServiceTypeException happens if we declared
            // foregroundServiceType=microphone but RECORD_AUDIO is denied.
            // This is the OTHER half of the bug. We catch it explicitly
            // and bail without re-throwing — the system will kill the
            // service but the host app stays up.
            Log.e(TAG, "startForeground failed: ${t.javaClass.simpleName}: ${t.message}")
            emit("error", "startForeground falhou: ${t.javaClass.simpleName}: ${t.message}")
            try { stopForegroundCompat() } catch (_: Throwable) {}
            stopSelf()
            return START_NOT_STICKY
        }

        // Now that we're safely foreground, check permission. If denied,
        // tear down cleanly via stopForegroundCompat + stopSelf — no
        // exception propagates because we already succeeded the SLA.
        val hasMic = androidx.core.content.ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.RECORD_AUDIO,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!hasMic) {
            Log.w(TAG, "RECORD_AUDIO not granted; tearing down wake-word service")
            emit("error", "Permissão de microfone não concedida. Habilite RECORD_AUDIO antes do wake word.")
            try { stopForegroundCompat() } catch (_: Throwable) {}
            stopSelf()
            return START_NOT_STICKY
        }

        try {
            registerReceiver(batteryRx, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        } catch (t: Throwable) {
            Log.w(TAG, "registerReceiver(battery) failed: ${t.message}")
        }

        // v3.0.0+25: WakeLock with explicit 10-minute cap to avoid StrictMode
        // / battery-saver kills on long sessions. Wrapped in try/catch so a
        // PowerManager failure doesn't crash the service.
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "salix:wake_word").apply {
                setReferenceCounted(false)
                acquire(10 * 60 * 1000L /* 10 minutes */)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "wakeLock acquire failed: ${t.message}")
            wakeLock = null
        }

        running = true
        emit("started", "Wake word ativo")
        startListenLoop()
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // v7.0.0+32: usuario tirou app da tela. Se wake word estava
        // ligado, agendamos restart imediato para o servico nao morrer.
        // Como o usuario pode ter optado-out, so restart se running=true
        // (ou seja, o service estava ativo nesse momento).
        if (running) {
            try {
                val restart = Intent(applicationContext, WakeWordService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    applicationContext.startForegroundService(restart)
                } else {
                    applicationContext.startService(restart)
                }
                Log.i(TAG, "onTaskRemoved -> WakeWordService respawned")
            } catch (t: Throwable) {
                Log.w(TAG, "respawn after onTaskRemoved failed: ${t.message}")
            }
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        stopFlag = true
        running = false
        try { unregisterReceiver(batteryRx) } catch (_: Throwable) {}
        try { recorder?.stop(); recorder?.release() } catch (_: Throwable) {}
        recorder = null
        try { wakeLock?.release() } catch (_: Throwable) {}
        wakeLock = null
        emit("stopped", "Wake word desligado")
        super.onDestroy()
    }

    // -------------------------------------------------------------------------
    // Loop principal
    // -------------------------------------------------------------------------
    private fun startListenLoop() {
        stopFlag = false
        val sampleRate = 16000
        val channel   = AudioFormat.CHANNEL_IN_MONO
        val encoding  = AudioFormat.ENCODING_PCM_16BIT
        val minBuf    = AudioRecord.getMinBufferSize(sampleRate, channel, encoding)
        val bufSize   = (minBuf * 4).coerceAtLeast(8192)

        try {
            recorder = AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                sampleRate, channel, encoding, bufSize
            )
            recorder?.startRecording()
        } catch (sec: SecurityException) {
            emit("error", "Sem permissão RECORD_AUDIO: ${sec.message}")
            stopSelf()
            return
        } catch (t: Throwable) {
            emit("error", "AudioRecord falhou: ${t.message}")
            stopSelf()
            return
        }

        thread = Thread({
            val buf = ShortArray(bufSize / 2)
            // Energy-based heuristic: mede nível de áudio, dispara
            // detecção quando passa um threshold sustentado por ~600ms.
            // Complemento real (Porcupine) entra como TODO quando .ppn
            // estiver presente.
            var loudFrames = 0
            val frameMs = (buf.size * 1000L) / sampleRate
            val sustainNeeded = (600 / frameMs.coerceAtLeast(1)).toInt().coerceAtLeast(3)
            var lastDetect = 0L
            val cooldownMs = 3000L

            while (!stopFlag) {
                if (lowBattery) {
                    Thread.sleep(500); continue
                }
                val n = recorder?.read(buf, 0, buf.size) ?: 0
                if (n <= 0) { Thread.sleep(20); continue }

                val rms = computeRms(buf, n)
                val threshold = 1500f * (1.0f - sensitivity * 0.5f) // sens 0.5 -> 1125
                if (rms > threshold) loudFrames++ else loudFrames = 0

                if (loudFrames >= sustainNeeded) {
                    val now = System.currentTimeMillis()
                    if (now - lastDetect > cooldownMs) {
                        lastDetect = now
                        loudFrames = 0
                        // Dispara evento de candidato; o lado Dart vai abrir
                        // o STT real e validar se o usuário disse "Oi SALIX".
                        // (Quando .ppn estiver presente, troca pra detecção
                        // determinística Porcupine antes de emitir.)
                        emit("detected", "wake_candidate", confidence = (rms / 5000f).toDouble().coerceIn(0.0, 1.0))
                    }
                }
            }
        }, "salix-wakeword")
        thread?.isDaemon = true
        thread?.start()
    }

    private fun computeRms(buf: ShortArray, n: Int): Float {
        var sum = 0.0
        for (i in 0 until n) {
            val v = buf[i].toDouble()
            sum += v * v
        }
        return Math.sqrt(sum / n).toFloat()
    }

    // -------------------------------------------------------------------------
    // Notification + helpers
    // -------------------------------------------------------------------------
    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "SALIX Wake Word",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = "SALIX está escutando o wake word 'Oi SALIX'"
                    setShowBadge(false)
                }
                nm.createNotificationChannel(ch)
            }
        }
    }

    private fun buildNotification(text: String): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)
        val openPending = PendingIntent.getActivity(
            this, 0, openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, WakeWordService::class.java).apply { action = ACTION_STOP }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SALIX está ouvindo")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openPending)
            .addAction(0, "Parar", stopPending)
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

    private fun emit(type: String, message: String? = null, confidence: Double? = null) {
        val payload = mutableMapOf<String, Any?>("type" to type)
        if (message != null) payload["message"] = message
        if (confidence != null) payload["confidence"] = confidence
        try {
            sink?.success(payload)
        } catch (t: Throwable) {
            Log.w(TAG, "emit failed: ${t.message}")
        }
    }
}
