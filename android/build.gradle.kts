group = "app.xyz.everydayapp.syncing_keys"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "app.xyz.everydayapp.syncing_keys"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24

        // Ship our consumer ProGuard rules with the AAR so host apps that
        // enable R8 in release builds don't strip GMS / Tink classes.
        consumerProguardFiles("consumer-rules.pro")
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // EncryptedSharedPreferences — Keystore-backed local store.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Google Sign-In + OAuth token retrieval for the Drive REST API.
    implementation("com.google.android.gms:play-services-auth:21.2.0")

    // OkHttp for the Drive REST multipart upload (lightweight; no Drive SDK).
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // Kotlin coroutines — Drive calls run off the main thread.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // JSON for envelope wrapping the Drive multipart metadata.
    implementation("org.json:json:20240303")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
