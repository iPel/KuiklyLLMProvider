plugins {
    kotlin("multiplatform")
    id("com.android.library")
    `maven-publish`
}

val mavenVersion: String = (findProperty("mavenVersion") as? String)
    ?: (findProperty("MAVEN_VERSION") as? String) ?: "0.1.2"
val publishGroupId: String = (findProperty("groupId") as? String)
    ?: (findProperty("GROUP_ID") as? String) ?: "com.github.iPel.KuiklyLLMProvider"
val mavenRepoUrl: String = (findProperty("mavenRepoUrl") as? String)
    ?: (findProperty("MAVEN_REPO_URL") as? String) ?: ""
val publishToLocal: Boolean = (findProperty("PUB_IS_LOCAL_REPO") as? String) == "true"

group = publishGroupId
version = mavenVersion

kotlin {
    androidTarget {
        compilations.all {
            kotlinOptions { jvmTarget = "1.8" }
        }
        publishLibraryVariants("release")
    }

    js(IR) { browser() }
    iosX64()
    iosArm64()
    iosSimulatorArm64()

    sourceSets {
        val commonMain by getting {
            dependencies {
                // 不把 Kuikly SDK 作为传递依赖带给业务方。
                compileOnly("com.tencent.kuikly-open:core:${Version.getKuiklyVersion()}")
                compileOnly("com.tencent.kuikly-open:core-annotations:${Version.getKuiklyVersion()}")
            }
        }
        val commonTest by getting {
            dependencies { implementation(kotlin("test")) }
        }
        val androidMain by getting
        val iosX64Main by getting
        val iosArm64Main by getting
        val iosSimulatorArm64Main by getting
        val iosMain by creating {
            dependsOn(commonMain)
            iosX64Main.dependsOn(this)
            iosArm64Main.dependsOn(this)
            iosSimulatorArm64Main.dependsOn(this)
        }
    }
}

android {
    namespace = "com.kuikly.llmprovider"
    compileSdk = 34
    defaultConfig { minSdk = 23 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

publishing {
    repositories {
        maven {
            url = uri(
                if (!publishToLocal && mavenRepoUrl.isNotBlank()) mavenRepoUrl
                else layout.buildDirectory.dir("repo").get().asFile.toURI()
            )
            if (!publishToLocal && mavenRepoUrl.isNotBlank()) {
                credentials {
                    username = (findProperty("mavenUsername") as? String)
                        ?: (findProperty("MAVEN_USERNAME") as? String) ?: ""
                    password = (findProperty("mavenPassword") as? String)
                        ?: (findProperty("MAVEN_PASSWORD") as? String) ?: ""
                }
            }
        }
    }
}
