package com.hermes.mobile.termux

import android.content.Context
import android.util.Log
import java.io.*
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Termux Bootstrap — downloads and extracts official Termux bootstrap,
 * installs Python + dependencies, copies bridge server.
 *
 * Uses official termux-packages bootstrap releases.
 */
class TermuxBootstrap(private val context: Context) {

    companion object {
        private const val TAG = "TermuxBootstrap"

        // Official Termux bootstrap (latest 2026-04-12, 29MB)
        private const val BOOTSTRAP_URL =
            "https://github.com/termux/termux-packages/releases/download/bootstrap-2026.04.12-r1%2Bapt.android-7/bootstrap-aarch64.zip"
        private const val BOOTSTRAP_X86_URL =
            "https://github.com/termux/termux-packages/releases/download/bootstrap-2026.04.12-r1%2Bapt.android-7/bootstrap-x86_64.zip"

        private const val PKG = "com.hermes.mobile"
    }

    // ── Directories ─────────────────────────────────────────
    val prefixDir: File get() = File(context.filesDir, "usr")
    val homeDir: File get() = File(context.filesDir, "home")
    val binDir: File get() = File(prefixDir, "bin")
    val bashBin: File get() = File(binDir, "bash")
    val pythonBin: File get() = File(binDir, "python")
    val statusFile: File get() = File(context.filesDir, ".bootstrap_done")
    val bridgeScript: File get() = File(homeDir, "bridge_server.py")

    val isBootstrapped: Boolean
        get() = statusFile.exists() && prefixDir.exists() && bashBin.exists()

    /**
     * Full bootstrap. Call from background thread.
     * @param progress (message, percent 0-100)
     */
    fun bootstrap(progress: (String, Int) -> Unit) {
        if (isBootstrapped) {
            progress("Environment ready ✓", 100)
            return
        }

        // Step 1: Download
        progress("Downloading Termux environment (29MB)...", 3)
        val zipFile = File(context.cacheDir, "termux-bootstrap.zip")
        downloadBootstrap(zipFile, progress)

        // Step 2: Extract
        progress("Extracting rootfs...", 30)
        extractZip(zipFile, context.filesDir, progress)
        zipFile.delete()

        // Step 3: Permissions
        progress("Configuring permissions...", 55)
        fixPermissions()

        // Step 4: Write bridge server script to assets → home dir
        progress("Installing bridge server...", 58)
        copyBridgeServer()

        // Step 5: Install Python + deps via apt
        progress("Installing Python & dependencies (this takes a few minutes)...", 60)
        installPython(progress)

        // Step 6: Copy API key config
        progress("Configuring API access...", 90)
        copyApiKeyConfig()

        // Done
        progress("Bootstrap complete ✓", 100)
        statusFile.createNewFile()
        Log.i(TAG, "Bootstrap completed successfully")
    }

    private fun downloadBootstrap(target: File, progress: (String, Int) -> Unit) {
        val url = if (isX86()) BOOTSTRAP_X86_URL else BOOTSTRAP_URL
        Log.i(TAG, "Downloading from: $url")

        target.parentFile?.mkdirs()
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.setRequestProperty("User-Agent", "HermesMobile/1.0")
        conn.connectTimeout = 30000
        conn.readTimeout = 300000  // 5 min for 29MB
        conn.instanceFollowRedirects = true

        try {
            conn.connect()
            val code = conn.responseCode
            if (code != 200) {
                throw IOException("HTTP $code: ${conn.responseMessage}")
            }

            val total = conn.contentLength.toLong()
            var downloaded = 0L
            val buffer = ByteArray(32768)  // 32KB buffer

            conn.inputStream.use { input ->
                FileOutputStream(target).use { output ->
                    var bytesRead: Int
                    while (input.read(buffer).also { bytesRead = it } != -1) {
                        output.write(buffer, 0, bytesRead)
                        downloaded += bytesRead
                        if (total > 0) {
                            val pct = 3 + (downloaded * 27 / total).toInt()
                            progress("Downloading... ${downloaded / 1024 / 1024}MB / ${total / 1024 / 1024}MB", pct)
                        }
                    }
                }
            }
            Log.i(TAG, "Downloaded ${downloaded / 1024 / 1024}MB")
        } finally {
            conn.disconnect()
        }
    }

    private fun extractZip(zipFile: File, destDir: File, progress: (String, Int) -> Unit) {
        destDir.mkdirs()
        var count = 0

        ZipInputStream(BufferedInputStream(FileInputStream(zipFile), 65536)).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                val e = entry
                val outFile = File(destDir, e.name)

                // Security: prevent path traversal
                if (!outFile.canonicalPath.startsWith(destDir.canonicalPath)) {
                    Log.w(TAG, "Skipping path traversal: ${e.name}")
                    entry = zis.nextEntry
                    continue
                }

                if (e.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos ->
                        zis.copyTo(fos)
                    }
                }
                count++
                if (count % 500 == 0) {
                    progress("Extracting... $count files", 30 + (count / 200).coerceAtMost(25))
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
        Log.i(TAG, "Extracted $count entries")
    }

    private fun fixPermissions() {
        val dirs = listOf(
            File(context.filesDir, "usr/bin"),
            File(context.filesDir, "usr/libexec"),
            File(context.filesDir, "usr/lib/apt/methods"),
            File(context.filesDir, "usr/libexec/proot"),
        )
        for (dir in dirs) {
            if (dir.exists()) {
                dir.listFiles()?.forEach { f ->
                    if (f.isFile) f.setExecutable(true, false)
                }
            }
        }
        // Critical binaries
        listOf("bash", "sh", "env", "proot").forEach { name ->
            File(binDir, name).setExecutable(true, false)
        }
    }

    private fun copyBridgeServer() {
        homeDir.mkdirs()
        // Copy from APK assets
        try {
            context.assets.open("bridge_server.py").use { input ->
                FileOutputStream(bridgeScript).use { output ->
                    input.copyTo(output)
                }
            }
            Log.i(TAG, "Bridge server copied to ${bridgeScript.absolutePath}")
        } catch (e: Exception) {
            Log.w(TAG, "Could not copy bridge_server.py from assets: ${e.message}")
            // Create minimal fallback
            bridgeScript.writeText("""
                import http.server, json, subprocess, sys, os
                class H(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        if self.path=='/api/health':
                            self.send_response(200); self.end_headers()
                            self.wfile.write(json.dumps({"status":"ok"}).encode())
                    def do_POST(self):
                        l=int(self.headers.get('Content-Length',0))
                        d=json.loads(self.rfile.read(l))
                        self.send_response(200); self.end_headers()
                        self.wfile.write(json.dumps({"role":"assistant","content":"Bridge is running but dependencies not installed. Run: pip install fastapi uvicorn openai"}).encode())
                    def log_message(self,*a): pass
                http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
            """.trimIndent())
        }
    }

    private fun installPython(progress: (String, Int) -> Unit) {
        // Script to run inside the Termux environment
        val installScript = File(homeDir, "install_deps.sh")
        installScript.writeText("""
            #!/data/data/$PKG/files/usr/bin/bash
            set -e
            export PREFIX="/data/data/$PKG/files/usr"
            export HOME="/data/data/$PKG/files/home"
            export PATH="${'$'}PREFIX/bin:${'$'}PATH"
            export LANG="en_US.UTF-8"
            export TMPDIR="/data/data/$PKG/cache"
            export DEBIAN_FRONTEND=noninteractive

            echo "[1/4] Updating package lists..."
            apt update -y 2>&1 | tail -3

            echo "[2/4] Installing Python..."
            apt install -y python openssl libffi libxml2 libxslt 2>&1 | tail -3

            echo "[3/4] Upgrading pip..."
            python -m pip install --upgrade pip --break-system-packages 2>&1 | tail -3

            echo "[4/4] Installing dependencies..."
            python -m pip install fastapi uvicorn websockets openai lxml --break-system-packages 2>&1 | tail -3

            echo "Dependencies installed ✓"
        """.trimIndent())
        installScript.setExecutable(true, false)

        val env = buildEnvMap()
        val pb = ProcessBuilder(bashBin.absolutePath, installScript.absolutePath)
            .directory(homeDir)
            .redirectErrorStream(true)
        pb.environment().putAll(env)

        progress("Running apt update + install Python...", 65)

        val process = pb.start()
        val reader = process.inputStream.bufferedReader()
        var line: String?
        while (reader.readLine().also { line = it } != null) {
            Log.d(TAG, "install> $line")
            when {
                line!!.contains("Updating") -> progress("Updating package lists...", 65)
                line!!.contains("Installing Python") -> progress("Installing Python...", 70)
                line!!.contains("Upgrading pip") -> progress("Upgrading pip...", 78)
                line!!.contains("Installing dependencies") -> progress("Installing fastapi, openai...", 82)
                line!!.contains("installed") -> progress("Dependencies ready ✓", 88)
            }
        }

        val exitCode = process.waitFor()
        if (exitCode != 0) {
            Log.e(TAG, "Install script failed with exit code $exitCode")
            throw RuntimeException("Dependency installation failed (exit $exitCode)")
        }
    }

    private fun copyApiKeyConfig() {
        // Create a .env file if NOUS_API_KEY is set in Android system props or shared prefs
        val envFile = File(homeDir, ".env")
        if (!envFile.exists()) {
            envFile.writeText("""
                # Hermes Bridge API Configuration
                # Set your API key here:
                # NOUS_API_KEY=your_key_here
                # OPENAI_API_KEY=your_key_here
                HERMES_MODEL=nousresearch/hermes-3-llama-3.1-405b
                BRIDGE_PORT=18923
            """.trimIndent())
        }
    }

    /**
     * Start the bridge server. Returns the Process handle.
     */
    fun startBridgeServer(): Process {
        val env = buildEnvMap()
        val pb = ProcessBuilder(
            pythonBin.absolutePath,
            bridgeScript.absolutePath,
        )
            .directory(homeDir)
            .redirectErrorStream(true)
        pb.environment().putAll(env)

        Log.i(TAG, "Starting bridge server...")
        return pb.start()
    }

    fun buildEnv(): Array<String> {
        return buildEnvMap().map { "${it.key}=${it.value}" }.toTypedArray()
    }

    fun buildEnvMap(): Map<String, String> {
        return mapOf(
            "PREFIX" to prefixDir.absolutePath,
            "HOME" to homeDir.absolutePath,
            "PATH" to "${prefixDir.absolutePath}/bin:/system/bin:/system/xbin",
            "LANG" to "en_US.UTF-8",
            "LC_ALL" to "en_US.UTF-8",
            "TMPDIR" to context.cacheDir.absolutePath,
            "HERMES_HOME" to "${homeDir.absolutePath}/.hermes",
            "TERM" to "xterm-256color",
            "SHELL" to bashBin.absolutePath,
            "ANDROID_DATA" to "/data",
            "ANDROID_ROOT" to "/system",
            "EXTERNAL_STORAGE" to "/sdcard",
        )
    }

    private fun isX86(): Boolean {
        val abi = android.os.Build.SUPPORTED_ABIS?.firstOrNull() ?: ""
        return abi.startsWith("x86")
    }
}
