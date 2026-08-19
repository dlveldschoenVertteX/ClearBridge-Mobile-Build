package com.clearbridge.captureharness

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraExtensionCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

// Streams GAME_ROTATION_VECTOR as a normalized [x, y, z, w] quaternion over
// the "clearbridge/orientation" EventChannel -- mac_capture's
// DeviceOrientationService reads this channel by that exact name (it's the
// package's contract with the host app, not specific to ClearBridge), and
// without it the left/top/right capture positions never fire. Copied
// verbatim from the main app's MainActivity.kt.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "clearbridge/orientation")
            .setStreamHandler(OrientationStreamHandler(applicationContext))

        // Lens-probe diagnostic (2026-08-19): CTO asked whether this
        // device's stock-camera "Macro" mode (a distinct mode tile, not a
        // toggle inside Photo mode -- screenshot confirmed) is a real,
        // separate hardware lens ClearBridge could use, and if so which of
        // the enumerated camera IDs it actually is. `getCameraLensInfo` is
        // copied verbatim from clearbridge_beta's own MainActivity.kt (same
        // read-only CameraCharacteristics query, never opens a session) so
        // the probe screen can label each camera by its real focal length/
        // sensor size -- the strongest existing real evidence (camera "2":
        // 2.37mm focal length, 3.92x2.94mm sensor, smallest/shortest of the
        // four) already points at a likely macro sensor. `getCameraExtensionSupport`
        // is new: Android's Camera2 Extensions API (API 31+) lets a device
        // formally advertise CameraExtensionCharacteristics.EXTENSION_MACRO
        // as a supported *mode* rather than a distinct camera ID -- if this
        // device implements it, that's a direct, no-visual-comparison-needed
        // confirmation. Deliberately scoped to capture_harness only (a
        // standalone test build, per this project's own standing policy of
        // keeping one-off diagnostic tooling out of the production
        // clearbridge_beta app) -- see the removed diagnostic-screen
        // precedent (commit 4a832c0) this project already established.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "clearbridge/cameraCapabilities")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCameraLensInfo" -> try {
                        result.success(cameraLensInfoByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "getCameraExtensionSupport" -> try {
                        result.success(cameraExtensionSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun colorFilterArrangementName(value: Int?): String? = when (value) {
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGGB -> "RGGB"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GRBG -> "GRBG"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_GBRG -> "GBRG"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_BGGR -> "BGGR"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_RGB -> "RGB"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_MONO -> "MONO"
        CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT_NIR -> "NIR"
        else -> null
    }

    // Copied verbatim from clearbridge_beta's MainActivity.kt (same
    // read-only query) -- see that file's own history for why each field
    // was added.
    private fun cameraLensInfoByCameraId(): Map<String, Map<String, Any?>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val info = mutableMapOf<String, Map<String, Any?>>()
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            val cfa = chars.get(CameraCharacteristics.SENSOR_INFO_COLOR_FILTER_ARRANGEMENT)
            val hasFlash = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE)
            val minFocusDistanceDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
            info[id] = mapOf(
                "focalLengthMm" to focalLengths?.firstOrNull()?.toDouble(),
                "sensorWidthMm" to sensorSize?.width?.toDouble(),
                "sensorHeightMm" to sensorSize?.height?.toDouble(),
                "lensFacing" to facing,
                "colorFilterArrangement" to colorFilterArrangementName(cfa),
                "hasOwnFlash" to hasFlash,
                "minFocusDistanceDiopters" to minFocusDistanceDiopters?.toDouble(),
            )
        }
        return info
    }

    // New, 2026-08-19: does this device formally advertise Camera2
    // Extensions support, and specifically EXTENSION_MACRO, per camera id?
    // Camera2 Extensions (API 31+) is how newer/flagship devices expose
    // Macro as a vendor-implemented MODE layered on a base camera, rather
    // than as its own distinct physical camera id -- if this device
    // implements it, `getSupportedExtensions()` on that base camera's
    // CameraExtensionCharacteristics will list EXTENSION_MACRO (value 4)
    // directly, settling the "which camera id is Macro" question without
    // needing any visual comparison at all. Real, honest expectation
    // stated plainly: this device (a rugged/budget phone, per this
    // project's own device history) is far more likely to implement Macro
    // the OLDER way -- a genuinely separate low-res camera id switched to
    // directly by the OEM camera app, which Camera2 Extensions has no way
    // to see -- so an empty/false result here does NOT rule Macro out, it
    // just means the visual (photo-comparison) side of this probe is the
    // real answer. Wrapped in try/catch per-id and gated on API 31 (older
    // OS versions don't have the class at all) so this can only ever
    // report false/empty, never crash the probe screen.
    private fun cameraExtensionSupportByCameraId(): Map<String, Map<String, Any?>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val support = mutableMapOf<String, Map<String, Any?>>()
        for (id in cameraManager.cameraIdList) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
                support[id] = mapOf("extensionsApiAvailable" to false, "supportsMacro" to false)
                continue
            }
            try {
                val extChars = cameraManager.getCameraExtensionCharacteristics(id)
                val supported = extChars.supportedExtensions
                support[id] = mapOf(
                    "extensionsApiAvailable" to true,
                    "supportsMacro" to supported.contains(CameraExtensionCharacteristics.EXTENSION_MACRO),
                    "supportedExtensions" to supported.toList(),
                )
            } catch (e: Exception) {
                support[id] = mapOf(
                    "extensionsApiAvailable" to true,
                    "supportsMacro" to false,
                    "error" to e.message,
                )
            }
        }
        return support
    }
}

private class OrientationStreamHandler(
    private val context: Context,
) : EventChannel.StreamHandler, SensorEventListener {
    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
    private val rotationSensor =
        sensorManager?.getDefaultSensor(Sensor.TYPE_GAME_ROTATION_VECTOR)
    private var eventSink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        rotationSensor?.let {
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME)
        }
    }

    override fun onCancel(arguments: Any?) {
        sensorManager?.unregisterListener(this)
        eventSink = null
    }

    override fun onSensorChanged(event: SensorEvent?) {
        val values = event?.values ?: return
        val quaternion = FloatArray(4)
        SensorManager.getQuaternionFromVector(quaternion, values)
        val w = quaternion[0].toDouble()
        val x = quaternion[1].toDouble()
        val y = quaternion[2].toDouble()
        val z = quaternion[3].toDouble()
        eventSink?.success(listOf(x, y, z, w))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
