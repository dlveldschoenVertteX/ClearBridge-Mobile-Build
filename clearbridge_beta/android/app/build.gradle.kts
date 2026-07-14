plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// AGP only auto-generates ~/.android/debug.keystore when a build variant
// uses the literal built-in "debug" SigningConfig object -- the "release"
// config below borrows its storeFile path as a fallback (when no real
// release keystore secret is configured), which does NOT trigger that
// auto-generation. On a fresh CI runner with no pre-existing debug
// keystore (confirmed on GitLab; GitHub Actions runners happen to ship
// with one already) that leaves the fallback pointing at a file that's
// never created, so validateSigningRelease fails outright. Generate it
// ourselves if missing, matching AGP's own default debug key parameters.
val debugKeystore = file(System.getProperty("user.home") + "/.android/debug.keystore")
if (!debugKeystore.exists()) {
    debugKeystore.parentFile.mkdirs()
    // Plain ProcessBuilder rather than Gradle's exec {} DSL -- the latter
    // isn't resolvable at this script scope on every AGP/Gradle version
    // (confirmed broken here), while ProcessBuilder is just JVM stdlib.
    val process = ProcessBuilder(
        "keytool", "-genkeypair", "-v",
        "-keystore", debugKeystore.absolutePath,
        "-storepass", "android", "-alias", "androiddebugkey", "-keypass", "android",
        "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000",
        "-dname", "CN=Android Debug,O=Android,C=US",
    ).redirectErrorStream(true).start()
    process.waitFor()
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
        // Plugin native libs (camerax, TFLite, etc.) land in both arm64-v8a
        // and armeabi-v7a, but --target-platform android-arm64 only compiles
        // libapp.so for arm64. The resulting partial armeabi-v7a directory
        // confuses Android's ABI selector and causes INSTALL_PARSE_FAILED /
        // "can't unzip" on sideloaded installs. Restrict to arm64 only so
        // the APK is consistent end-to-end.
        ndk {
            abiFilters += "arm64-v8a"
        }
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
