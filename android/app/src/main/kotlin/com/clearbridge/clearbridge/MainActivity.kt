package com.clearbridge.clearbridge

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

// Streams GAME_ROTATION_VECTOR as a normalized [x, y, z, w] quaternion over
// the "clearbridge/orientation" EventChannel. This is the sole source of the
// device orbit angle used to drive the left/top/right MAC capture positions
// (see lib/device_orientation_service.dart) -- without this channel the Dart
// side never receives sensor events and the orbit angle is permanently stuck
// at the identity quaternion.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "clearbridge/orientation")
            .setStreamHandler(OrientationStreamHandler(applicationContext))
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
        // TYPE_GAME_ROTATION_VECTOR reports either 3 elements (x, y, z, with
        // the scalar w implied) or 4 (x, y, z, cos(theta/2)) depending on
        // device/API level. getQuaternionFromVector normalizes either input
        // to a full [w, x, y, z] quaternion.
        val quaternion = FloatArray(4)
        SensorManager.getQuaternionFromVector(quaternion, values)
        val w = quaternion[0].toDouble()
        val x = quaternion[1].toDouble()
        val y = quaternion[2].toDouble()
        val z = quaternion[3].toDouble()
        // Dart side (DeviceOrientationService) expects [x, y, z, w].
        eventSink?.success(listOf(x, y, z, w))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
