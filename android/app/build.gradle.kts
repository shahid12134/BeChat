plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bechat.bechat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.1.12297006"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.bechat.bechat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    // On-device tests for the native identity boundary (Keystore wrapping,
    // envelope validation, identity lifecycle). They drive the production
    // classes directly, so no test-only hooks exist in the app itself.
    // Versions are pinned to the ones the Flutter `integration_test` plugin
    // already puts on the app runtime classpath (androidx.test 1.2.0 /
    // junit 4.12); newer androidx.test releases require junit 4.13, which
    // conflicts with that consistent resolution.
    androidTestImplementation("androidx.test:monitor:1.2.0")
    androidTestImplementation("androidx.test:runner:1.2.0")
    androidTestImplementation("junit:junit:4.12")
}

flutter {
    source = "../.."
}
