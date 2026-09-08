import java.security.KeyStore
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Release channel this APK is built for. CI exports it as an environment
// variable holding the same value it passes to Dart through
// --dart-define=BUILD_CHANNEL; a local build, which sets neither, falls back to
// "nightly" exactly like lib/core/constants/build_channel.dart does.
val buildChannel: String =
    System.getenv("BUILD_CHANNEL")?.takeIf { it.isNotBlank() }?.trim()?.lowercase()
        ?: "nightly"

// Every channel gets its own applicationId so stable / staging / nightly can be
// installed next to each other on one device. All three are still signed with
// the same CI keystore — Android refuses to co-install packages that share an
// applicationId, not ones that share a signing certificate.
val channelApplicationIdSuffix = when (buildChannel) {
    "stable" -> ""
    "staging" -> ".staging"
    else -> ".nightly"
}

// Launcher label, so three icons on the home screen are told apart.
val channelAppLabel = when (buildChannel) {
    "stable" -> "Glaze"
    "staging" -> "Glaze Staging"
    else -> "Glaze Nightly"
}

// CI signing: the keystore is passed in as base64 through KEYSTORE_BASE64.
// An *unset* secret still reaches Gradle as an empty string, so blank must be
// treated exactly like "no CI keystore" — otherwise we write a 0-byte file and
// AGP fails deep inside the DER parser ("Tag number over 30 is not supported")
// with no hint about the real cause.
val ciKeystoreBase64: String? =
    System.getenv("KEYSTORE_BASE64")?.filterNot { it.isWhitespace() }?.ifEmpty { null }

// Store password, key alias and key password come from secrets too, so they are
// subject to the same empty-string-instead-of-null trap.
fun requireCiEnv(name: String): String =
    System.getenv(name)?.takeIf { it.isNotBlank() } ?: throw GradleException(
        "KEYSTORE_BASE64 is set but $name is empty — CI signing needs the store password, " +
            "key alias and key password (secrets ANDROID_STORE_PASSWORD, ANDROID_KEY_ALIAS, " +
            "ANDROID_KEY_PASSWORD).",
    )

fun decodeCiKeystore(base64: String): ByteArray {
    val bytes = try {
        Base64.getMimeDecoder().decode(base64)
    } catch (e: IllegalArgumentException) {
        throw GradleException(
            "KEYSTORE_BASE64 is not valid base64 (${e.message}). Re-create the ANDROID_KEYSTORE_BASE64 " +
                "secret from the raw keystore bytes:\n" +
                "  [Convert]::ToBase64String([IO.File]::ReadAllBytes(\"<keystore>\")) | Set-Clipboard",
        )
    }
    if (bytes.isEmpty()) {
        throw GradleException("KEYSTORE_BASE64 decodes to 0 bytes — the secret is empty or truncated.")
    }
    return bytes
}

fun verifyCiKeystore(ksFile: File, storePassword: String, keyAlias: String) {
    var lastError: Exception? = null
    // PKCS12 first (keytool's default since JDK 9), JKS for older keystores.
    val store = listOf("pkcs12", "jks").firstNotNullOfOrNull { type ->
        try {
            KeyStore.getInstance(type).also { ks ->
                ksFile.inputStream().use { ks.load(it, storePassword.toCharArray()) }
            }
        } catch (e: Exception) {
            lastError = e
            null
        }
    } ?: throw GradleException(
        "Cannot read the keystore decoded from KEYSTORE_BASE64 (${ksFile.length()} bytes): ${lastError?.message}\n" +
            "The secret is either corrupted (re-encoded as text instead of raw bytes) or was created " +
            "with a different store password than KEYSTORE_PASSWORD.",
        lastError,
    )
    if (!store.containsAlias(keyAlias)) {
        throw GradleException(
            "Keystore has no alias \"$keyAlias\". Available aliases: " +
                store.aliases().toList().joinToString(", ").ifEmpty { "<none>" },
        )
    }
}

android {
    namespace = "app.glaze.flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    signingConfigs {
        create("ci") {
            val base64 = ciKeystoreBase64
            if (base64 != null) {
                val ksPassword = requireCiEnv("KEYSTORE_PASSWORD")
                val ksAlias = requireCiEnv("KEY_ALIAS")
                val ksFile = rootProject.file("ci-signing.keystore")
                ksFile.writeBytes(decodeCiKeystore(base64))
                verifyCiKeystore(ksFile, ksPassword, ksAlias)
                storeFile = ksFile
                storePassword = ksPassword
                keyAlias = ksAlias
                keyPassword = requireCiEnv("KEY_PASSWORD")
            }
        }
    }

    defaultConfig {
        applicationId = "app.glaze.flutter$channelApplicationIdSuffix"
        manifestPlaceholders["appLabel"] = channelAppLabel
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            signingConfig = if (ciKeystoreBase64 != null) {
                signingConfigs.getByName("ci")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (ciKeystoreBase64 != null) {
                signingConfigs.getByName("ci")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
