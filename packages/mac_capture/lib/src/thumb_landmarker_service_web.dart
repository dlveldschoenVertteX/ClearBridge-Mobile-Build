import 'package:camera/camera.dart';

import 'hand_types.dart';

/// Web stub for [ThumbLandmarkerService].
///
/// The real implementation (thumb_landmarker_service_io.dart) depends on
/// `package:tflite_flutter`, whose generated bindings call into `dart:ffi`
/// (raw `Pointer`/`NativeFunction` types to invoke the native TensorFlow
/// Lite C library) -- `dart:ffi` has no web target at all, so any file that
/// imports tflite_flutter fails `flutter build web` outright (472 "isn't a
/// type" errors, all `ffi.Pointer`/`ffi.NativeFunction` etc., confirmed via
/// a real CI build log, 2026-08-23) regardless of whether the code path is
/// ever actually reached at runtime.
///
/// Selected over the real implementation via `thumb_landmarker_service.dart`'s
/// conditional export (`if (dart.library.io)`) -- every caller in this
/// monorepo imports that one file by its stable name and is unaffected by
/// which implementation it resolves to. Same public API, permanently
/// "not ready": no camera app in this monorepo runs on web (they're all
/// Android-only builds), so this stub only ever loads for the ONE app that
/// does build for web -- the root Flutter app's admin panel
/// (see .github/workflows/build.yml's deploy-web job) -- which never
/// constructs a live camera capture flow and so never calls `detect()` in
/// practice. Kept honest rather than silently pretending to work: `isReady`
/// stays false and `detect()` always returns empty, so any caller that
/// somehow does reach this on web degrades exactly like "hand landmark
/// detection unavailable" rather than throwing.
class ThumbLandmarkerService {
  bool get isReady => false;

  void initialize() {}

  List<Hand> detect(CameraImage image, int sensorOrientation) => const [];

  void dispose() {}
}
