// 独立的 Android 原生层 artifact：只含 KuiklyRenderBaseModule 实现与本地 Server，
// 不依赖 KMP 跨端层（契约常量以 AndroidProviderContract 自带，避免两个 artifact 类冲突）。
import java.io.File
import org.gradle.api.tasks.bundling.Zip

plugins {
    id("com.android.library")
    kotlin("android")
    `maven-publish`
}

val providerVariant: String = (findProperty("variant") as? String)
    ?: (findProperty("PROVIDER_VARIANT") as? String) ?: "bundled"
val mavenVersion: String = (findProperty("mavenVersion") as? String)
    ?: (findProperty("MAVEN_VERSION") as? String) ?: "0.1.2"
val publishGroupId: String = (findProperty("groupId") as? String)
    ?: (findProperty("GROUP_ID") as? String) ?: "com.github.iPel.KuiklyLLMProvider"
val mavenRepoUrl: String = (findProperty("mavenRepoUrl") as? String)
    ?: (findProperty("MAVEN_REPO_URL") as? String) ?: ""
val publishToLocal: Boolean = (findProperty("PUB_IS_LOCAL_REPO") as? String) == "true"

// 未 strip 的 native 链接产物由 CMake POST_BUILD 写到模块 build 目录，而不是仓库根的
// dist/symbols/：后者会被任意一次构建覆盖，且 JitPack 远端构建无法写回本机。
val nativeSymbolsDir: File = layout.buildDirectory.dir("native-symbols").get().asFile

group = publishGroupId
version = mavenVersion

android {
    namespace = "com.kuikly.llmprovider.android"
    compileSdk = 34
    // prebuilt/llama/android/*.a 由该 NDK 产出，换版本会引入 c++_static 运行时的 ABI 风险。
    ndkVersion = "26.0.10792818"

    defaultConfig {
        minSdk = 23
        // 仓库只入库 arm64-v8a 的 llama.cpp 静态库；不限制会让 AGP 为四个 ABI
        // 全部触发 CMake，其余三个因缺 .a 直接 FATAL_ERROR。
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                // AAR 只分发一个 .so，宿主无需 libc++_shared.so。
                arguments += "-DANDROID_STL=c++_static"
                // CMake POST_BUILD 的符号输出目录用绝对路径注入，JitPack 与本机行为一致。
                arguments += "-DLLMPROVIDER_SYMBOL_DIR=${nativeSymbolsDir.absolutePath}"
                // 与鸿蒙侧同名，允许 -P 覆盖 llama.cpp 依赖位置。
                listOf("LLMPROVIDER_LLAMA_DIR", "LLMPROVIDER_LLAMA_LIB_DIR").forEach { key ->
                    (project.findProperty(key) as? String)?.takeIf { it.isNotBlank() }?.let {
                        arguments += "-D$key=$it"
                    }
                }
            }
        }
    }

    // 唯一的 native 构建入口：CMake 编译共享 C++ 源码并产出 libllm_provider.so，
    // AGP 自动打包进 AAR 的 jni/arm64-v8a/。src/main/jniLibs/ 不放入库文件，
    // 否则会与 CMake 产物重名，mergeNativeLibs 报 "2 files found with path"。
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions { jvmTarget = "1.8" }

    sourceSets.getByName("main").java.srcDir("src/$providerVariant/java")
}

dependencies {
    implementation("com.tencent.kuikly-open:core-render-android:${Version.getKuiklyVersion()}")
}

val nativeSymbolsZip = tasks.register<Zip>("nativeSymbolsZip") {
    dependsOn("externalNativeBuildRelease")
    from(nativeSymbolsDir) { include("libllm_provider.so.unstripped") }
    archiveFileName.set("native-symbols.zip")
    destinationDirectory.set(layout.buildDirectory.dir("native-symbols-zip"))
    // 符号文件是 POST_BUILD 的副作用，Gradle 无法感知其内容变化，禁用增量以免打包进旧符号文件。
    outputs.upToDateWhen { false }
    doFirst {
        val symbol = File(nativeSymbolsDir, "libllm_provider.so.unstripped")
        check(symbol.isFile && symbol.length() > 0) {
            "缺少未 strip 的 native 符号：$symbol；请确认 externalNativeBuildRelease 已执行 CMake POST_BUILD"
        }
    }
}

afterEvaluate {
    publishing {
        publications {
            // JitPack 以 build/publications/<name>/pom-default.xml 为收集清单，两个变体必须各占一个 publication 名。
            val publicationName = if (providerVariant == "bundled") "releaseBundled" else "releaseDownload"
            create<MavenPublication>(publicationName) {
                from(components["release"])
                groupId = this@afterEvaluate.group.toString()
                artifactId = if (providerVariant == "bundled") "KuiklyLLMProviderAndroid-Bundled" else "KuiklyLLMProviderAndroid"
                version = this@afterEvaluate.version.toString()
                if (providerVariant != "bundled") {
                    artifact(nativeSymbolsZip) {
                        classifier = "native-symbols"
                        extension = "zip"
                    }
                }
            }
        }
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
}
