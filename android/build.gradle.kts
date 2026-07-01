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
// "Inconsistent JVM Target Compatibility". A plain subprojects{} block
// configures tasks too early: each plugin's own build.gradle sets its
// Java target *during* its own evaluation, after this block already ran,
// so it wins the race and silently overwrites our override. afterEvaluate
// runs once a subproject's own script has finished, guaranteeing our
// value is applied last for every plugin module, not just the ones
// that have already surfaced an error one CI run at a time.
subprojects {
    afterEvaluate {
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_17.toString()
            targetCompatibility = JavaVersion.VERSION_17.toString()
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
