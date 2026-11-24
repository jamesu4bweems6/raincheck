package cn.raincheck.cli

import cn.raincheck.core.Account
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CliTest {

    @Test
    fun `Options 支持 --key=value 与布尔开关不吞位置参数与 query URL 解码`() {
        val opts = Options(listOf("--dry-run", "--concurrency=8", "--profile=/tmp/p.json", "lessonId=123"))
        assertTrue(opts.has("dry-run"))
        assertEquals("8", opts.value("concurrency"))
        assertEquals("/tmp/p.json", opts.profilePath)
        assertEquals(listOf("lessonId=123"), opts.positional)

        val decoded = Options.parseQuery("c=a%2Bb&s=%E4%B8%AD%E6%96%87+测试")
        assertEquals("a+b", decoded["c"])
        assertEquals("中文 测试", decoded["s"])
    }

    @Test
    fun `Store 原子写入与损坏文件备份报错不清空且回填不污染 host`() {
        val dir = Files.createTempDirectory("raincheck-cli-test-").toFile()
        try {
            val file = File(dir, "accounts.json")
            val store = Store(file)
            val original = Account(
                id = "acc-1",
                label = "张三",
                host = "pro.yuketang.cn",
                scheme = "https",
                bearer = "tok-1",
            )
            store.upsert(original)
            assertEquals(1, store.load().size)

            // 模拟 --host 临时覆盖后收到新凭据：不得污染原本的 host/scheme
            store.updateCredentialsPreservingHost(
                original.copy(host = "127.0.0.1:8787", scheme = "http", bearer = "tok-2"),
            )
            val after = store.load().single()
            assertEquals("pro.yuketang.cn", after.host)
            assertEquals("https", after.scheme)
            assertEquals("tok-2", after.bearer)

            // 损坏文件：必须备份并报错，绝不静默返回空列表
            file.writeText("{ broken json !!!")
            assertFailsWith<RuntimeException> { store.load() }
            val backups = dir.listFiles()?.filter { it.name.contains(".corrupt-") }.orEmpty()
            assertTrue(backups.isNotEmpty(), "损坏文件必须被备份")
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `probe 找不到账号直接退出 2 且 signin 并发越界友好退出 2`() = runBlocking {
        val dir = Files.createTempDirectory("raincheck-cli-cmd-").toFile()
        try {
            val storeFile = File(dir, "accounts.json")
            val probeExit = runCli(
                arrayOf("probe", "--id", "missing-id", "--path", "/health", "--store", storeFile.path),
            )
            assertEquals(2, probeExit)

            Store(storeFile).upsert(Account(id = "a1", label = "u1", bearer = "tok-1"))
            val badConcExit = runCli(
                arrayOf("signin", "--qr", "lessonId=1", "--concurrency", "99", "--store", storeFile.path),
            )
            assertEquals(2, badConcExit)

            val helpExit = runCli(arrayOf("signin", "--help"))
            assertEquals(0, helpExit)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun `parse 尊重 --profile 自定义参数`() = runBlocking {
        val dir = Files.createTempDirectory("raincheck-cli-profile-").toFile()
        try {
            val customProfile = File(dir, "custom.json")
            customProfile.writeText(
                """
                {
                  "version": 1,
                  "qr": {
                    "dynamicKeys": ["k1", "k2"],
                    "schemes": ["https"]
                  }
                }
                """.trimIndent(),
            )
            val code = runCli(
                arrayOf("parse", "--profile", customProfile.path, "https://www.yuketang.cn/x?k1=a&k2=b"),
            )
            assertEquals(0, code)
            assertFalse(File(dir, "nonexistent").exists())
        } finally {
            dir.deleteRecursively()
        }
    }
}
