package com.ppfriend.pp_friend

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 读取当前活动网络（通常是 Wi-Fi）上配置的系统代理。
 *
 * Dart 的 `HttpClient` 默认是 DIRECT，不会自动使用 Android Wi-Fi 设置里的
 * 自定义代理。这里把 host/port 交给 Dart 侧，由 `HttpClient.findProxy`
 * 显式走 PROXY，Base URL 的请求才会经过用户在 Wi-Fi 里填的代理。
 */
class ProxyPlugin private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        private const val CHANNEL = "com.ppfriend.pp_friend/proxy"

        fun registerWith(messenger: BinaryMessenger, context: Context) {
            MethodChannel(messenger, CHANNEL).setMethodCallHandler(
                ProxyPlugin(context.applicationContext),
            )
        }
    }

    @Suppress("DEPRECATION")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getProxy") {
            result.notImplemented()
            return
        }

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
            as? ConnectivityManager
        if (cm == null) {
            result.success(null)
            return
        }

        // getLinkProperties(activeNetwork) 是当前 Wi-Fi 链路上的代理；
        // defaultProxy 是全局兜底，部分 ROM 只更新后者。
        val proxy = cm.activeNetwork
            ?.let { cm.getLinkProperties(it) }
            ?.httpProxy
            ?: cm.defaultProxy

        // 少数 ROM 的 Wi-Fi 代理只写进 Java 系统属性，ProxyInfo 是空的。
        val host = proxy?.host?.takeIf { it.isNotBlank() }
            ?: System.getProperty("http.proxyHost")
        val port = proxy?.port?.takeIf { it > 0 }
            ?: System.getProperty("http.proxyPort")?.toIntOrNull()
            ?: 0
        if (host.isNullOrBlank() || port <= 0) {
            result.success(null)
        } else {
            result.success(mapOf("host" to host, "port" to port))
        }
    }
}
