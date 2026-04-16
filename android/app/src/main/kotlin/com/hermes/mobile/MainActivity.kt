package com.hermes.mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import androidx.annotation.NonNull
import com.hermes.mobile.bridge.HermesBridgeService
import com.hermes.mobile.termux.TermuxBootstrap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val BRIDGE_CHANNEL = "com.hermes.mobile/bridge"
        private const val BOOTSTRAP_CHANNEL = "com.hermes.mobile/bootstrap"
        private const val CONFIG_CHANNEL = "com.hermes.mobile/config"
        private const val LOG_CHANNEL = "com.hermes.mobile/logs"
    }

    private var logSink: EventChannel.EventSink? = null
    private var logReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Bridge Channel ──────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BRIDGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = call.argument<String>("url") ?: ""
                        try {
                            val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
                            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_URL_FAILED", e.message, null)
                        }
                    }
                    "httpPost" -> {
                        val url = call.argument<String>("url") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        val headers = call.argument<String>("headers") ?: ""
                        val contentType = call.argument<String>("contentType") ?: "application/x-www-form-urlencoded"
                        Thread {
                            try {
                                val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                                conn.requestMethod = "POST"
                                conn.setRequestProperty("Content-Type", contentType)
                                conn.setRequestProperty("User-Agent", "HermesMobile/1.0")
                                conn.connectTimeout = 15000
                                conn.readTimeout = 15000
                                conn.instanceFollowRedirects = true

                                if (headers.isNotEmpty()) {
                                    headers.split("\n").forEach { h ->
                                        val parts = h.split(":", limit = 2)
                                        if (parts.size == 2) {
                                            conn.setRequestProperty(parts[0].trim(), parts[1].trim())
                                        }
                                    }
                                }

                                conn.doOutput = true
                                if (body.isNotEmpty()) {
                                    conn.outputStream.use { it.write(body.toByteArray()) }
                                }

                                val responseCode = conn.responseCode
                                val responseText = if (responseCode in 200..299) {
                                    conn.inputStream.bufferedReader().readText()
                                } else {
                                    conn.errorStream?.bufferedReader()?.readText() ?: ""
                                }
                                conn.disconnect()

                                val wrapped = if (responseCode in 200..299) {
                                    responseText
                                } else {
                                    val errJson = org.json.JSONObject()
                                    errJson.put("status_code", responseCode)
                                    try {
                                        errJson.put("error", org.json.JSONObject(responseText))
                                    } catch (_: Exception) {
                                        errJson.put("error", responseText)
                                    }
                                    errJson.toString()
                                }
                                runOnUiThread { result.success(wrapped) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("HTTP_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "httpGet" -> {
                        val url = call.argument<String>("url") ?: ""
                        val headers = call.argument<String>("headers") ?: ""
                        Thread {
                            try {
                                val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
                                conn.requestMethod = "GET"
                                conn.setRequestProperty("User-Agent", "HermesMobile/1.0")
                                conn.connectTimeout = 15000
                                conn.readTimeout = 15000
                                conn.instanceFollowRedirects = true

                                if (headers.isNotEmpty()) {
                                    headers.split("\n").forEach { h ->
                                        val parts = h.split(":", limit = 2)
                                        if (parts.size == 2) {
                                            conn.setRequestProperty(parts[0].trim(), parts[1].trim())
                                        }
                                    }
                                }

                                val responseCode = conn.responseCode
                                val responseText = if (responseCode in 200..299) {
                                    conn.inputStream.bufferedReader().readText()
                                } else {
                                    conn.errorStream?.bufferedReader()?.readText() ?: ""
                                }
                                conn.disconnect()

                                val wrapped = if (responseCode in 200..299) {
                                    responseText
                                } else {
                                    val errJson = org.json.JSONObject()
                                    errJson.put("status_code", responseCode)
                                    try {
                                        errJson.put("error", org.json.JSONObject(responseText))
                                    } catch (_: Exception) {
                                        errJson.put("error", responseText)
                                    }
                                    errJson.toString()
                                }
                                runOnUiThread { result.success(wrapped) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("HTTP_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "execShell" -> {
                        val command = call.argument<String>("command") ?: ""
                        Thread {
                            try {
                                val process = Runtime.getRuntime().exec(arrayOf("sh", "-c", command))
                                val stdout = process.inputStream.bufferedReader().readText()
                                val stderr = process.errorStream.bufferedReader().readText()
                                process.waitFor()
                                val output = stdout + (if (stderr.isNotEmpty()) "\n$stderr" else "")
                                runOnUiThread { result.success(if (output.length > 8000) output.substring(0, 8000) + "\n...(truncated)" else output) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("SHELL_FAILED", e.message, null) }
                            }
                        }.start()
                    }
                    "readFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        try {
                            val file = java.io.File(path)
                            if (!file.exists()) {
                                result.success("Error: File not found: $path")
                            } else {
                                val lines = file.readLines().take(500)
                                result.success(lines.mapIndexed { i, l -> "${i+1}|$l" }.joinToString("\n"))
                            }
                        } catch (e: Exception) {
                            result.success("Error reading file: ${e.message}")
                        }
                    }
                    "writeFile" -> {
                        val path = call.argument<String>("path") ?: ""
                        val content = call.argument<String>("content") ?: ""
                        try {
                            val file = java.io.File(path)
                            file.parentFile?.mkdirs()
                            file.writeText(content)
                            result.success("Written ${content.length} chars to $path")
                        } catch (e: Exception) {
                            result.success("Error writing file: ${e.message}")
                        }
                    }
                    "startBridge" -> {
                        val port = call.argument<Int>("port") ?: 18923
                        val intent = Intent(this, HermesBridgeService::class.java).apply {
                            action = HermesBridgeService.ACTION_START
                            putExtra(HermesBridgeService.EXTRA_PORT, port)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "stopBridge" -> {
                        startService(Intent(this, HermesBridgeService::class.java).apply {
                            action = HermesBridgeService.ACTION_STOP
                        })
                        result.success(true)
                    }
                    "isRunning" -> result.success(HermesBridgeService.isRunning())
                    "getPort" -> result.success(HermesBridgeService.DEFAULT_PORT)
                    "getBridgeUrl" -> result.success(HermesBridgeService.getBridgeUrl())
                    else -> result.notImplemented()
                }
            }

        // ── Bootstrap Channel ───────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, BOOTSTRAP_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBootstrapped" -> {
                        result.success(TermuxBootstrap(applicationContext).isBootstrapped)
                    }
                    "bootstrap" -> {
                        Thread {
                            try {
                                TermuxBootstrap(applicationContext).bootstrap { msg, pct ->
                                    runOnUiThread { logSink?.success(mapOf("message" to msg, "percent" to pct)) }
                                }
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("BOOTSTRAP_FAILED", e.message, null)
                            }
                        }.start()
                    }
                    "getHomesDir" -> result.success(TermuxBootstrap(applicationContext).homeDir.absolutePath)
                    else -> result.notImplemented()
                }
            }

        // ── Config Channel (API keys) ──────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONFIG_CHANNEL)
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences("hermes_config", Context.MODE_PRIVATE)
                when (call.method) {
                    "setApiKey" -> {
                        val key = call.argument<String>("key") ?: ""
                        val value = call.argument<String>("value") ?: ""
                        prefs.edit().putString(key, value).apply()
                        // Also write to .env file in Termux home
                        updateEnvFile(key, value)
                        result.success(true)
                    }
                    "getApiKey" -> {
                        val key = call.argument<String>("key") ?: ""
                        result.success(prefs.getString(key, null))
                    }
                    "setModel" -> {
                        val model = call.argument<String>("model") ?: ""
                        prefs.edit().putString("hermes_model", model).apply()
                        updateEnvFile("HERMES_MODEL", model)
                        result.success(true)
                    }
                    "getModel" -> {
                        result.success(prefs.getString("hermes_model", "gpt-4o-mini"))
                    }
                    "hasAnyApiKey" -> {
                        val hasNous = !prefs.getString("nous_api_key", null).isNullOrEmpty()
                        val hasOpenai = !prefs.getString("openai_api_key", null).isNullOrEmpty()
                        result.success(hasNous || hasOpenai)
                    }
                    else -> result.notImplemented()
                }
            }

        // ── Log Stream ─────────────────────────────────────
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LOG_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logSink = events
                    // Register broadcast receiver for bridge logs
                    logReceiver = object : BroadcastReceiver() {
                        override fun onReceive(ctx: Context?, intent: Intent?) {
                            val msg = intent?.getStringExtra("message") ?: ""
                            val pct = intent?.getIntExtra("percent", -1) ?: -1
                            events?.success(mapOf("message" to msg, "percent" to pct))
                        }
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        registerReceiver(logReceiver, IntentFilter("com.hermes.mobile.BRIDGE_LOG"),
                            Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        registerReceiver(logReceiver, IntentFilter("com.hermes.mobile.BRIDGE_LOG"))
                    }
                }
                override fun onCancel(arguments: Any?) {
                    logReceiver?.let { unregisterReceiver(it) }
                    logReceiver = null
                    logSink = null
                }
            })
    }

    private fun updateEnvFile(key: String, value: String) {
        try {
            val boot = TermuxBootstrap(applicationContext)
            val envFile = java.io.File(boot.homeDir, ".env")
            boot.homeDir.mkdirs()

            val lines = if (envFile.exists()) envFile.readLines().toMutableList() else mutableListOf()

            // Update or add the key
            var found = false
            for (i in lines.indices) {
                if (lines[i].startsWith("$key=") || lines[i].startsWith("# $key=")) {
                    lines[i] = "$key=$value"
                    found = true
                    break
                }
            }
            if (!found) {
                lines.add("$key=$value")
            }

            envFile.writeText(lines.joinToString("\n") + "\n")
        } catch (e: Exception) {
            android.util.Log.w("MainActivity", "Failed to update .env: ${e.message}")
        }
    }

    override fun onDestroy() {
        logReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        super.onDestroy()
    }
}
