// mirrors.tencent.com 是 Kuikly SDK 的必需依赖源，勿移除。
pluginManagement {
    repositories {
        google()
        gradlePluginPortal()
        mavenCentral()
        maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-public/") }
        mavenLocal()
        maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-tencent/") }
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-public/") }
        gradlePluginPortal()
        mavenLocal()
        maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-tencent/") }
    }
}

val ohosBuildfFileName = "build.ohos.gradle.kts"
rootProject.buildFileName = ohosBuildfFileName
rootProject.name = "KuiklyLLMProvider"

include(":shared")
include(":KuiklyLLMProvider")
project(":shared").buildFileName = ohosBuildfFileName
project(":KuiklyLLMProvider").buildFileName = ohosBuildfFileName
