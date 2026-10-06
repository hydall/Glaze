package app.glaze.flutter

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter

/// Crash evidence that only the platform has. The Dart side reads it on the
/// next launch, after the process that crashed is gone.
object CrashDiagnostics {
    private const val JAVA_CRASH_FILE = "glaze_java_crash.txt"
    private const val MAX_TRACE_CHARS = 200_000

    @Volatile
    private var handlerInstalled = false

    /// Writes an uncaught JVM exception to a file before handing it on to the
    /// previous handler, which still kills the process as before. Dart never
    /// sees these: a plugin throwing on the main thread takes the app down
    /// before the engine can report anything.
    fun installJavaCrashHandler(context: Context) {
        if (handlerInstalled) return
        handlerInstalled = true
        val appContext = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val trace = StringWriter().also { error.printStackTrace(PrintWriter(it)) }
                File(appContext.filesDir, JAVA_CRASH_FILE).writeText(
                    "Thread: ${thread.name}\nTime: ${System.currentTimeMillis()}\n\n$trace"
                )
            } catch (e: Throwable) {
                // Nothing left to report it with.
            }
            previous?.uncaughtException(thread, error)
        }
    }

    fun takeJavaCrash(context: Context): String? {
        val file = File(context.filesDir, JAVA_CRASH_FILE)
        if (!file.exists()) return null
        return try {
            file.readText().also { file.delete() }
        } catch (e: Exception) {
            null
        }
    }

    /// The most recent exit of this package — the previous run, since the
    /// current one is still alive.
    fun lastExit(context: Context): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = am.getHistoricalProcessExitReasons(context.packageName, 0, 1)
                .firstOrNull() ?: return null
            mapOf(
                "reason" to reasonName(info.reason),
                "description" to info.description,
                "timestamp" to info.timestamp,
                "importance" to info.importance,
                "status" to info.status,
                "pss" to info.pss.toInt(),
                "rss" to info.rss.toInt(),
                "trace" to readTrace(info),
            )
        } catch (e: Exception) {
            null
        }
    }

    fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "release" to Build.VERSION.RELEASE,
        "sdk" to Build.VERSION.SDK_INT,
        "abis" to Build.SUPPORTED_ABIS.joinToString(","),
    )

    /// ANR traces are text; a native crash's trace is a binary tombstone that
    /// would only be noise in a text report.
    private fun readTrace(info: ApplicationExitInfo): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        if (info.reason != ApplicationExitInfo.REASON_ANR) return null
        return try {
            info.traceInputStream?.bufferedReader()?.use { reader ->
                val buffer = CharArray(MAX_TRACE_CHARS)
                val read = reader.read(buffer)
                if (read <= 0) null else String(buffer, 0, read)
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        // Added in Android 14 (34); spelled as literals so compileSdk does not
        // have to know them.
        13 -> "FREEZER"
        14 -> "PACKAGE_STATE_CHANGE"
        15 -> "PACKAGE_UPDATED"
        else -> "UNKNOWN($reason)"
    }
}
