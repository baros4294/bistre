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
            // Uses provisioned release keystore when available (CI secrets or local key.properties);
            // falls back to debug keystore for unsigned local verification builds.
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
