plugins {
    id("com.android.library")
    `maven-publish`
}

android {
    namespace = "com.simconsole"
    compileSdk = 35

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    // OkHttp is `compileOnly`: SimConsoleInterceptor only makes sense in an app
    // that already uses OkHttp (directly, or via Retrofit / Ktor's OkHttp engine).
    // Pinning here would shadow the host's version on the classpath — host apps
    // bring their own at runtime. Aligned to the version luzia-android uses.
    compileOnly("com.squareup.okhttp3:okhttp:5.3.2")

    // Unit tests run on the host JVM where android.jar's `org.json` is stubbed to
    // return defaults. Pulling in the real implementation lets us parse the JSON
    // our production code emits and assert on its contents directly.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    testImplementation("com.squareup.okhttp3:okhttp:5.3.2")
    testImplementation("com.squareup.okhttp3:mockwebserver3-junit4:5.3.2")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.simconsole"
            artifactId = "simconsole"
            version = "0.1.0"

            afterEvaluate {
                from(components["release"])
            }
        }
    }
}
