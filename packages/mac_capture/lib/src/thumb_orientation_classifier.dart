/// Conditional export: the real tflite_flutter-backed implementation on
/// every platform that has `dart:io` (Android, iOS, desktop -- every camera
/// app in this monorepo), a web-safe stub everywhere else. Same reasoning
/// and mechanism as thumb_landmarker_service.dart's own conditional export
/// -- see that file's docstring for the full explanation.
///
/// Every caller in this monorepo imports THIS file by its stable name
/// (never the _io/_web variants directly), so no caller needed to change.
export 'thumb_orientation_classifier_web.dart'
    if (dart.library.io) 'thumb_orientation_classifier_io.dart';
