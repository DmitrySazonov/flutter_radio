import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_radio" // ← замени на свой пакет, если нужно
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.flutter_radio" // ← тоже под себя
        minSdk = flutter.minSdkVersion
        targetSdk = 36
        versionCode = 12000
        versionName = "1.2.0"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        create("release") {
            val props = Properties()
            props.load(FileInputStream(rootProject.file("key.properties")))
            storeFile = file(props["storeFile"]!!)
            storePassword = props["storePassword"] as String
            keyAlias = props["keyAlias"] as String
            keyPassword = props["keyPassword"] as String
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Обычно ничего не нужно добавлять, но если ругнется на kotlin-stdlib, раскомментируй:
// dependencies {
//     implementation("org.jetbrains.kotlin:kotlin-stdlib")
// }
