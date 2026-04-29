package ai.ironedge.salix_ai

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val WAKE_WORD_METHOD = "salix.wake_word"
    private val WAKE_WORD_EVENTS = "salix.wake_word.events"
    private val CHAT_STREAM_METHOD = "salix.chat_stream"

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ---- v7.0.0+32: ChatStreamService persistente (24/7) ---------------
        // Dart chama startPersistent UMA vez no boot do app (e BootReceiver
        // faz o mesmo apos reboot do celular). bumpStreaming/bumpIdle so
        // atualizam o texto da notif. stop() e usado apenas em logout.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHAT_STREAM_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startPersistent", "start" -> {
                        try {
                            val intent = Intent(this, ChatStreamService::class.java).apply {
                                action = ChatStreamService.ACTION_START_PERSISTENT
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("CHAT_STREAM_START_FAIL", t.message, null)
                        }
                    }
                    "bumpStreaming" -> {
                        try {
                            val intent = Intent(this, ChatStreamService::class.java).apply {
                                action = ChatStreamService.ACTION_BUMP_STREAMING
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("CHAT_STREAM_BUMP_FAIL", t.message, null)
                        }
                    }
                    "bumpIdle" -> {
                        try {
                            val intent = Intent(this, ChatStreamService::class.java).apply {
                                action = ChatStreamService.ACTION_BUMP_IDLE
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("CHAT_STREAM_BUMP_FAIL", t.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            val intent = Intent(this, ChatStreamService::class.java).apply {
                                action = ChatStreamService.ACTION_STOP
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("CHAT_STREAM_STOP_FAIL", t.message, null)
                        }
                    }
                    "status" -> {
                        result.success(mapOf(
                            "running" to ChatStreamService.running,
                            "streaming" to ChatStreamService.streaming,
                        ))
                    }
                    else -> result.notImplemented()
                }
            }

        // ---- MethodChannel: start / stop / setSensitivity / status -----------
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_WORD_METHOD)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            // v1.8.0: enable service component dynamically (manifest
                            // has android:enabled="false" by default to avoid boot
                            // crash on devices without RECORD_AUDIO).
                            try {
                                val pm = packageManager
                                val cn = ComponentName(this, WakeWordService::class.java)
                                pm.setComponentEnabledSetting(
                                    cn,
                                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                                    PackageManager.DONT_KILL_APP,
                                )
                            } catch (_: Throwable) { /* ignore — startService still works */ }

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
                    "isIgnoringBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(pm.isIgnoringBatteryOptimizations(packageName))
                        } catch (t: Throwable) {
                            result.error("BATTERY_OPT_QUERY_FAIL", t.message, null)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (!pm.isIgnoringBatteryOptimizations(packageName)) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:" + packageName)
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(mapOf("requested" to true))
                            } else {
                                result.success(mapOf("alreadyIgnoring" to true))
                            }
                        } catch (t: Throwable) {
                            result.error("BATTERY_OPT_FAIL", t.message, null)
                        }
                    }
                    "openAppDetailsSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:" + packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("APP_DETAILS_FAIL", t.message, null)
                        }
                    }
                    // v10.0.0+35: pause/resume the wake-word AudioRecord
                    // while a foreground SpeechRecognizer captures the mic.
                    // Fixes Bug 1 (Galaxy S24 Ultra mic conflict).
                    "pauseForForegroundMic" -> {
                        try {
                            WakeWordService.pausedForForeground = true
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("WAKE_PAUSE_FAIL", t.message, null)
                        }
                    }
                    "resumeAfterForegroundMic" -> {
                        try {
                            WakeWordService.pausedForForeground = false
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("WAKE_RESUME_FAIL", t.message, null)
                        }
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
