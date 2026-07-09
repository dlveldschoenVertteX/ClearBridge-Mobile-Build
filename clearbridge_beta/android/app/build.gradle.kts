plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.clearbridge.beta"
    // See the main ClearBridge app's android/app/build.gradle.kts: several
    // AndroidX deps pulled in by sensors_plus and friends require compileSdk
    // >= 34, higher than flutter.compileSdkVersion resolves to.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.clearbridge.beta"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Only use KEYSTORE_PATH if that file actually exists -- CI sets
            // the env var unconditionally, but only decodes/writes the file
            // when the KEYSTORE_BASE64 secret is configured. Falling back to
            // the env var's mere presence (rather than checking the file)
            // broke the build the moment this signing config was added,
            // since the keystore secret hadn't been set up yet.
            val keystorePath = System.getenv("KEYSTORE_PATH")
            val keystoreFile = keystorePath?.let { file(it) }?.takeIf { it.exists() }
            storeFile = keystoreFile ?: signingConfigs.getByName("debug").storeFile
            storePassword = System.getenv("KEYSTORE_PASSWORD") ?: "android"
            keyAlias = System.getenv("KEY_ALIAS") ?: "androiddebugkey"
            keyPassword = System.getenv("KEY_PASSWORD") ?: "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
