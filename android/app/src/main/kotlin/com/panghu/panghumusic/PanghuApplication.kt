package com.panghu.panghumusic

import android.app.Application

class PanghuApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AndroidCrashHandler.install(this)
    }
}
