package com.clearbridge.fusion

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
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

        // Ported from clearbridge_beta's own MainActivity.kt (only the two
        // probes this app actually needs -- getCameraLensInfo/
        // getRawSensorSupport -- not clearbridge_beta's full capability
        // set, which also covers noise-reduction/manual-exposure/torch
        // investigations unrelated to fusion_capture's own goals). Real,
        // direct motivation: fusion_capture's macro (camera "2") phase
        // crops with the FRONT camera's own guide_region as an unvalidated
        // placeholder (see phase0c_real_fusion_capture.py's own loud
        // warning about this) -- cameraLensInfo is what lets that crop be
        // corrected with real per-device sensor/focal-length data instead
        // of a guess, the same mechanism main.py's own secondary-camera
        // scoring loop already relies on. rawSensorSupport doubles as
        // real, free hardware-survey data for whatever device this
        // happens to run on -- directly useful if this app is ever run on
        // more than one physical device to compare hardware.
        // Read-only characteristics queries, never open a camera session.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "clearbridge/cameraCapabilities")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getCameraLensInfo" -> try {
                        result.success(cameraLensInfoByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "getRawSensorSupport" -> try {
                        result.success(rawSensorSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "getPhysicalCameraIds" -> try {
                        result.success(physicalCameraIdsByCameraId())
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

    private fun focusDistanceCalibrationName(value: Int?): String? = when (value) {
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_UNCALIBRATED -> "UNCALIBRATED"
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_APPROXIMATE -> "APPROXIMATE"
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_CALIBRATED -> "CALIBRATED"
        else -> null
    }

    private fun afModeName(value: Int): String = when (value) {
        CameraCharacteristics.CONTROL_AF_MODE_OFF -> "OFF"
        CameraCharacteristics.CONTROL_AF_MODE_AUTO -> "AUTO"
        CameraCharacteristics.CONTROL_AF_MODE_MACRO -> "MACRO"
        CameraCharacteristics.CONTROL_AF_MODE_CONTINUOUS_VIDEO -> "CONTINUOUS_VIDEO"
        CameraCharacteristics.CONTROL_AF_MODE_CONTINUOUS_PICTURE -> "CONTINUOUS_PICTURE"
        CameraCharacteristics.CONTROL_AF_MODE_EDOF -> "EDOF"
        else -> "UNKNOWN_$value"
    }

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
            val focusCalib = chars.get(CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION)
            val minFocusDistanceDiopters = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)
            val ois = chars.get(CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION)
                ?: IntArray(0)
            val hasOis = ois.any { it != CameraCharacteristics.LENS_OPTICAL_STABILIZATION_MODE_OFF }
            // Real diagnostic, 2026-09-02: CTO reported the A55's macro shot
            // (camera "2") stays soft even after the crop/AF-target fix
            // landed on the right region -- direct hypothesis was "maybe
            // this lens doesn't even have real autofocus". minFocusDistance
            // alone can't answer that (it read null on every camera on this
            // device, which just means the native query found nothing, not
            // that the lens is fixed-focus -- a genuinely fixed-focus lens
            // reports EXACTLY 0.0 there per Android's own spec, not null).
            // CONTROL_AF_AVAILABLE_MODES is the real, direct answer: a
            // fixed-focus lens reports only OFF (or an empty/absent list);
            // a lens with real AF reports AUTO/CONTINUOUS_PICTURE/etc.
            // alongside it.
            val afModes = chars.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                ?: IntArray(0)
            val afModeNames = afModes.map { afModeName(it) }
            info[id] = mapOf(
                "focalLengthMm" to focalLengths?.firstOrNull()?.toDouble(),
                "sensorWidthMm" to sensorSize?.width?.toDouble(),
                "sensorHeightMm" to sensorSize?.height?.toDouble(),
                "lensFacing" to facing,
                "colorFilterArrangement" to colorFilterArrangementName(cfa),
                "hasOwnFlash" to hasFlash,
                "focusDistanceCalibration" to focusDistanceCalibrationName(focusCalib),
                "minFocusDistanceDiopters" to minFocusDistanceDiopters?.toDouble(),
                "hasOpticalStabilization" to hasOis,
                "afAvailableModes" to afModeNames,
            )
        }
        return info
    }

    // Real, direct test of the CTO's "3 physical rear cameras, camera 1
    // must be the macro by elimination" hypothesis (2026-09-02) -- the
    // decisive counter-evidence so far is photographic (camera "1"'s own
    // captured frame is unambiguously a selfie), but `cameraManager
    // .cameraIdList` only enumerates LOGICAL/top-level camera ids, which
    // on many Samsung devices does not include every physical rear lens
    // separately. A macro sensor grouped under a logical multi-camera id
    // (API 28+, `CameraCharacteristics.getPhysicalCameraIds()`) would
    // never show up as its own top-level id at all -- exactly the shape
    // that would explain camera "0" being the only id whose
    // `afAvailableModes` advertises MACRO: id "0" may be the logical
    // camera that internally owns a hidden physical macro sensor. This
    // answers that directly instead of inferring it from AF-mode lists.
    private fun physicalCameraIdsByCameraId(): Map<String, List<String>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val info = mutableMapOf<String, List<String>>()
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.P) {
            // getPhysicalCameraIds() is API 28+; below that, report an
            // empty list per id rather than crash -- absence of physical
            // sub-ids is meaningful data only when we can actually query
            // it. No known device in this project's fleet is this old,
            // but there is no reason to hard-fail if one ever is.
            for (id in cameraManager.cameraIdList) info[id] = emptyList()
            return info
        }
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            info[id] = chars.physicalCameraIds.toList()
        }
        return info
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
