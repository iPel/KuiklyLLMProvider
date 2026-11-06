package com.kuikly.llmprovider

import java.io.File
import java.io.FileOutputStream

/** bundled 变体：把 assets/model_parts 合并成可直接 mmap 的文件。 */
internal object BundledPartsInstaller {
    fun install(s: ModelStore) {
        val e = s.catalog.firstOrNull { it.bundled } ?: return
        val f = s.path(e)
        // 已合并过：最终路径只经「严格校验后原子 rename」写入，这里只做轻量判定。
        if (s.isPlausible(f, e)) return
        val names = try {
            (s.ctx.assets.list("model_parts") ?: emptyArray()).filter { it.endsWith(".bin") }.sorted()
        } catch (ex: Exception) { emptyList() }
        if (names.isEmpty()) return
        val tmp = File(s.dir, e.file + ".merging")
        try {
            FileOutputStream(tmp, false).use { out ->
                names.forEach { n -> s.ctx.assets.open("model_parts/$n").use { it.copyTo(out) } }
            }
            if (s.verify(tmp, e)) {
                if (!s.moveIntoPlace(tmp, f)) { tmp.delete(); s.lastError = "bundled model install failed" }
            } else {
                tmp.delete(); s.lastError = "bundled model verification failed"
            }
        } catch (ex: Exception) {
            tmp.delete(); s.lastError = ex.message ?: "part merge failed"
        }
    }
}
