plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.muzhao.muzhao"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // 阶段 2 由主会话按 CLAUDE.md 7.5 的跨界请求流程代 release 加入。
    //
    // 起因：pub 插件 onnxruntime:1.4.1 的 jniLibs 只带 arm64-v8a / armeabi-v7a，
    // 没有 x86_64；而本机两台 AVD 都是 x86_64，不补这个库 G2A 在模拟器上必然
    // 起不来（不是模型的问题，是找不到 .so）。ml-porting 已把官方 ORT 1.15.1
    // 的 x86_64 libonnxruntime.so 放进 native/android/jniLibs/。
    //
    // 这是**为了让模拟器能跑通验收**而加的开发期依赖。release 在阶段 5 必须复核：
    // 用 abiFilters 把 x86/x86_64 从发布包里排掉，否则平白多 16MB（G5.5 限 60MB）。
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs", "../../native/android/jniLibs")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.muzhao.muzhao"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
