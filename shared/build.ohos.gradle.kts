plugins {
    kotlin("multiplatform")
    id("com.google.devtools.ksp")
    id("org.jetbrains.compose")
    kotlin("plugin.compose")
}

kotlin {
    ohosArm64 {
        // 不指定 binary 名，Gradle task 为 linkDebugSharedOhosArm64、
        // 产物目录为 debugShared/，由 entry/hvigorfile.ts 的内联关联编译 task
        // 按 buildMode 拼接路径并拷回 entry/。
        binaries.sharedLib {
            freeCompilerArgs += "-Xadd-light-debug=enable"
            if (buildType == org.jetbrains.kotlin.gradle.plugin.mpp.NativeBuildType.RELEASE) {
                val clangOpt = "-Os -mllvm -enable-machine-outliner=always -ffunction-sections"
                val clangFlags = "clangOptFlags.ohos_arm64=$clangOpt;clangDebugFlags.ohos_arm64=$clangOpt"
                freeCompilerArgs += "-Xoverride-konan-properties=$clangFlags"
                linkerOpts += "--pack-dyn-relocs=relr"
                linkerOpts += "--gc-sections"
            }
        }
    }

    sourceSets {
        val commonMain by getting {
            dependencies {
                implementation("com.tencent.kuikly-open:core:2.30.0-2.0.21-ohos")
                implementation("com.tencent.kuikly-open:core-annotations:2.30.0-2.0.21-ohos")
                implementation("com.tencent.kuikly-open:compose:2.30.0-2.0.21-ohos")
                // 业务跨端层只依赖 KMP 契约层，不接触任何平台原生实现
                implementation(project(":KuiklyLLMProvider"))
            }
        }
        val commonTest by getting {
            dependencies {
                implementation(kotlin("test"))
            }
        }
    }
}

dependencies {
    add("kspOhosArm64", "com.tencent.kuikly-open:core-ksp:2.30.0-2.0.21-ohos")
}
