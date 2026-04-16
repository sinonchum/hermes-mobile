package com.hermes.mobile.bridge

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.hermes.mobile.MainActivity
import com.hermes.mobile.termux.TermuxBootstrap
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service that manages the Hermes Bridge Server.
 *
 * Lifecycle:
 *   1. Bootstrap Termux environment (first launch only)
 *   2. Start Python bridge_server.py
 *   3. Keep alive with WakeLock + foreground notification
 *
 * Flutter connects to http://127.0.0.1:18923/api/ and ws://127.0.0.1:18923/ws/chat
 */
class HermesBridgeService : Service() {

    companion object {
        const val TAG = "HermesBridge"
        const val NOTIFICATION_ID = 1001
        const val CHANNEL_ID = "hermes_bridge"
        const val DEFAULT_PORT = 18923

        const val ACTION_START = "com.hermes.mobile.START_BRIDGE"
        const val ACTION_STOP = "com.hermes.mobile.STOP_BRIDGE"
        const val EXTRA_PORT = "port"

        private val running = AtomicBoolean(false)
        private var bridgeProcess: Process? = null
        private var bootstrap: TermuxBootstrap? = null

        fun isRunning(): Boolean = running.get()

        fun getBridgeUrl(): String = "http://127.0.0.1:$DEFAULT_PORT"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var port = DEFAULT_PORT

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        bootstrap = TermuxBootstrap(applicationContext)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopBridge()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                running.set(false)
                return START_NOT_STICKY
            }
            else -> {
                port = intent?.getIntExtra(EXTRA_PORT, DEFAULT_PORT) ?: DEFAULT_PORT
                startForeground(NOTIFICATION_ID, buildNotification("Starting..."))
                acquireWakeLock()
                running.set(true)

                Thread({
                    try {
                        startBridge()
                    } catch (e: Exception) {
                        Log.e(TAG, "Bridge startup failed", e)
                        updateNotification("Error: ${e.message}")
                        running.set(false)
                    }
                }, "hermes-bridge-thread").start()
            }
        }
        return START_STICKY
    }

    private fun startBridge() {
        val boot = bootstrap ?: return

        // ── Bootstrap if needed ─────────────────────────────
        if (!boot.isBootstrapped) {
            updateNotification("Setting up environment (first launch)...")
            sendLogBroadcast("Starting bootstrap...", 0)
            boot.bootstrap { msg, pct ->
                Log.i(TAG, "Bootstrap: $msg ($pct%)")
                updateNotification(msg)
                sendLogBroadcast(msg, pct)
            }
        }

        // ── Kill any existing bridge process ────────────────
        bridgeProcess?.destroyForcibly()
        bridgeProcess = null

        // ── Ensure port is free ─────────────────────────────
        killPortProcess(port)

        // ── Start bridge server ─────────────────────────────
        updateNotification("Starting bridge server...")
        sendLogBroadcast("Launching bridge server...", 92)

        // Set environment variables from shared prefs or .env
        loadApiKeys()

        bridgeProcess = boot.startBridgeServer()

        // Monitor stdout for logging
        Thread({
            val reader = BufferedReader(InputStreamReader(bridgeProcess!!.inputStream))
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                Log.d(TAG, "bridge> $line")
                // Detect ready state
                if (line!!.contains("Uvicorn running") || line!!.contains("Application startup")) {
                    updateNotification("Hermes Agent ready ✓")
                    sendLogBroadcast("Bridge server running ✓", 100)
                }
            }
        }, "bridge-stdout").start()

        // Monitor stderr
        Thread({
            val reader = BufferedReader(InputStreamReader(bridgeProcess!!.errorStream))
            var line: String?
            while (reader.readLine().also { line = it } != null) {
                Log.w(TAG, "bridge-err> $line")
            }
        }, "bridge-stderr").start()

        // Wait briefly for server to start
        Thread.sleep(2000)

        // Verify process is alive
        if (bridgeProcess?.isAlive != true) {
            val exitCode = bridgeProcess?.exitValue() ?: -1
            throw RuntimeException("Bridge server exited immediately (code $exitCode)")
        }

        updateNotification("Hermes Agent running ✓")
        Log.i(TAG, "Bridge server started on port $port (PID: ${getPid(bridgeProcess!!)})")
    }

    private fun stopBridge() {
        bridgeProcess?.let {
            Log.i(TAG, "Stopping bridge server (PID: ${getPid(it)})")
            it.destroy()
            // Give it a moment to clean up
            try {
                it.waitFor(3, java.util.concurrent.TimeUnit.SECONDS)
            } catch (_: Exception) {
                it.destroyForcibly()
            }
        }
        bridgeProcess = null
        killPortProcess(port)
        releaseWakeLock()
        Log.i(TAG, "Bridge server stopped")
    }

    private fun loadApiKeys() {
        // Read API keys from shared preferences (set by Flutter settings)
        val prefs = getSharedPreferences("hermes_config", Context.MODE_PRIVATE)

        val nousKey = prefs.getString("nous_api_key", null)
        val openaiKey = prefs.getString("openai_api_key", null)
        val model = prefs.getString("hermes_model", null)

        // Local LLM settings (PocketPal, Ollama, LM Studio)
        val localUrl = prefs.getString("local_llm_url", null)
        val localModel = prefs.getString("local_llm_model", null)
        val localKey = prefs.getString("local_llm_key", null)

        if (localUrl != null && localUrl.isNotEmpty()) {
            // Local mode — set local env vars, skip cloud keys
            System.setProperty("LOCAL_LLM_URL", localUrl)
            System.setProperty("LOCAL_LLM_MODEL", localModel ?: "local")
            System.setProperty("LOCAL_LLM_KEY", localKey ?: "not-needed")
            Log.i(TAG, "Local LLM mode: $localUrl (model: ${localModel ?: "local"})")
        } else {
            // Cloud mode
            if (nousKey != null) {
                System.setProperty("NOUS_API_KEY", nousKey)
            }
            if (openaiKey != null) {
                System.setProperty("OPENAI_API_KEY", openaiKey)
            }
        }
        if (model != null) {
            System.setProperty("HERMES_MODEL", model)
        }

        // Also read from .env file in home dir
        val envFile = bootstrap?.homeDir?.let { java.io.File(it, ".env") }
        if (envFile?.exists() == true) {
            envFile.readLines().forEach { line ->
                val trimmed = line.trim()
                if (trimmed.startsWith("#") || !trimmed.contains("=")) return@forEach
                val parts = trimmed.split("=", limit = 2)
                if (parts.size == 2) {
                    val key = parts[0].trim()
                    val value = parts[1].trim().removeSurrounding("\"").removeSurrounding("'")
                    if (value.isNotEmpty()) {
                        System.setProperty(key, value)
                    }
                }
            }
        }
    }

    private fun killPortProcess(port: Int) {
        try {
            Runtime.getRuntime().exec(arrayOf("sh", "-c", "kill \$(lsof -t -i:$port) 2>/dev/null")).waitFor()
        } catch (_: Exception) {}
    }

    private fun getPid(process: Process): Long {
        return try {
            val pidField = process.javaClass.getDeclaredField("pid")
            pidField.isAccessible = true
            pidField.getLong(process)
        } catch (_: Exception) {
            -1
        }
    }

    private fun sendLogBroadcast(message: String, percent: Int) {
        // Send via local broadcast so Flutter EventChannel can pick it up
        val intent = Intent("com.hermes.mobile.BRIDGE_LOG").apply {
            putExtra("message", message)
            putExtra("percent", percent)
        }
        sendBroadcast(intent)
    }

    // ── Notification ────────────────────────────────────────
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Hermes Agent",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Hermes Agent bridge server"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Stop action
        val stopIntent = Intent(this, HermesBridgeService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hermes Agent")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPending)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun acquireWakeLock() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "Hermes::BridgeWakeLock"
        ).apply { acquire(24 * 60 * 60 * 1000L) }
    }

    private fun releaseWakeLock() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    override fun onDestroy() {
        stopBridge()
        super.onDestroy()
    }
}
