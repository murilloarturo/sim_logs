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
    // Unit tests run on the host JVM where android.jar's `org.json` is stubbed to
    // return defaults. Pulling in the real implementation lets us parse the JSON
    // our production code emits and assert on its contents directly.
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
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
