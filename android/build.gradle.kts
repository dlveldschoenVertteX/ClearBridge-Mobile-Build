allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Several plugins ship a build.gradle with a Java/Kotlin JVM target
// mismatch that Gradle rejects as "Inconsistent JVM Target Compatibility"
// -- but they don't all disagree in the same direction. tflite_flutter,
// flutter_image_compress_common and audio_session pin Java to 11 while
// Kotlin resolves to 17; camera_android_camerax's Java already resolves
// to 17 and broke when Kotlin was blanket-forced to 11. There's no single
// target that's correct for every plugin.
//
// Forcing JavaCompile's own source/targetCompatibility (an earlier
// attempt) broke audio_session outright: its Java sources could no
// longer find android.* packages at all, meaning that interfered with
// AGP's own Android SDK classpath wiring. So Java compileOptions are
// left completely alone here -- instead, each module's Kotlin target is
// read from and matched to whatever ITS OWN Java compile task already
// resolved to, per-module, rather than assuming one value fits every
// plugin.
//
// gradle.projectsEvaluated {} runs once every project has finished
// configuring itself, regardless of evaluation order (subprojects {
// afterEvaluate {...} } crashes here because evaluationDependsOn(":app")
// above means :app is already evaluated by the time that block runs).
gradle.projectsEvaluated {
    subprojects {
        if (project.name == "app") return@subprojects
        val javaTask = tasks.withType<JavaCompile>().firstOrNull() ?: return@subprojects
        val jvmTarget = when (javaTask.targetCompatibility) {
            "1.8", "8" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
            "11" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11
            "17" -> org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
            else -> null
        } ?: return@subprojects
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                this.jvmTarget.set(jvmTarget)
            }
        }
    }
}

// compileSdk = 36 on :app (build.gradle.kts) only raises the *app's own*
// compileSdk -- it has no effect on plugin modules. sensors_plus (and
// potentially others) declare their own compileSdk = 33 in their own
// build.gradle, which several transitively-pulled AndroidX deps
// (androidx.core 1.13.1, lifecycle 2.7.0, exifinterface 1.4.1...)
// require at least 34 for. Same fix shape as the JVM-target override
// above: read late via projectsEvaluated so it wins over each plugin's
// own declaration, applied to every android-library subproject.
gradle.projectsEvaluated {
    subprojects {
        if (project.name == "app") return@subprojects
        plugins.withId("com.android.library") {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
