package com.example.kuiklyllmprovider.adapter

import android.graphics.Typeface
import com.tencent.kuikly.core.render.android.adapter.IKRFontAdapter

object KRFontAdapter : IKRFontAdapter {
    override fun getTypeface(fontFamily: String, result: (Typeface?) -> Unit) {
        result(null)
    }
}
