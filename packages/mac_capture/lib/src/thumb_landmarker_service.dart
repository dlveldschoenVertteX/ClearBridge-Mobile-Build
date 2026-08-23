/// Conditional export: the real tflite_flutter-backed implementation on
/// every platform that has `dart:io` (Android, iOS, desktop -- every camera
/// app in this monorepo), a web-safe stub everywhere else. `dart:library.io`
/// is Dart's own standard, built-in platform-detection mechanism for
/// exactly this -- not a project-specific guess -- and this is the same
/// stub/io conditional-export shape widely used by federated Flutter
/// plugins for a platform-specific dependency.
///
/// See thumb_landmarker_service_web.dart's docstring for why this is
/// needed: tflite_flutter's generated bindings use `dart:ffi`, which has no
/// web target at all, so importing it anywhere in a web build's reachable
/// import graph fails compilation outright (confirmed via a real CI build
/// log, 2026-08-23) -- not a runtime concern, a hard compile-time one.
///
/// Every caller in this monorepo imports THIS file by its stable name
/// (never the _io/_web variants directly), so no caller needed to change.
export 'thumb_landmarker_service_web.dart'
    if (dart.library.io) 'thumb_landmarker_service_io.dart';
