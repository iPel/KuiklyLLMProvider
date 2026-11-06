plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "com.example.kuiklyllmprovider"
    compileSdk = 34
    defaultConfig {
        applicationId = "com.example.kuiklyllmprovider"
        minSdk = 23
        targetSdk = 34   // 与 compileSdk 保持一致
        versionCode = 1
        versionName = "1.0"
    }

    androidResources {
        // bundled 变体含 378MB 模型分卷；不压缩二进制资产，
        // 避免 compressDebugAssets 压缩大文件时 Java heap 溢出。
        noCompress.addAll(listOf("bin", "gguf"))
    }

    buildTypes {
        getByName("release") {
            // 缺 Kuikly keep 规则会让 R8 破坏按字符串名注册的 Module / Pager，故不开启 minify。
            isMinifyEnabled = false
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
}

dependencies {
    implementation(project(":shared"))
    // 壳工程只依赖 Android 原生层 artifact；KMP 契约层由 shared 传递
    implementation(project(":KuiklyLLMProviderAndroid"))
    implementation("androidx.recyclerview:recyclerview:1.2.1")
    implementation("androidx.appcompat:appcompat:1.3.1")
    implementation("com.squareup.picasso:picasso:2.71828")
    implementation("androidx.core:core-ktx:1.6.0")
    implementation("androidx.dynamicanimation:dynamicanimation:1.0.0")
    implementation("com.github.bumptech.glide:glide:4.12.0")
    annotationProcessor("com.github.bumptech.glide:compiler:4.12.0")
}
