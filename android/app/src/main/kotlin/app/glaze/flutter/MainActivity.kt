package app.glaze.flutter

import android.Manifest
import android.app.WallpaperManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val wallpaperPermissionCode = 9911
    private var powerSaveReceiver: BroadcastReceiver? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.glaze.flutter/system_settings"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openNotificationSettings" -> {
                    openNotificationSettings()
                    result.success(null)
                }
                "isPowerSaveMode" -> result.success(isPowerSaveMode())
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.glaze.flutter/power_save_events"
        ).setStreamHandler(powerSaveStreamHandler())

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.glaze.flutter/media_store"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "scanFile" -> scanFile(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "app.glaze.flutter/wallpaper"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getWallpaper" -> result.success(readWallpaperBytesIfPermitted())
                "hasPermission" -> result.success(hasWallpaperPermission())
                "requestPermission" -> handleRequestPermission(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun powerManager(): PowerManager? =
        getSystemService(Context.POWER_SERVICE) as? PowerManager

    private fun isPowerSaveMode(): Boolean = powerManager()?.isPowerSaveMode == true

    /// Pushes the power-save flag on every change. Polling cannot see the
    /// moment the phone flips, which is the only thing "follow the system" is
    /// about; ACTION_POWER_SAVE_MODE_CHANGED is the broadcast that can.
    private fun powerSaveStreamHandler() = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            if (events == null) return
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    events.success(isPowerSaveMode())
                }
            }
            powerSaveReceiver = receiver
            registerReceiver(
                receiver,
                IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            )
            // Seed the stream so a listener that attached after a change still
            // starts from the truth rather than from its own default.
            events.success(isPowerSaveMode())
        }

        override fun onCancel(arguments: Any?) {
            powerSaveReceiver?.let {
                try {
                    unregisterReceiver(it)
                } catch (e: IllegalArgumentException) {
                    // Already gone with the activity.
                }
            }
            powerSaveReceiver = null
        }
    }

    /// Puts a file Glaze wrote into public Downloads in front of the media
    /// scanner, so it lands in MediaStore.
    ///
    /// The system file picker reaches the Glaze folder two ways: from the
    /// device root, through `ExternalStorageProvider`, which walks the real
    /// directory and sees every file; and through the "Downloads" shortcut,
    /// through `DownloadsProvider`, which lists MediaStore rows. A file created
    /// with plain file IO may have no such row, which is why a fresh backup was
    /// invisible under the shortcut and had to be reached from the root.
    ///
    /// Answers as soon as the scan is handed off, not when it finishes: the
    /// export is already written and complete, and the caller must never be
    /// left awaiting a scanner callback that may not come. A path the scanner
    /// will not take is not an error the export should hear about either, so
    /// every outcome is a success.
    private fun scanFile(path: String?, result: MethodChannel.Result) {
        if (!path.isNullOrEmpty()) {
            try {
                // Trailing no-op listener rather than a null one: the scan
                // is fire-and-forget, and a lambda leaves no doubt about which
                // overload this is.
                MediaScannerConnection.scanFile(
                    applicationContext,
                    arrayOf(path),
                    null
                ) { _, _ -> }
            } catch (e: Exception) {
                // No MediaProvider, or a path it refuses. The file is written.
            }
        }
        result.success(null)
    }

    private fun openNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
            }
        } else {
            Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
        }

        startActivity(intent)
    }

    /// The runtime permission that gates `WallpaperManager.getDrawable()`:
    /// media-images on Android 13+, legacy external-storage below.
    private fun requiredWallpaperPermission(): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_IMAGES
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }

    private fun hasWallpaperPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, requiredWallpaperPermission()) ==
            PackageManager.PERMISSION_GRANTED

    /// Reads the wallpaper only when permission is already granted. Never
    /// prompts — the prompt is gated behind an explicit `requestPermission`.
    private fun readWallpaperBytesIfPermitted(): ByteArray? {
        if (!hasWallpaperPermission()) return null
        return readWallpaperBytes()
    }

    private fun handleRequestPermission(result: MethodChannel.Result) {
        if (hasWallpaperPermission()) {
            result.success(true)
            return
        }
        // Only one permission request can be in flight at a time.
        if (pendingPermissionResult != null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(requiredWallpaperPermission()),
            wallpaperPermissionCode
        )
    }

    /// Reads the current home-screen wallpaper as PNG bytes. Returns null on any
    /// failure (live wallpaper, missing permission, SecurityException) so the
    /// Flutter side can fall back to the plain Material You surface.
    private fun readWallpaperBytes(): ByteArray? {
        return try {
            val drawable: Drawable? = WallpaperManager.getInstance(this).drawable
            drawable?.let { drawableToPng(it) }
        } catch (e: Exception) {
            null
        }
    }

    private fun drawableToPng(drawable: Drawable): ByteArray? {
        return try {
            val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                drawable.bitmap
            } else {
                val w = drawable.intrinsicWidth.takeIf { it > 0 } ?: 1080
                val h = drawable.intrinsicHeight.takeIf { it > 0 } ?: 1920
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
                bmp
            }
            ByteArrayOutputStream().use { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                stream.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != wallpaperPermissionCode) return
        val pending = pendingPermissionResult
        pendingPermissionResult = null
        if (pending == null) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
    }
}
