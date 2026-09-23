plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "id.wangsa.wangsa_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Wajib untuk flutter_local_notifications (dipakai VoiceSummoner
        // gaya Siri): AAR-nya memakai API java.time yang butuh desugaring
        // di bawah API 26.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "id.wangsa.wangsa_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        // Pinned below Flutter's own default (36 / Android 16) rather than
        // left floating: kept conservative after finding, via testing on a
        // real Android 15 phone, that the foreground service's mic-holding
        // type needed to move off "microphone" entirely (see the
        // FOREGROUND_SERVICE_SPECIAL_USE comment in AndroidManifest.xml —
        // "microphone" FGS type turned out to require privileged
        // CAPTURE_AUDIO_HOTWORD-class permissions no normal app can hold,
        // regardless of targetSdk). API 34 is what this app's wake-word
        // design was built and verified against.
        targetSdk = 34
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

    // try-jarvis spike only: `sherpa_onnx` and `flutter_onnxruntime` both
    // bundle their own `lib/arm64-v8a/libonnxruntime.so` at the identical
    // APK path, which makes Gradle's native-lib merge fail outright.
    // `pickFirst`/`excludes` can't fix this on their own — neither can
    // discriminate by *source*, only by final path, and AGP's merge always
    // favors sherpa_onnx's copy (a local project module) over
    // flutter_onnxruntime's (an external Maven AAR) regardless of
    // `pickFirst`. Kept here only as a harmless safety net for any other
    // future duplicate; the real fix is the task below.
    //
    // ROOT CAUSE (verified via `llvm-readelf` on both .so files, not
    // guessed): this isn't just "two copies of the same library" — the two
    // plugins were built against genuinely different upstream ONNX Runtime
    // releases, and ONNX Runtime's Android build uses a *flat* per-release
    // symbol version tag (no backward-compatible version chain like
    // glibc's). `libsherpa-onnx-c-api.so` has an undefined reference to
    // `OrtGetApiBase@VERS_1.28.2`; flutter_onnxruntime bundles
    // onnxruntime-android 1.23.0, whose libonnxruntime.so only exports
    // `OrtGetApiBase@@VERS_1.23.0`. No published onnxruntime-android
    // version on Maven Central satisfies both at once (1.28.2 was checked
    // and doesn't exist — releases jump 1.28.0 -> 1.29.0), and even a
    // newer build (checked 1.30.0 directly) only ever exports its own
    // release's version tag, never older ones. So the two native
    // libraries are simply incompatible under one shared filename — a
    // single `libonnxruntime.so` cannot satisfy both consumers.
    //
    // FIX: rather than picking a winner, give sherpa_onnx's copy a unique
    // SONAME (`libonnxruntime_sherpa.so`) via `patchelf` and re-point
    // sherpa's own native libraries at that new name, entirely within
    // sherpa_onnx's own project-local intermediate build output — see the
    // task below. flutter_onnxruntime's AAR-provided
    // `libonnxruntime.so`/`libonnxruntime4j_jni.so` are left completely
    // untouched at their normal path. Requires `patchelf` on PATH
    // (`brew install patchelf` on macOS) — a new one-time local dev-tool
    // prerequisite for building this branch; there is no pure-Gradle way
    // to rewrite an ELF SONAME/NEEDED entry. Revert this whole block (and
    // the task below) if `try-jarvis` doesn't merge back.
    packaging {
        jniLibs {
            pickFirsts += "lib/*/libonnxruntime.so"
        }
    }
}

// Pasangan dari isCoreLibraryDesugaringEnabled di atas.
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

// Renames sherpa_onnx's bundled libonnxruntime.so to libonnxruntime_sherpa.so
// and re-links every sherpa_onnx native library that references it, so it no
// longer collides with flutter_onnxruntime's own libonnxruntime.so at the
// same APK path. See the long comment above `packaging` for why this is
// necessary (the two plugins need genuinely incompatible ONNX Runtime
// builds, not just "a" build each).
tasks.matching { it.name.matches(Regex("merge.*NativeLibs")) }.configureEach {
    doFirst {
        // sherpa_onnx ships a separate pub package per ABI (arm64, armeabi,
        // x86, x86_64) — each with its own `intermediates/library_jni` build
        // output. Only patching arm64's copy left every other ABI (including
        // the x86_64 emulator used for local dev/testing) with the original
        // colliding libonnxruntime.so, causing a runtime
        // UnsatisfiedLinkError/OrtGetApiBase crash on app startup instead of
        // a build-time failure.
        val abiPackageNames = listOf(
            "sherpa_onnx_android_arm64",
            "sherpa_onnx_android_armeabi",
            "sherpa_onnx_android_x86",
            "sherpa_onnx_android_x86_64",
        )
        for (pkg in abiPackageNames) {
            val jniRoot = rootProject.layout.buildDirectory
                .dir("$pkg/intermediates/library_jni")
                .get()
                .asFile
            if (!jniRoot.exists()) continue

            jniRoot.walkTopDown()
                .filter { it.isFile && it.name == "libonnxruntime.so" }
                .forEach { originalOrt ->
                    val abiDir = originalOrt.parentFile
                    val renamedOrt = File(abiDir, "libonnxruntime_sherpa.so")

                    originalOrt.copyTo(renamedOrt, overwrite = true)
                    runPatchelf("--set-soname", "libonnxruntime_sherpa.so", renamedOrt.absolutePath)

                    // Re-point every OTHER sherpa_onnx .so in this ABI directory that
                    // declares a NEEDED dependency on the original filename — covers
                    // libsherpa-onnx-c-api.so today, and stays correct if sherpa_onnx
                    // adds/renames wrapper libraries later.
                    abiDir.listFiles { f -> f.isFile && f.name.endsWith(".so") && f.name != "libonnxruntime.so" && f.name != "libonnxruntime_sherpa.so" }
                        ?.forEach { dependent ->
                            runPatchelf("--replace-needed", "libonnxruntime.so", "libonnxruntime_sherpa.so", dependent.absolutePath)
                        }

                    originalOrt.delete()
                }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Plain ProcessBuilder rather than Gradle's `Project.exec` — not resolvable
// as an extension function from a `doFirst {}` task-action lambda under this
// Gradle/AGP version's Kotlin DSL (task actions run detached from the
// Project's script context for configuration-cache compatibility).
fun runPatchelf(vararg args: String) {
    // Windows' CreateProcess (which plain ProcessBuilder calls into) only
    // auto-resolves a bare command name to a `.exe` on PATH, never to a
    // `.bat`/`.cmd` shim — unlike cmd.exe's own command resolution, which
    // honors PATHEXT. A local dev environment providing `patchelf` as a
    // `.bat` wrapper (e.g. forwarding to a container, since there's no
    // native Windows patchelf) would otherwise fail with "Cannot run
    // program 'patchelf': CreateProcess error=2", so route through cmd.exe
    // on Windows to get that resolution back; other OSes call it directly.
    val isWindows = System.getProperty("os.name").lowercase().contains("windows")
    val command = if (isWindows) listOf("cmd", "/c", "patchelf", *args) else listOf("patchelf", *args)
    val process = ProcessBuilder(command)
        .redirectErrorStream(true)
        .start()
    val output = process.inputStream.bufferedReader().readText()
    val exitCode = process.waitFor()
    check(exitCode == 0) {
        "patchelf ${args.joinToString(" ")} failed (exit $exitCode): $output"
    }
}

flutter {
    source = "../.."
}
