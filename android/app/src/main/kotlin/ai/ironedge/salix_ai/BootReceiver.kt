package ai.ironedge.salix_ai

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * v7.0.0+32 — BootReceiver
 *
 * Recebe BOOT_COMPLETED + LOCKED_BOOT_COMPLETED + MY_PACKAGE_REPLACED
 * (Android dispara este ultimo quando o usuario instala uma nova versao
 * por cima) e re-inicia o ChatStreamService em modo persistente.
 *
 * Sem isso, apos um reboot do telefone o usuario teria que abrir o app
 * uma vez para o servico voltar a rodar — exatamente o sintoma que Roger
 * relatou ("tem que permanecer ativo em segundo plano direto").
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "SalixBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        Log.i(TAG, "received $action")
        when (action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                try {
                    val svc = Intent(context, ChatStreamService::class.java).apply {
                        this.action = ChatStreamService.ACTION_START_PERSISTENT
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        context.startForegroundService(svc)
                    } else {
                        context.startService(svc)
                    }
                    Log.i(TAG, "ChatStreamService persistent kicked")
                } catch (t: Throwable) {
                    Log.w(TAG, "failed to start ChatStreamService: ${t.message}")
                }
            }
            else -> { /* ignore */ }
        }
    }
}
