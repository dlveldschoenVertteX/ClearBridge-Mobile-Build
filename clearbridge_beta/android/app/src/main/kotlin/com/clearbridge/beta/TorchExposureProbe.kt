package com.clearbridge.beta

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * docs/LOCKED_SHUTTER_SPEED_SCOPE.md, Phase 0: answers the one real open
 * question Option A (a Camera2Interop pass-through patched onto the live
 * CameraX session) hinges on -- does this device's Camera2 HAL keep the
 * torch lit (FLASH_MODE_TORCH) while CONTROL_AE_MODE is OFF and exposure
 * time / sensitivity are set manually, the way it already refuses to when
 * the app merely calls the much smaller setExposureMode() (see
 * CameraService's own documented finding: that alone blocks the torch on
 * this CameraX backend)?
 *
 * Deliberately does NOT reuse the live CameraX-managed session --
 * MainActivity has no handle into that plugin-internal session
 * (Camera2CameraControlProxyApi is marked @OptIn/internal, confirmed against
 * the plugin's own source), so this opens its OWN short-lived, throwaway
 * Camera2 session instead. That tests the underlying HAL-level constraint
 * (can AE_MODE_OFF + FLASH_MODE_TORCH coexist AT ALL on this hardware),
 * which is the fundamental question -- a positive result here is necessary
 * but not sufficient proof Option A works through CameraX's own interop
 * layer specifically; see the scope doc's own caveat on this.
 *
 * MUST be run to completion BEFORE CameraService.initializeCamera() opens
 * the real capture session -- Android does not allow two concurrent
 * CameraDevice handles onto the same physical camera, so this and the live
 * capture flow can never overlap. Called once, cached Dart-side, same
 * pattern as every other capability probe in MainActivity.kt.
 */
class TorchExposureProbe(private val context: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val thread = HandlerThread("torchExposureProbe")
    private lateinit var bgHandler: Handler

    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null
    private var finished = false
    private val out = mutableMapOf<String, Any?>()
    private lateinit var flutterResult: MethodChannel.Result

    fun run(result: MethodChannel.Result) {
        flutterResult = result
        val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        val cameraId = cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: cameraManager.cameraIdList.firstOrNull()

        if (cameraId == null) {
            finishWith(mapOf("skipped" to true, "reason" to "no camera found"))
            return
        }
        out["cameraId"] = cameraId

        val chars = cameraManager.getCameraCharacteristics(cameraId)
        val caps = chars.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES) ?: IntArray(0)
        if (!caps.contains(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR)) {
            finishWith(mapOf("skipped" to true, "reason" to "no manual sensor capability"))
            return
        }
        if (chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) != true) {
            finishWith(mapOf("skipped" to true, "reason" to "no flash unit on this camera"))
            return
        }
        val exposureRange = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val isoRange = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        if (exposureRange == null || isoRange == null) {
            finishWith(mapOf("skipped" to true, "reason" to "exposure/iso range unavailable"))
            return
        }

        // Handoff doc's own target (1/150s = 6667us), converted to Camera2's
        // native nanosecond unit and clamped to this device's real range.
        val targetExposureNs = 6_667_000L.coerceIn(exposureRange.lower, exposureRange.upper)
        // A conservative mid-range ISO -- this probe never keeps a frame, so
        // it isn't tuned for image quality, just needs to be a value the
        // device is guaranteed to accept.
        val targetIso = 400.coerceIn(isoRange.lower, isoRange.upper)
        out["targetExposureNs"] = targetExposureNs
        out["targetIso"] = targetIso

        thread.start()
        bgHandler = Handler(thread.looper)
        // 6s hard bound -- this project's real-device history is full of
        // camera-session-related hangs; a stuck probe must never be allowed
        // to block the real capture flow that opens right after it.
        bgHandler.postDelayed({
            if (!finished) {
                out["timedOut"] = true
                finish()
            }
        }, 6000)

        // Guard before openCamera(): a SecurityException here gets cached
        // permanently by the Dart side, blocking every future probe attempt.
        // Returning skipped/reason here instead of error lets Dart detect
        // the transient state (permission not yet granted) and retry on the
        // next screen open rather than treating it as a permanent failure.
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            finishWith(mapOf("skipped" to true, "reason" to "camera_permission_not_granted"))
            return
        }

        try {
            val r = ImageReader.newInstance(320, 240, ImageFormat.YUV_420_888, 2)
            reader = r
            r.setOnImageAvailableListener({ rd -> rd.acquireLatestImage()?.close() }, bgHandler)

            cameraManager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(cam: CameraDevice) {
                    device = cam
                    openSession(cam, r)
                }
                override fun onDisconnected(cam: CameraDevice) {
                    out["error"] = "camera disconnected"
                    finish()
                }
                override fun onError(cam: CameraDevice, error: Int) {
                    out["error"] = "camera open error $error"
                    finish()
                }
            }, bgHandler)
        } catch (e: SecurityException) {
            // openCamera() threw despite our pre-check (OEM race or revoked
            // mid-call). Use skipped/reason (not error) so the Dart cache
            // logic can detect permission issues and allow retry.
            out["skipped"] = true
            out["reason"] = "camera_permission_security_exception"
            finish()
        } catch (e: Exception) {
            out["error"] = "probe setup failed: ${e.message}"
            finish()
        }
    }

    private fun openSession(cam: CameraDevice, r: ImageReader) {
        try {
            cam.createCaptureSession(
                listOf(r.surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(sess: CameraCaptureSession) {
                        session = sess
                        runBaselineStep(cam, sess, r)
                    }
                    override fun onConfigureFailed(sess: CameraCaptureSession) {
                        out["error"] = "session configure failed"
                        finish()
                    }
                },
                bgHandler,
            )
        } catch (e: Exception) {
            out["error"] = "createCaptureSession: ${e.message}"
            finish()
        }
    }

    private fun flashStateName(v: Int?): String = when (v) {
        CaptureResult.FLASH_STATE_UNAVAILABLE -> "unavailable"
        CaptureResult.FLASH_STATE_CHARGING -> "charging"
        CaptureResult.FLASH_STATE_READY -> "ready"
        CaptureResult.FLASH_STATE_FIRED -> "fired"
        CaptureResult.FLASH_STATE_PARTIAL -> "partial"
        null -> "null"
        else -> "unknown($v)"
    }

    // Step A -- baseline: normal auto-AE + torch. Confirms the flash unit
    // actually fires in THIS raw session/surface context at all, independent
    // of the AE_MODE_OFF question -- without this, a "didn't fire" result
    // under manual exposure would be ambiguous (could be this session
    // context in general, not specifically caused by AE_MODE_OFF).
    private fun runBaselineStep(cam: CameraDevice, sess: CameraCaptureSession, r: ImageReader) {
        try {
            val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(r.surface)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            }.build()
            sess.capture(req, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    s: CameraCaptureSession, rq: CaptureRequest, res: TotalCaptureResult,
                ) {
                    out["torchBaselineFlashState"] = flashStateName(res.get(CaptureResult.FLASH_STATE))
                    runManualExposureStep(cam, sess, r)
                }
                override fun onCaptureFailed(
                    s: CameraCaptureSession, rq: CaptureRequest, f: CaptureFailure,
                ) {
                    out["torchBaselineFlashState"] = "captureFailed"
                    runManualExposureStep(cam, sess, r)
                }
            }, bgHandler)
        } catch (e: Exception) {
            out["error"] = "baseline capture failed: ${e.message}"
            finish()
        }
    }

    // Step B -- the real question: AE_MODE_OFF + fixed exposure/ISO + torch.
    private fun runManualExposureStep(cam: CameraDevice, sess: CameraCaptureSession, r: ImageReader) {
        try {
            val targetExposureNs = out["targetExposureNs"] as Long
            val targetIso = out["targetIso"] as Int
            val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(r.surface)
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                set(CaptureRequest.SENSOR_EXPOSURE_TIME, targetExposureNs)
                set(CaptureRequest.SENSOR_SENSITIVITY, targetIso)
                set(CaptureRequest.FLASH_MODE, CaptureRequest.FLASH_MODE_TORCH)
            }.build()
            sess.capture(req, object : CameraCaptureSession.CaptureCallback() {
                override fun onCaptureCompleted(
                    s: CameraCaptureSession, rq: CaptureRequest, res: TotalCaptureResult,
                ) {
                    out["manualExposureRequestSucceeded"] = true
                    out["torchManualExposureFlashState"] =
                        flashStateName(res.get(CaptureResult.FLASH_STATE))
                    out["actualExposureTimeNs"] = res.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                    out["actualIso"] = res.get(CaptureResult.SENSOR_SENSITIVITY)
                    finish()
                }
                override fun onCaptureFailed(
                    s: CameraCaptureSession, rq: CaptureRequest, f: CaptureFailure,
                ) {
                    out["manualExposureRequestSucceeded"] = false
                    out["torchManualExposureFlashState"] = "captureFailed"
                    finish()
                }
            }, bgHandler)
        } catch (e: Exception) {
            out["error"] = "manual-exposure capture failed: ${e.message}"
            finish()
        }
    }

    private fun finish() {
        if (finished) return
        finished = true
        try { session?.close() } catch (e: Exception) {}
        try { device?.close() } catch (e: Exception) {}
        try { reader?.close() } catch (e: Exception) {}
        try { thread.quitSafely() } catch (e: Exception) {}
        mainHandler.post { flutterResult.success(out) }
    }

    private fun finishWith(result: Map<String, Any?>) {
        out.putAll(result)
        mainHandler.post { flutterResult.success(out) }
    }
}
