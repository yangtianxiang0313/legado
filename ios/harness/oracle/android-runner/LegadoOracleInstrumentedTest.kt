package io.legado.app.oracle

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.webBook.WebBook
import io.legado.app.utils.GSON
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LegadoOracleInstrumentedTest {
    private val arguments = InstrumentationRegistry.getArguments()
    private val logicalOrigin = requiredArgument("logicalOrigin").trimEnd('/')
    private val sourceJson = String(
        Base64.decode(requiredArgument("sourceBase64"), Base64.DEFAULT),
        Charsets.UTF_8
    )
    private val source = GSON.fromJson(sourceJson, BookSource::class.java)
    private val deviceOrigin = source.bookSourceUrl.trimEnd('/')
    private val cases = JSONArray()
    private val requestPlan = JSONArray()

    @Test
    fun runSourceLabCharacterization() = runBlocking {
        require(deviceOrigin.startsWith("http://127.0.0.1:")) {
            "Oracle source must use the run-scoped device loopback origin"
        }
        source.enabledCookieJar = false

        runCase("search-hit", "search", searchRequest("星河")) {
            searchProjection(WebBook.searchBookAwait(source, "星河"))
        }
        runCase("search-empty", "search", searchRequest("不存在")) {
            searchProjection(WebBook.searchBookAwait(source, "不存在"))
        }
        runCase(
            "book-detail",
            "book_info",
            request("$deviceOrigin/books/star-river/index.html")
        ) {
            bookProjection(
                WebBook.getBookInfoAwait(
                    source,
                    Book(
                        bookUrl = "$deviceOrigin/books/star-river/index.html",
                        origin = source.bookSourceUrl,
                        originName = source.bookSourceName
                    )
                )
            )
        }
        runCase(
            "book-detail-missing-cover",
            "book_info",
            request("$deviceOrigin/books/no-cover/index.html")
        ) {
            bookProjection(
                WebBook.getBookInfoAwait(
                    source,
                    Book(
                        bookUrl = "$deviceOrigin/books/no-cover/index.html",
                        origin = source.bookSourceUrl,
                        originName = source.bookSourceName
                    )
                )
            )
        }
        runCase(
            "toc",
            "chapters",
            request("$deviceOrigin/books/star-river/toc.html")
        ) {
            val book = Book(
                bookUrl = "$deviceOrigin/books/star-river/index.html",
                tocUrl = "$deviceOrigin/books/star-river/toc.html",
                origin = source.bookSourceUrl,
                originName = source.bookSourceName,
                name = "星河纪事"
            )
            chapterProjection(
                WebBook.getChapterListAwait(source, book).getOrThrow()
            )
        }
        runCase(
            "toc-empty",
            "chapters",
            request("$deviceOrigin/books/no-cover/toc.html")
        ) {
            val book = Book(
                bookUrl = "$deviceOrigin/books/no-cover/index.html",
                tocUrl = "$deviceOrigin/books/no-cover/toc.html",
                origin = source.bookSourceUrl,
                originName = source.bookSourceName,
                name = "无封面之书"
            )
            chapterProjection(
                WebBook.getChapterListAwait(source, book).getOrThrow()
            )
        }
        runCase(
            "chapter",
            "content",
            request("$deviceOrigin/books/star-river/chapter-1.html")
        ) {
            contentProjection("chapter-1.html", 0)
        }
        runCase(
            "chapter-second",
            "content",
            request("$deviceOrigin/books/star-river/chapter-2.html")
        ) {
            contentProjection("chapter-2.html", 1)
        }

        val raw = JSONObject()
            .put("schema_version", 1)
            .put("scenario_id", "sl-html-basic-001")
            .put("device_origin", deviceOrigin)
            .put("logical_origin", logicalOrigin)
            .put("request_plan", requestPlan)
            .put("cases", cases)
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        File(target.filesDir, OUTPUT_FILE).writeText(raw.toString(), Charsets.UTF_8)
    }

    private suspend fun contentProjection(
        relativeURL: String,
        index: Int
    ): JSONObject {
        val book = Book(
            bookUrl = "$deviceOrigin/books/star-river/index.html",
            tocUrl = "$deviceOrigin/books/star-river/toc.html",
            origin = source.bookSourceUrl,
            originName = source.bookSourceName,
            name = "星河纪事"
        )
        val chapter = BookChapter(
            url = relativeURL,
            title = "",
            baseUrl = "$deviceOrigin/books/star-river/toc.html",
            bookUrl = book.bookUrl,
            index = index
        )
        val value = WebBook.getContentAwait(
            source,
            book,
            chapter,
            needSave = false
        )
        return JSONObject()
            .put("content", value.replace(deviceOrigin, logicalOrigin))
            .put("chapter_url", logical(chapter.getAbsoluteURL()))
    }

    private suspend fun runCase(
        id: String,
        operation: String,
        request: JSONObject,
        execute: suspend () -> JSONObject
    ) {
        requestPlan.put(request)
        val record = JSONObject()
            .put("id", id)
            .put("operation", operation)
            .put("request", request)
        try {
            record
                .put("result", execute())
                .put("issue", JSONObject.NULL)
        } catch (error: Throwable) {
            record
                .put("result", JSONObject.NULL)
                .put(
                    "issue",
                    JSONObject()
                        .put("code", "android_exception")
                        .put("exception_type", error.javaClass.name)
                )
        }
        cases.put(record)
    }

    private fun searchRequest(keyword: String): JSONObject {
        val analyze = AnalyzeUrl(
            mUrl = requireNotNull(source.searchUrl),
            key = keyword,
            page = 1,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        return request(analyze.url)
    }

    private fun request(url: String): JSONObject =
        JSONObject()
            .put("method", "GET")
            .put("url", logical(url))
            .put("headers", JSONArray())
            .put("body", JSONObject.NULL)
            .put("timeout_ms", JSONObject.NULL)

    private fun searchProjection(values: List<SearchBook>): JSONObject =
        JSONObject().put(
            "books",
            JSONArray().apply {
                values.forEach { value ->
                    put(
                        JSONObject()
                            .put("name", value.name)
                            .put("author", value.author)
                            .put("kind", nullable(value.kind))
                            .put("intro", nullable(value.intro))
                            .put("last_chapter", nullable(value.latestChapterTitle))
                            .put("book_url", logical(value.bookUrl))
                            .put("cover_url", nullableURL(value.coverUrl))
                    )
                }
            }
        )

    private fun bookProjection(value: Book): JSONObject =
        JSONObject()
            .put("name", value.name)
            .put("author", value.author)
            .put("kind", nullable(value.kind))
            .put("intro", nullable(value.intro))
            .put("last_chapter", nullable(value.latestChapterTitle))
            .put("book_url", logical(value.bookUrl))
            .put("toc_url", logical(value.tocUrl))
            .put("cover_url", nullableURL(value.coverUrl))

    private fun chapterProjection(values: List<BookChapter>): JSONObject =
        JSONObject().put(
            "chapters",
            JSONArray().apply {
                values.forEach { value ->
                    put(
                        JSONObject()
                            .put("index", value.index)
                            .put("title", value.title)
                            .put("url", logical(value.getAbsoluteURL()))
                            .put("is_volume", value.isVolume)
                            .put("is_vip", value.isVip)
                            .put("is_pay", value.isPay)
                    )
                }
            }
        )

    private fun nullable(value: String?): Any =
        value ?: JSONObject.NULL

    private fun nullableURL(value: String?): Any =
        value?.let(::logical) ?: JSONObject.NULL

    private fun logical(value: String): String =
        if (value.startsWith(deviceOrigin)) {
            logicalOrigin + value.removePrefix(deviceOrigin)
        } else {
            value
        }

    private fun requiredArgument(name: String): String =
        requireNotNull(arguments.getString(name)) {
            "Missing instrumentation argument: $name"
        }

    companion object {
        const val OUTPUT_FILE = "legado-oracle-raw.json"
    }
}
