# Bistre Android R8 / ProGuard keep rules.
# Preserve Flutter embedding, WorkManager workers, Foreground Service, and platform channel entrypoints.
-keep class dev.bistre.bistre_app.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class com.github.dart_lang.jni.** { *; }
-keep class org.rustls.platformverifier.** { *; }
-dontwarn io.flutter.embedding.**
