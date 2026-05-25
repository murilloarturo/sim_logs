pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // Picks up com.simconsole:simconsole published by `./android/gradlew :simconsole:publishToMavenLocal`.
        mavenLocal()
    }
}

rootProject.name = "DemoAppAndroid"
include(":app")
