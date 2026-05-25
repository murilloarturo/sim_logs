plugins {
    id("com.android.application")
}

android {
    namespace = "com.simconsole.demo"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.simconsole.demo"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        getByName("debug") {
            isDebuggable = true
        }
        getByName("release") {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        viewBinding = true
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    // OkHttp drives the network demo button. Real apps will likely use
    // Retrofit / Ktor on top — both ride on OkHttp.
    implementation("com.squareup.okhttp3:okhttp:5.3.2")

    // Debug-only: the SimConsole SDK + interceptor. `debugImplementation`
    // keeps everything out of release builds.
    debugImplementation("com.simconsole:simconsole:0.1.0")
}
