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

// Several plugins (tflite_flutter, flutter_image_compress_common, and
// potentially others not yet hit) ship a build.gradle whose Java
// compileOptions still target JVM 11 while their Kotlin compilation
// resolves to 17 on this toolchain -- Gradle rejects the mismatch as
// "Inconsistent JVM Target Compatibility".
//
// Forcing JavaCompile's sourceCompatibility/targetCompatibility up to 17
// (an earlier attempt) broke audio_session's compile: its Java sources
// could no longer find android.* packages at all, meaning that override
// was interfering with AGP's own Android SDK classpath wiring for that
// task. Leaving Java compileOptions alone and only pulling Kotlin *down*
// to 11 (matching what these legacy plugins already declare for Java,
// rather than pushing Java up to match a newer Kotlin target) fixes the
// mismatch without touching anything AGP itself manages. The app module
// keeps its own JVM 17 target (set directly in app/build.gradle.kts) --
// only plugin subprojects need pulling down to 11 here.
//
// gradle.projectsEvaluated {} runs once every project has finished
// configuring itself, regardless of evaluation order (subprojects {
// afterEvaluate {...} } crashes here because evaluationDependsOn(":app")
// above means :app is already evaluated by the time that block runs).
gradle.projectsEvaluated {
    subprojects {
        if (project.name == "app") return@subprojects
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
