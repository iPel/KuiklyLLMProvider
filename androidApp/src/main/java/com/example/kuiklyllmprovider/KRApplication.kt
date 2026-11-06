package com.example.kuiklyllmprovider

import android.app.Application

class KRApplication : Application() {

    init {
        application = this
    }

    companion object {
        lateinit var application: Application
    }
}
