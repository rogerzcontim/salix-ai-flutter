package ai.ironedge.salix_ai

import android.content.Intent
import android.os.Build
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val WAKE_WORD_METHOD = "salix.wake_word"
    private val WAKE_WORD_EVENTS = "salix.wake_word.events"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---- MethodChannel: start / stop / setSensitivity / status -----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_WORD_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val intent = Intent(this, WakeWordService::class.java)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("START_FAIL", t.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            val intent = Intent(this, WakeWordService::class.java)
                            stopService(intent)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("STOP_FAIL", t.message, null)
                        }
                    }
                    "setSensitivity" -> {
                        val s = (call.argument<Double>("sensitivity") ?: 0.55).toFloat()
                        WakeWordService.sensitivity = s.coerceIn(0f, 1f)
                        result.success(true)
                    }
                    "status" -> {
                        result.success(mapOf(
                            "running"     to WakeWordService.running,
                            "lowBattery"  to WakeWordService.lowBattery,
                            "sensitivity" to WakeWordService.sensitivity.toDouble(),
                            "supported"   to true,
                            "model"       to "energy-heuristic-v1",
                        ))
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- EventChannel: detected / started / stopped / error / battery ----
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_WORD_EVENTS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    WakeWordService.sink = events
                }
                override fun onCancel(arguments: Any?) {
                    WakeWordService.sink = null
                }
            })
    }
}
