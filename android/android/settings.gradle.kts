pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// Local Maven mirror for the Flutter engine debug artifacts
// (io.flutter:arm64_v8a_debug etc.). This sandbox's egress proxy stalls
// Gradle's downloads from storage.googleapis.com, while curl fetches the
// same files in under a second — so the engine jars are pre-downloaded
// into ~/workspace/local-maven and resolved from disk. PREFER_SETTINGS
// keeps the project's own repositories (including the Flutter engine
// repo) as a fallback for everything else.
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        maven { url = uri("file:///home/hatch/workspace/local-maven") }
        google()
        mavenCentral()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
