allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// env-setup workaround (2026-09-08): pub 插件 onnxruntime 1.4.1 在自己的
// android/build.gradle 里硬编码了 `compileSdkVersion 33`（在 apply plugin 之后
// 才设置，所以早于该行的 plugins.withId 回调会被它自己的脚本覆盖回 33），
// 而它引入的 androidx 依赖（fragment/window/lifecycle/exifinterface 等）要求
// compileSdk >= 34，导致 `:onnxruntime:checkDebugAarMetadata` 失败。
// 上游插件本身在 pub cache 里没法改，这里只对 :onnxruntime 这一个子项目注册
// afterEvaluate（此时它自己的脚本已跑完，compileSdkVersion 33 已生效，我们
// 再强制改回 36，和 app 的 flutter.compileSdkVersion 保持一致）。只影响编译期
// API 校验，不影响 minSdk/targetSdk 运行时行为。只对这一个子项目注册，避免
// "Cannot run Project.afterEvaluate(Action) when the project is already
// evaluated" —— 那个错误是对所有 subprojects 通用注册时，某些子项目已经因为
// evaluationDependsOn 被提前 eval 完导致的。
// release agent 在阶段 5 做包体积/依赖精简时如果替换掉 onnxruntime 插件，
// 可以视情况移除这段。
subprojects {
    if (project.path == ":onnxruntime") {
        project.afterEvaluate {
            val ext = project.extensions.findByName("android")
            if (ext is com.android.build.gradle.LibraryExtension) {
                ext.compileSdk = 36
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
