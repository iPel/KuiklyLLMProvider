plugins {
    //trick: for the same plugin versions in all sub-modules
    id("com.android.application").version("8.2.2").apply(false)
    id("com.android.library").version("8.2.2").apply(false)
    kotlin("android").version("2.1.21").apply(false)
    kotlin("multiplatform").version("2.1.21").apply(false)
    id("com.google.devtools.ksp").version("2.1.21-2.0.1").apply(false)
    id("org.jetbrains.compose").version("1.7.3").apply(false)
    kotlin("plugin.compose").version("2.1.21").apply(false)
}

buildscript {
    dependencies {
        classpath(BuildPlugin.kuikly)
        // Kotlin 2.1 的 metadata 需要 R8 >= 8.6.17；AGP 8.2.2 自带 8.2.47。
        classpath("com.android.tools:r8:8.6.17")
    }
}
