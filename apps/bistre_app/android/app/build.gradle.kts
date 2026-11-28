import org.gradle.api.file.RegularFileProperty
import org.gradle.api.provider.ValueSource
import org.gradle.api.provider.ValueSourceParameters
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

abstract class RustlsPlatformVerifierVersion : ValueSource<String, RustlsPlatformVerifierVersion.Params> {
    interface Params : ValueSourceParameters {
        val lockFile: RegularFileProperty
    }

    override fun obtain(): String {
        val lines = parameters.lockFile.get().asFile.readLines()
        val idx = lines.indexOfFirst { it.trim() == "name = \"rustls-platform-verifier-android\"" }
        val version = if (idx < 0) {
            null
        } else {
            lines.drop(idx + 1)
                .firstOrNull { it.trimStart().startsWith("version = ") }
                ?.substringAfter('"', "")
                ?.substringBefore('"', "")
                ?.takeIf { it.isNotEmpty() }
        }
        return version ?: error("rustls-platform-verifier-android not found in Cargo.lock")
    }
}

val rustlsPlatformVerifierVersion = providers.of(RustlsPlatformVerifierVersion::class) {
    parameters.lockFile.set(layout.projectDirectory.file("../../../../Cargo.lock"))
}

repositories {
    maven {
        url = uri("https://github.com/rustls/rustls-platform-verifier/raw/maven-archive/android-release-support/maven/")
    }
}

configurations.configureEach {
    resolutionStrategy.eachDependency {
        if (requested.group == "org.rustls" && requested.name == "rustls-platform-verifier") {
            useVersion(rustlsPlatformVerifierVersion.get())
            because("Android TLS verifier AAR must match rustls-platform-verifier-android in Cargo.lock")
        }
    }
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
            // Drop unused ABI shims from transitive plugins (such as libdartjni.so) in arm64 APKs.
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**", "lib/x86_64/**")
        }
        resources {
            excludes += listOf(
                "META-INF/androidx/**",
                "META-INF/*.version",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "DebugProbesKt.bin",
            )
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
        debug {
            // Isolate debug installs side-by-side from the installed production app.
            applicationIdSuffix = ".dev"
        }
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
    implementation("org.rustls:rustls-platform-verifier")
}

flutter {
    source = "../.."
}
