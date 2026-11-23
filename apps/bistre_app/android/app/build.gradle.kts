plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // Release signing keys supplied via CI secrets or local key.properties; debug fallback for local verification builds.
            signingConfig = signingConfigs.getByName("debug")
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
