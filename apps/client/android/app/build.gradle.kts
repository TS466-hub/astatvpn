import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "shop.autohitech.astatvpn"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "shop.autohitech.astatvpn"
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

    // геобазы ядра: без сжатия копируются на устройство быстрее
    androidResources {
        noCompress += "dat"
    }

    // отдельный APK под каждую архитектуру: ядро занимает около 30 МБ на каждую
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "armeabi-v7a", "x86_64")
            isUniversalApk = true
        }
    }

    // Постоянный ключ подписи лежит вне репозитория. Где искать его описание (key.properties):
    // переменная ASTAT_KEY_PROPERTIES, затем android/key.properties, затем ~/.astatvpn/key.properties.
    // Без ключа сборка подписывается отладочным: такой APK не обновит установленный с другим ключом.
    val keyPropsFile = listOfNotNull(
        System.getenv("ASTAT_KEY_PROPERTIES")?.takeIf { it.isNotBlank() }?.let { file(it) },
        rootProject.file("key.properties"),
        File(System.getProperty("user.home"), ".astatvpn/key.properties"),
    ).firstOrNull { it.isFile }
    val keyProps = Properties().apply { keyPropsFile?.inputStream()?.use { load(it) } }

    signingConfigs {
        if (keyPropsFile != null) {
            create("release") {
                // путь к хранилищу в key.properties считается от каталога самого key.properties
                storeFile = keyPropsFile.parentFile.resolve(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (keyPropsFile != null) "release" else "debug")
            if (keyPropsFile == null) logger.warn("AstatVPN: постоянного ключа подписи нет, сборка подписана отладочным ключом")
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

dependencies {
    // ядро Xray: собирается скриптом tool/build_core_android.sh, в git не хранится
    implementation(files("libs/libXray.aar"))
    implementation("androidx.core:core-ktx:1.15.0")
}
