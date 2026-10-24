import org.jetbrains.kotlin.gradle.dsl.JvmTarget

val splitPerAbi = providers.gradleProperty("split-per-abi").isPresent

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.nozelt.nozelt"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        // Used by NozeltLog to compile production lifecycle logging down to
        // a release-time false branch without querying package state.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.nozelt.nozelt"
        // nozelt-core .aar is built with -androidapi=24 — keep these in sync.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // The embedded Go core is intentionally built for physical ARM
        // devices only. Do not advertise an x86 ABI containing Flutter but no
        // libgojni.so: Android would install it and crash at first core call.
        if (!splitPerAbi) {
            ndk {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a")
            }
        }

        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17", "-Wall", "-Wextra")
            }
        }
    }

    if (splitPerAbi) {
        // Flutter configures ABI splits before evaluating this script and its
        // default target set also contains x86_64. The Go AAR intentionally
        // ships only physical-device ARM binaries, so remove the unsupported
        // split instead of producing an installable APK that crashes when JNI
        // first loads Binding.
        splits {
            abi {
                reset()
                include("arm64-v8a", "armeabi-v7a")
            }
        }
    }

    lint {
        // Flutter regenerates local.properties with Windows paths in a form
        // Gradle accepts but Android Lint misreports as PropertyEscape.
        disable += "PropertyEscape"
        // The legacy fallback intentionally fills its square with the brand's
        // black background; the logo itself remains inside the safe zone and
        // adaptive launchers use separate background/foreground layers.
        disable += "IconLauncherShape"
    }

    // Nozelt switches notification/UI language in-app. Keep both tiny RU/EN
    // resource sets in every bundle split instead of requiring Play Core
    // language downloads before the foreground service can localize itself.
    bundle {
        language {
            enableSplit = false
        }
    }

    // Xray and sing-box are native PIE executables, not JNI libraries. They
    // intentionally use a lib*.so filename so Android packages the correct
    // ABI, but they must exist as executable files in nativeLibraryDir rather
    // than only as mmap-able entries inside the APK.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Intentionally unsigned until a private production keystore is
            // configured. Never produce a distributable release with the
            // public Android debug key.
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // nozelt-core: Go engine compiled to .aar via gomobile. Refresh via
    // ../scripts/sync_aar.{sh,ps1}; not committed to VCS.
    implementation(files("libs/nozelt.aar"))

    // Coroutines for the Kotlin <-> Go bridge so blocking Go calls run off the
    // main thread without callback chains.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")

    // lifecycleScope on FlutterActivity (extends ComponentActivity).
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.11.0")

    // NotificationCompat/NotificationManagerCompat — keeps the
    // notification path safe on API 24-25 where NotificationChannel
    // does not exist.
    //noinspection GradleDependency -- 1.19 requires API 37 / AGP 9.1.
    implementation("androidx.core:core-ktx:1.18.0")

    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
