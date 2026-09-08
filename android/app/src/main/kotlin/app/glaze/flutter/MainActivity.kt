package app.glaze.flutter

import android.Manifest
import android.app.WallpaperManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.net.Uri
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private val wallpaperPermissionCode = 9911

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
