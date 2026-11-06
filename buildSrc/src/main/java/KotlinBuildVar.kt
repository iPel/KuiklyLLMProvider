object Version {

    // Kuikly 2.30.0 起 NetworkModule 提供 httpStreamRequest；这是本库的最低版本要求。
    private const val KUIKLY_VERSION = "2.30.0"
    private const val KOTLIN_VERSION = "2.1.21"

    fun getKuiklyVersion(): String {
        return "$KUIKLY_VERSION-$KOTLIN_VERSION"
    }
}

object BuildPlugin {
    val kuikly by lazy {
        "com.tencent.kuikly-open:core-gradle-plugin:${Version.getKuiklyVersion()}"
    }
}
