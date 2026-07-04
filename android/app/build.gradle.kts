plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.clearbridge.app"
    // flutter.compileSdkVersion resolved to 33 here, but several AndroidX
    // deps (androidx.core 1.13.1, lifecycle 2.7.0, exifinterface 1.4.1...)
    // pulled in by sensors_plus and friends require compileSdk >= 34.
    // Pinned directly rather than trusting the Flutter-resolved default.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications' AAR metadata.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.clearbridge.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Two co-installable variants of the same codebase — one defaulting to
    // 4-angle capture, one to arc-sweep. Which capture flow is actually used
    // at runtime is selected by the CAPTURE_MODE dart-define passed to
    // `flutter build apk --flavor <flavor> --dart-define=CAPTURE_MODE=<mode>`;
    // these flavors only need to keep the two APKs distinct on-device
    // (application ID + display name) so both can be installed side by side.
    flavorDimensions += "captureMode"
    productFlavors {
        create("fourAngle") {
            dimension = "captureMode"
            resValue("string", "app_name", "ClearBridge")
        }
        create("arcSweep") {
            dimension = "captureMode"
            applicationIdSuffix = ".arcsweep"
            resValue("string", "app_name", "ClearBridge Arc")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
