plugins {
    kotlin("multiplatform")
    id("maven-publish")
}

// 由 settings.ohos.gradle.kts 引入（鸿蒙工具链）。
val mavenVersion: String = (findProperty("mavenVersion") as? String)
    ?: (findProperty("MAVEN_VERSION") as? String) ?: "0.1.1"
val publishGroupId: String = (findProperty("groupId") as? String)
    ?: (findProperty("GROUP_ID") as? String) ?: "com.github.iPel.KuiklyLLMProvider"
val mavenRepoUrl: String = (findProperty("mavenRepoUrl") as? String)
    ?: (findProperty("MAVEN_REPO_URL") as? String) ?: ""
val publishToLocal: Boolean = (findProperty("PUB_IS_LOCAL_REPO") as? String) == "true"

group = publishGroupId
version = mavenVersion

kotlin {
    ohosArm64()

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("com.tencent.kuikly-open:core:2.30.0-2.0.21-ohos")
            }
        }
        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
            }
        }
        val ohosMain by creating {
            dependsOn(commonMain)
        }
        val ohosArm64Main by getting {
            dependsOn(ohosMain)
        }
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
