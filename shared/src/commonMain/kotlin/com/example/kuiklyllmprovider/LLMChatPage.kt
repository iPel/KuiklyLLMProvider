package com.example.kuiklyllmprovider

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import com.example.kuiklyllmprovider.base.BridgeModule
import com.kuikly.llmprovider.LLMProviderModule
import com.tencent.kuikly.compose.ComposeContainer
import com.tencent.kuikly.compose.setContent
import com.tencent.kuikly.core.annotations.Page
import com.tencent.kuikly.core.module.Module


@Page("LLMChat")
internal class LLMChatPage : ComposeContainer() {

    override fun createExternalModules(): Map<String, Module>? = mapOf(
        BridgeModule.MODULE_NAME to BridgeModule(),
        LLMProviderModule.MODULE_NAME to LLMProviderModule(),
    )

    override fun willInit() {
        super.willInit()
        setContent {
            LLMChatScreen()
        }
    }
}
