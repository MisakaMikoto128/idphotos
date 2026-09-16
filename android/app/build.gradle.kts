import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 阶段 5（release agent）：
//   - applicationId 定为 com.muzhao.idphoto（namespace 仍是 com.muzhao.muzhao，
//     MainActivity/GeneratedPluginRegistrant 不需要动）。
//   - release 只保留 arm64-v8a + armeabi-v7a（pub 插件 onnxruntime:1.4.1 的
//     jniLibs 只有这两个 arm ABI；x86_64 的 libonnxruntime.so 是开发期为
//     x86_64 AVD 从官方 ORT 1.15.1 补的，发布包带它白付 16.5MB）。
//   - 模拟器验证专用通道：环境变量 MUZHAO_EXTRA_ABIS=x86_64 可把 x86_64 加回
//     release（仅本机验证用，正式产物一律不带；示例：
//     MUZHAO_EXTRA_ABIS=x86_64 flutter build apk --release）。
val releaseExtraAbis: List<String> =
    System.getenv("MUZHAO_EXTRA_ABIS")
        ?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() }
        ?: emptyList()

// release 签名：口令在 android/key.properties（已 gitignore，绝不提交）。
// 没有 key.properties 时（如 CI 初次拉取）回退 debug 签名，保证 assembleRelease 不炸。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.isNotEmpty()

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
    // release（阶段 5）已用 buildTypes.release.ndk.abiFilters 把 x86/x86_64 从
    // 发布包排掉；debug 仍带全部 ABI 供模拟器使用。这两个 srcDirs 保留：
    // debug/模拟器验证构建仍需要 x86_64 那份 so。
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs", "../../native/android/jniLibs")
        }
    }

    defaultConfig {
        applicationId = "com.muzhao.idphoto"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // 发布 ABI 白名单（G5.5 包体积：排掉 x86_64 的 libonnxruntime.so 16.5MB）。
            // 必须写在 defaultConfig：Flutter Gradle 插件在 apply 期（早于本 android{} 块）
            // 已把 defaultConfig abiFilters 清空重设为全部三 ABI，**clear() 不能省**——
            // 插件留下的是 arm/arm64/x64 三个元素，直接 addAll 等于没过滤（实测踩过）。
            // 写在 buildTypes.release 无效——AGP 与 defaultConfig 取并集。
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a", "armeabi-v7a"))
        }
    }

    if (hasReleaseKeystore) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // R8 混淆 + 资源收缩：包体与"无多余代码"都是隐私卖点的一部分。
            // keep 规则见 proguard-rules.pro（ONNX FFI 插件的反射路径）。
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // 无 keystore 时回退 debug 签名（与 Flutter 模板默认行为一致），
                // 正式产物必须用 MUZHAO_EXTRA_ABIS 之外的正式流程构建。
                signingConfig = signingConfigs.getByName("debug")
            }
            ndk {
                // 注意：不能在这里写 arm-only —— AGP 把 defaultConfig 与 buildType 的
                // abiFilters 做**并集**，这里加了 x86_64 就挡不住它混进 release。
                // release 的额外 ABI 只经 MUZHAO_EXTRA_ABIS 注入（模拟器验证用）。
                abiFilters.addAll(releaseExtraAbis)
            }
        }
        debug {
            ndk {
                // 本机两台 AVD 都是 x86_64：debug 构建补回 x86_64 供模拟器使用。
                abiFilters.add("x86_64")
            }
        }
    }

    packaging {
        jniLibs {
            // onnxruntime 插件 AAR 与 native/android/jniLibs 可能各带一份同名 so，
            // 撞名直接构建失败，统一取第一份（内容同源于 ORT 1.15.1）。
            pickFirsts += "**/libonnxruntime.so"
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
