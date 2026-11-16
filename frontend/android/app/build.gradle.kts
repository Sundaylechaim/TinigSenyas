import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// android/key.properties is gitignored. Release builds must use a private release key;
// falling back to Android's shared debug key would make a public APK unsafe to distribute.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        load(FileInputStream(keystorePropertiesFile))
    }
}
val releaseStorePath = keystoreProperties.getProperty("storeFile")
val releaseStoreFile = releaseStorePath?.let { file(it) }
val hasReleaseKeystore = keystorePropertiesFile.exists() && releaseStoreFile?.isFile == true

android {
    namespace = "com.example.tinigsenyas"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tinigsenyas.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

// Fail release packaging before AGP can silently sign with the shared debug key,
// without preventing developers from building debug variants on a clean checkout.
tasks.configureEach {
    if (name.startsWith("validateSigning", ignoreCase = true) &&
        name.contains("Release", ignoreCase = true)) {
        doFirst {
            if (!hasReleaseKeystore) {
                throw GradleException(
                    "Release signing is not configured. Add android/key.properties and the private release keystore; refusing to sign a release APK with the debug key."
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
