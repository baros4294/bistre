import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProps = Properties().apply {
    val propsFile = rootProject.file("key.properties")
    if (propsFile.isFile) {
        propsFile.inputStream().use { load(it) }
    }
}
val envKeystorePath = System.getenv("ANDROID_KEYSTORE_PATH")
    ?: keystoreProps.getProperty("storeFile")
val hasReleaseSigning = !envKeystorePath.isNullOrBlank() && file(envKeystorePath).isFile
// C1: on CI a release build never silently falls back to the debug key. Only a job that
// explicitly builds a debug-signed intermediate (re-signed later by the release signing job,
// or the unshipped CI check build) sets BISTRE_ALLOW_DEBUG_SIGNING=1.
val onCi = System.getenv("CI") == "true"
val debugSigningAllowed = System.getenv("BISTRE_ALLOW_DEBUG_SIGNING") == "1"
if (onCi && !hasReleaseSigning && !debugSigningAllowed) {
    throw GradleException(
        "Release signing keystore missing on CI (set ANDROID_KEYSTORE_PATH, or BISTRE_ALLOW_DEBUG_SIGNING=1 for an unshipped build)",
    )
}

android {
    namespace = "dev.bistre.bistre_app"
    compileSdk = 36
    ndkVersion = "30.0.16248370"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.bistre.app"
        minSdk = 29
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a")
            debugSymbolLevel = "NONE"
        }
        resValue("string", "bistre_distribution_channel", "direct")
    }

    packaging {
        jniLibs {
            // Required for Android 15+ 16 KB uncompressed native library alignment (ADR-0002).
            useLegacyPackaging = false
        }
    }

    buildFeatures {
        resValues = true
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(envKeystorePath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                    ?: keystoreProps.getProperty("storePassword")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                    ?: keystoreProps.getProperty("keyAlias")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                    ?: keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Uses the provisioned release keystore when available (local key.properties); otherwise
            // the debug key, which CI allows only for builds that are never shipped as-is (above).
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
}

flutter {
    source = "../.."
}
