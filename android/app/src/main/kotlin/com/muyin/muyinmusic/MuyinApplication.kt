package com.muyin.muyinmusic

import android.app.Application

class MuyinApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AndroidCrashHandler.install(this)
    }
}
