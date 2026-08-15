pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Added 2026-08-15 for real crash reporting (see main.dart's own
    // init comment -- a real device crash during upload had no stack
    // trace to diagnose from). android/app/google-services.json now
    // exists (fetched via the real Firebase Management API, a NEW
    // Android-app registration for com.clearbridge.beta -- this
    // package was never registered in the Firebase project before;
    // firebase_options.dart had been borrowing a different app's
    // appId, which works for Dart-only SDKs but not for Crashlytics'
    // native app registration).
    // NOTE: these two versions could NOT be verified against the live
    // Maven registry from this sandbox (dl.google.com and
    // search.maven.org are both blocked by the sandbox's own egress
    // policy, confirmed via the proxy status endpoint) -- real,
    // well-established published versions, but check these FIRST if
    // CI fails specifically on plugin resolution.
    id("com.google.gms.google-services") version "4.4.2" apply false
    id("com.google.firebase.crashlytics") version "3.0.3" apply false
}

include(":app")
