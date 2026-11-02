# Flutter Wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# Sherpa-ONNX and ONNX Runtime JNI
-keep class com.k2fsa.sherpa.onnx.** { *; }
-dontwarn com.k2fsa.sherpa.onnx.**

# SQLite and native libraries
-keep class com.tekartik.sqflite.** { *; }
-dontwarn com.tekartik.sqflite.**

# Crypto and okhttp / Dio
-dontwarn okhttp3.**
-dontwarn okio.**

# Google Play Core (Flutter deferred components)
-dontwarn com.google.android.play.core.**


