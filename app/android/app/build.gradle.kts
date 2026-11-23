plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma de release (clave de subida de Play). Sale de variables de entorno, nunca del repo:
// RADICI_KEYSTORE_PATH, RADICI_KEYSTORE_PASSWORD, RADICI_KEY_ALIAS, RADICI_KEY_PASSWORD.
// Si faltan, un build local de release firma con la clave de debug y avisa; con
// RADICI_REQUIRE_RELEASE_SIGNING=true (el CI) la falta de variables hace fallar el build.
val releaseSigningVars = listOf(
    "RADICI_KEYSTORE_PATH", "RADICI_KEYSTORE_PASSWORD", "RADICI_KEY_ALIAS", "RADICI_KEY_PASSWORD",
)
val missingSigningVars = releaseSigningVars.filter { System.getenv(it).isNullOrBlank() }
val hasReleaseSigning = missingSigningVars.isEmpty()
val buildsRelease = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (buildsRelease && !hasReleaseSigning) {
    if (System.getenv("RADICI_REQUIRE_RELEASE_SIGNING") == "true") {
        throw GradleException("Falta la firma de release: " + missingSigningVars.joinToString(", "))
    }
    logger.warn(
        "ADVERTENCIA: faltan ${missingSigningVars.joinToString(", ")}. " +
            "El build de release se firma con la clave de DEBUG: no sirve para Play.",
    )
}

android {
    namespace = "app.radicicucina"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.radicicucina"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode/versionName: flutter build --build-number / --build-name (si no, pubspec.yaml).
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(System.getenv("RADICI_KEYSTORE_PATH"))
                storePassword = System.getenv("RADICI_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("RADICI_KEY_ALIAS")
                keyPassword = System.getenv("RADICI_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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
