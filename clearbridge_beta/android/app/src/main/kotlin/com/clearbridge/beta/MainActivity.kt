package com.clearbridge.beta

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
                if (call.method == "getRawSensorSupport") {
                    try {
                        result.success(rawSensorSupportByCameraId())
                    } catch (e: Exception) {
                        result.error("CAMERA_CAPABILITIES_ERROR", e.message, null)
                    }
                } else {
                    result.notImplemented()
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
