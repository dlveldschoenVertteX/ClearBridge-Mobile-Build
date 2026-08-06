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
                    "getManualExposureSupport" -> try {
                        result.success(manualExposureSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                    "probeTorchWithManualExposure" -> try {
                        // Async -- TorchExposureProbe delivers `result` itself
                        // once its short-lived Camera2 session finishes (or
                        // times out), never synchronously here. Caller
                        // (Dart side) MUST await this to completion before
                        // CameraService.initializeCamera() opens the real
                        // capture session -- see TorchExposureProbe's own
                        // doc comment for why the two can never overlap.
                        TorchExposureProbe(applicationContext).run(result)
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
    //
    // 2026-07-24: CTO reported camera "3" ("IR" by their naming) shows less
    // flash bleed/specular glare in the live preview than the main camera.
    // Two very different physical explanations fit that observation -- a
    // genuine near-infrared-sensitive sensor (weak/missing IR-cut filter,
    // common on rugged-phone "night vision" cameras) vs. just a bigger,
    // better-tuned RGB sensor that clips less easily -- and they call for
    // different optimizations. SENSOR_INFO_COLOR_FILTER_ARRANGEMENT is the
    // one Camera2 field that settles this: a true mono/NIR sensor reports
    // MONO/NIR here, a standard sensor reports one of the RGGB/GRBG/GBRG/
    // BGGR Bayer patterns (or RGB). Also added FLASH_INFO_AVAILABLE per
    // camera id -- if camera "3" has its own flash unit distinct from the
    // main camera's, that's a second real candidate explanation (a
    // different illuminant, not just a different sensor) worth telling
    // apart from the sensor-type question.
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

    // Focus-distance-calibration name, added 2026-08-06 as part of the
    // wavelength-hybrid investigation: `LENS_INFO_FOCUS_DISTANCE_CALIBRATION`
    // is the one Camera2 field that says whether this device's
    // LENS_FOCUS_DISTANCE readback is in real, physically-meaningful
    // diopters (CALIBRATED), an uncalibrated-but-monotonic per-device unit
    // (APPROXIMATE), or not usable as a distance signal at all
    // (UNCALIBRATED) -- static, read-only, same precedent as every other
    // probe in this file.
    //
    // IMPORTANT, checked before promising this as a live guidance signal:
    // even a CALIBRATED result here only says the VALUE would be
    // physically meaningful if read -- it does NOT mean this app can
    // actually read it live during the capture hold. This project's own
    // CameraX plugin (camera_android_camerax) exposes no path to live
    // Camera2 CaptureResult data through its public Dart API (confirmed
    // when Item C / native noise-reduction override was investigated and
    // declined: Camera2CameraControlProxyApi/CaptureRequestOptionsProxyApi
    // are internal-only). Reaching LENS_FOCUS_DISTANCE live would need
    // either forking that plugin or opening a second, parallel native
    // Camera2 session alongside the live CameraX one -- the same class of
    // camera-session-churn risk this project has already traced to real
    // ANRs multiple times (see the round-17/19 sweep-timeout and
    // secondary-camera-timeout history) and already explicitly declined
    // for the noise-reduction case. So this field is informational only
    // for now (does this device even support it in principle) -- not
    // wired into any live hint.
    private fun focusDistanceCalibrationName(value: Int?): String? = when (value) {
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_UNCALIBRATED -> "UNCALIBRATED"
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_APPROXIMATE -> "APPROXIMATE"
        CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION_CALIBRATED -> "CALIBRATED"
        else -> null
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
            info[id] = mapOf(
                "focalLengthMm" to focalLengths?.firstOrNull()?.toDouble(),
                "sensorWidthMm" to sensorSize?.width?.toDouble(),
                "sensorHeightMm" to sensorSize?.height?.toDouble(),
                "lensFacing" to facing,
                "colorFilterArrangement" to colorFilterArrangementName(cfa),
                "hasOwnFlash" to hasFlash,
                "focusDistanceCalibration" to focusDistanceCalibrationName(focusCalib),
                "minFocusDistanceDiopters" to minFocusDistanceDiopters?.toDouble(),
            )
        }
        return info
    }

    // Locked-shutter-speed handoff doc, Phase 0 (2026-07-31): before any
    // native Camera2Interop work is considered for a real locked-shutter
    // capture mode, answer the cheap question first -- same discipline as
    // rawSensorSupportByCameraId/noiseReductionOffSupportByCameraId above,
    // and the same reason RAW/DNG got closed out before any real capture
    // work started (that probe came back false on every camera on every
    // real device tested, so the much bigger native lift was never built).
    // Read-only CameraCharacteristics query, never opens a session or
    // issues a CaptureRequest.
    //
    // Two real caveats a positive result here would NOT resolve by itself:
    // (1) Camera2 has no native "locked shutter, auto ISO" AE mode --
    // AE_MODE_OFF (the only way to fix exposure time) requires the app to
    // also drive SENSOR_SENSITIVITY manually, so this only answers "is
    // manual sensor control possible at all", not "does this exact hybrid
    // mode exist for free"; (2) this app has no Camera2Interop plumbing
    // today (confirmed: the camera/camera_android_camerax plugin's public
    // Dart API exposes no path to CaptureRequest.SENSOR_EXPOSURE_TIME), so
    // reaching this even on a supporting device is a real native build, not
    // a follow-up config change. exposureTimeRangeNs is in NANOSECONDS
    // (Camera2's own unit) -- the handoff doc's targetShutterSpeedUs=6667
    // assumed microseconds; convert carefully if this is ever used.
    private fun manualExposureSupportByCameraId(): Map<String, Map<String, Any?>> {
        val cameraManager = applicationContext
            .getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val support = mutableMapOf<String, Map<String, Any?>>()
        for (id in cameraManager.cameraIdList) {
            val chars = cameraManager.getCameraCharacteristics(id)
            val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?: IntArray(0)
            val hasManualSensor = caps.contains(
                CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR
            )
            val exposureRange = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
            val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            support[id] = mapOf(
                "supportsManualSensor" to hasManualSensor,
                "exposureTimeRangeNs" to exposureRange?.let { listOf(it.lower, it.upper) },
                "isoRange" to isoRange?.let { listOf(it.lower, it.upper) },
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
