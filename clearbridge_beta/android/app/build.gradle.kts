plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Processes google-services.json (real crash reporting, 2026-08-15 --
    // see settings.gradle.kts's own comment on this pair of plugins).
    // Applied AFTER the Flutter plugin per Firebase's own documented
    // ordering requirement (it needs the application block already
    // configured).
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// AGP only auto-generates the debug keystore when a build variant uses the
// literal built-in "debug" SigningConfig object -- the "release" config
// below borrows its storeFile path as a fallback (when no real release
// keystore secret is configured), which does NOT trigger that
// auto-generation. On a fresh CI runner with no pre-existing debug
// keystore that leaves the fallback pointing at a file that's never
// created, so validateSigningRelease fails outright. Generate it ourselves
// if missing, matching AGP's own default debug key parameters.
// Read the path from AGP's own "debug" SigningConfig rather than
// hardcoding ~/.android/debug.keystore -- newer Android tooling resolves
// this to the XDG location (~/.config/.android/debug.keystore) on runners
// where XDG_CONFIG_HOME is set, and a hardcoded path silently generated a
// keystore nobody looked at while validateSigningRelease still failed
// "not found" against the real (XDG) path.
val debugKeystore = android.signingConfigs.getByName("debug").storeFile!!
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
    }

    // Plugin AARs (camerax, TFLite, datastore) bundle pre-compiled .so files
    // for arm64-v8a, armeabi-v7a, AND x86_64. But --target-platform android-arm64
    // only compiles libapp.so + libflutter.so for arm64, leaving the other ABI
    // directories partially populated (no libapp.so / libflutter.so). Android's
    // ABI selector sees multiple lib directories, picks the "best" one for the
    // device, then fails when core Flutter libs are missing there.
    // ndk.abiFilters only controls JNI compilation — it does NOT strip
    // pre-built .so files from plugin AARs. packaging.jniLibs.excludes
    // operates at the final APK packaging step and actually removes them.
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86_64/**",
                "lib/x86/**",
            )
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
            // Secrets not yet configured in GitHub evaluate to "" (empty string), not
            // null, so `?: "android"` alone doesn't trigger the fallback. Use
            // takeIf { isNotBlank() } so both null and "" fall through to the defaults.
            storePassword = System.getenv("KEYSTORE_PASSWORD")?.takeIf { it.isNotBlank() } ?: "android"
            keyAlias = System.getenv("KEY_ALIAS")?.takeIf { it.isNotBlank() } ?: "androiddebugkey"
            keyPassword = System.getenv("KEY_PASSWORD")?.takeIf { it.isNotBlank() } ?: "android"
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
