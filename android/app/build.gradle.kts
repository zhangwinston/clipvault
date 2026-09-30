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
        // 单 APK 瘦身：仅 arm64-v8a（用户决策：放弃 32 位老机型）。
        // media_kit 的 libmpv 按 ABI 重复打包，是包体大头；x86_64 仅模拟器
        // 需要。如需恢复老设备支持，加回 "armeabi-v7a" 即可。
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // CI 专用签名（§4.7-①固定签名钥）：runner 每次冷启动重新生成 debug
        // keystore → 每个 continuous APK 签名都不同 → 卸载重装后公共
        // Downloads 里的备份文件所有权不归属新安装（恢复失效），且无法
        // 覆盖安装升级（必须先卸载）。CI 经 secrets 注入固定 keystore 到
        // 本路径；文件不存在（本地构建/未配置）时回落 debug 签名。
        create("ci") {
            val ksFile = rootProject.file("app/clipvault-ci.jks")
            if (ksFile.exists()) {
                storeFile = ksFile
                storePassword = System.getenv("CV_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("CV_KEY_ALIAS") ?: "clipvault"
                keyPassword =
                    System.getenv("CV_KEY_PASSWORD")
                        ?: System.getenv("CV_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (rootProject.file("app/clipvault-ci.jks").exists()) {
                signingConfigs.getByName("ci")
            } else {
                // 本地构建/未注入 keystore：debug 签名（侧载可用）
                signingConfigs.getByName("debug")
            }
        }
    }

    packaging {
        jniLibs {
            // APK 内压缩 native 库（AGP 默认不压缩、页对齐直读）：libmpv 等
            // .so 压缩后下载体积约降四成；代价是安装时解压到 /data、启动
            // 略慢——侧载分发场景下载体积优先。
            useLegacyPackaging = true
            // AGP 打包层硬过滤：--target-platform android-arm64 只管 Flutter
            // 产物（libapp/libflutter），media_kit 以 jar 依赖（fileTree）引入
            // 的 .so 不受 ndk.abiFilters 约束（实测 v7a/x86_64 半套仍入包），
            // 此处按 APK 内路径强制剔除。恢复多 ABI 时删除这三行。
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
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
