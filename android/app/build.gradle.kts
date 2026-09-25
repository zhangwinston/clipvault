plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.clipvault.clipvault"
    // receive_sharing_intent 1.9.0 的 AAR 要求 compileSdk ≥ 37
    // （高于 flutter.compileSdkVersion=36，需 AGP ≥ 9.4，见 settings.gradle.kts）
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications 依赖 java.time 等 API：
        // minSdk 低于 26 的设备需 core library desugaring（插件官方要求）
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.clipvault.clipvault"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // 单 APK 瘦身：仅保留真机 ARM ABI。x86_64 仅供模拟器（media_kit
        // 的 libmpv 按 ABI 重复打包，是包体大头）；保留 armeabi-v7a 兼容
        // 32 位老设备。
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a")
        }
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

    packaging {
        jniLibs {
            // APK 内压缩 native 库（AGP 默认不压缩、页对齐直读）：libmpv 等
            // .so 压缩后下载体积约降四成；代价是安装时解压到 /data、启动
            // 略慢——侧载分发场景下载体积优先。
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

flutter {
    source = "../.."
}
