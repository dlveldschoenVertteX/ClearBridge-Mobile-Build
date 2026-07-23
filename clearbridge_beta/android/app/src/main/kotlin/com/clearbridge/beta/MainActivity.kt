package com.clearbridge.beta

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
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

        // docs/RIDGE_CONTINUITY_OPTIMIZATION_SCOPE.md item 4, Phase 0: a
        // read-only capability query (never fires an actual RAW capture),
        // so a future decision on whether to build a real RAW/DNG capture
        // path is grounded in which real devices support it, not a guess.
        // Deliberately NOT a revived diagnostic screen (that was explicitly
        // removed, commit 4a832c0, as "test-only tooling with no place in
        // the current build") -- this is a silent one-shot query whose
        // result the Dart side attaches to the normal capture's own
        // Firestore doc, no new UI.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "clearbridge/cameraCapabilities")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getRawSensorSupport" -> try {
                        result.success(rawSensorSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "getNoiseReductionOffSupport" -> try {
                        result.success(noiseReductionOffSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "getCameraLensInfo" -> try {
                        result.success(cameraLensInfoByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun rawSensorSupportByCameraId(): Map<String, Boolean> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val support = mutableMapOf<String, Boolean>()
        for (id in cameraManager.cameraIdList) {
            val caps = cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?: IntArray(0)
            support[id] = caps.contains(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_RAW
            )
        }
        return support
    }

    // docs/CAPTURE_OPTIMIZATION_SCOPE.md Lever C.1, Phase 0: a read-only
    // characteristics query (same shape/precedent as rawSensorSupportByCameraId
    // above -- never fires a capture, never touches a live session) so a
    // future decision on whether to attempt the much harder live
    // CaptureRequest.NOISE_REDUCTION_MODE/EDGE_MODE=OFF override (which needs
    // Camera2 interop and has NOT been de-risked the way RAW/DNG was) is
    // grounded in whether real devices even ADVERTISE support for turning
    // this off, not a guess. A device that doesn't list OFF among its
    // available modes can't honor the override no matter how it's reached,
    // so this alone can rule the harder work out the same way rawSensorSupport
    // ruled out RAW/DNG.
    private fun noiseReductionOffSupportByCameraId(): Map<String, Map<String, Boolean>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val support = mutableMapOf<String, Map<String, Boolean>>()
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val nrModes = chars.get(CameraCharacteristics.NOISE_REDUCTION_AVAILABLE_NOISE_REDUCTION_MODES)
                ?: IntArray(0)
            val edgeModes = chars.get(CameraCharacteristics.EDGE_AVAILABLE_EDGE_MODES)
                ?: IntArray(0)
            support[id] = mapOf(
                "noiseReductionOff" to nrModes.contains(CaptureRequest.NOISE_REDUCTION_MODE_OFF),
                "edgeModeOff" to edgeModes.contains(CaptureRequest.EDGE_MODE_OFF),
            )
        }
        return support
    }

    // Real-device finding, 2026-07-23: secondary camera "2" times out on
    // upload far more often than "3" across several real captures, but
    // camera IDs alone don't say which physical lens (IR/night-vision vs.
    // ultrawide) each one actually is -- nothing in the app has ever
    // distinguished them beyond the raw Android camera-id string. Read-only
    // characteristics query (same shape as the two above, never touches a
    // live session) so the next real capture's secondaryCameraDebug can be
    // cross-referenced against which physical lens actually stalled,
    // instead of guessing from an opaque id.
    private fun cameraLensInfoByCameraId(): Map<String, Map<String, Any?>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val info = mutableMapOf<String, Map<String, Any?>>()
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val focalLengths = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
            val facing = chars.get(CameraCharacteristics.LENS_FACING)
            info[id] = mapOf(
                "focalLengthMm" to focalLengths?.firstOrNull()?.toDouble(),
                "sensorWidthMm" to sensorSize?.width?.toDouble(),
                "sensorHeightMm" to sensorSize?.height?.toDouble(),
                "lensFacing" to facing,
            )
        }
        return info
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
