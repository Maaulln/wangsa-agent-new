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
// flutter_voice_processor 1.1.2, dependensi transitif porcupine_flutter,
// masih mengunci compileSdkVersion 31, padahal pustaka AndroidX yang ia
// tarik menuntut minimal 34. Tanpa ini build gagal di tahap
// checkDebugAarMetadata. compileSdk hanya menentukan API yang boleh
// dipakai saat kompilasi; minSdk dan targetSdk plugin tidak berubah, jadi
// perangkat yang didukung tetap sama.
//
// WAJIB berada sebelum blok evaluationDependsOn di bawah: blok itu memaksa
// proyek dievaluasi lebih awal, dan afterEvaluate yang didaftarkan
// sesudahnya akan ditolak Gradle.
subprojects {
    if (project.name != "app") {
        afterEvaluate {
            extensions.findByName("android")?.let { android ->
                (android as com.android.build.gradle.BaseExtension).compileSdkVersion(36)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
