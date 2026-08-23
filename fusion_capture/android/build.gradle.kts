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

// Same plugin set (camera, tflite_flutter, sensors_plus) hits the same
// Java/Kotlin JVM-target mismatch across plugins as the main ClearBridge app
// -- see the main app's android/build.gradle.kts for the full writeup. Kept
// identical here rather than re-deriving it.
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

// Matches the main app: sensors_plus (and potentially others) declare their
// own compileSdk = 33, which several transitively-pulled AndroidX deps need
// at least 34 for. See the main app's android/build.gradle.kts for details.
subprojects {
    if (project.name == "app") return@subprojects
    afterEvaluate {
        plugins.withId("com.android.library") {
            extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)
                ?.compileSdk = 36
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
