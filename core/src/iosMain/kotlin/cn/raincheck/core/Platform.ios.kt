package cn.raincheck.core

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.engine.darwin.Darwin
import platform.Foundation.NSDate
import platform.Foundation.NSHTTPCookieAcceptPolicy
import platform.Foundation.NSUUID
import platform.Foundation.timeIntervalSince1970

internal actual fun createPlatformHttpClient(config: HttpClientConfig<*>.() -> Unit): HttpClient =
    HttpClient(Darwin) {
        engine {
            configureSession {
                HTTPCookieStorage = null
                HTTPShouldSetCookies = false
                HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicy.NSHTTPCookieAcceptPolicyNever
                URLCache = null
            }
        }
        config()
    }

actual fun nowMillis(): Long = (NSDate().timeIntervalSince1970 * 1000.0).toLong()

actual fun randomId(): String = NSUUID().UUIDString
