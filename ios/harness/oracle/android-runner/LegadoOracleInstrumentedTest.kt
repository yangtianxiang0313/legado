package io.legado.app.oracle

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Base64
import android.util.Log
import android.view.View
import android.widget.TextView
import androidx.appcompat.view.menu.MenuBuilder
import androidx.appcompat.widget.SearchView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withId
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import io.legado.app.BuildConfig
import io.legado.app.R
import io.legado.app.constant.AppConst.appInfo
import io.legado.app.constant.BookType
import io.legado.app.constant.PreferKey
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookGroup
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.Bookmark
import io.legado.app.data.entities.BookProgress
import io.legado.app.data.entities.ReadRecord
import io.legado.app.data.entities.ReplaceRule
import io.legado.app.data.entities.SearchBook
import io.legado.app.data.entities.Server
import io.legado.app.data.entities.TxtTocRule
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.data.entities.rule.BookInfoRule
import io.legado.app.data.entities.rule.TocRule
import io.legado.app.data.appDb
import io.legado.app.exception.ConcurrentException
import io.legado.app.help.CacheManager
import io.legado.app.help.AppWebDav
import io.legado.app.help.TTS
import io.legado.app.help.book.BookHelp
import io.legado.app.help.book.ContentProcessor
import io.legado.app.help.book.addType
import io.legado.app.help.book.getLocalUri
import io.legado.app.help.book.isArchive
import io.legado.app.help.book.isLocal
import io.legado.app.help.book.isUpError
import io.legado.app.help.book.removeLocalUriCache
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.LocalConfig
import io.legado.app.help.config.ReadBookConfig
import io.legado.app.help.http.CookieManager
import io.legado.app.help.http.CookieStore
import io.legado.app.help.http.StrResponse
import io.legado.app.help.http.newCallResponse
import io.legado.app.help.storage.Backup
import io.legado.app.help.storage.BackupAES
import io.legado.app.help.storage.Restore
import io.legado.app.lib.webdav.Authorization
import io.legado.app.lib.webdav.WebDav
import io.legado.app.lib.webdav.WebDavFile
import io.legado.app.model.CacheBook
import io.legado.app.model.Debug
import io.legado.app.model.AudioPlay
import io.legado.app.model.ImageProvider
import io.legado.app.model.ReadBook
import io.legado.app.model.analyzeRule.AnalyzeRule
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.RuleData
import io.legado.app.model.webBook.WebBook
import io.legado.app.model.webBook.BookChapterList
import io.legado.app.model.webBook.SearchModel
import io.legado.app.model.localBook.LocalBook
import io.legado.app.service.WebService
import io.legado.app.service.BaseReadAloudService
import io.legado.app.service.TTSReadAloudService
import io.legado.app.ui.book.read.page.entities.TextChapter
import io.legado.app.ui.book.read.page.entities.TextLine
import io.legado.app.ui.book.read.page.entities.TextPage
import io.legado.app.ui.book.read.page.provider.ChapterProvider
import io.legado.app.ui.book.read.ReadBookActivity
import io.legado.app.ui.book.read.ReadBookViewModel
import io.legado.app.ui.book.toc.TocActivityResult
import io.legado.app.ui.book.info.BookInfoActivity
import io.legado.app.ui.book.info.BookInfoViewModel
import io.legado.app.ui.book.changesource.ChangeChapterSourceViewModel
import io.legado.app.ui.main.MainActivity
import io.legado.app.ui.main.MainViewModel
import io.legado.app.ui.main.bookshelf.BookshelfViewModel
import io.legado.app.ui.book.import.local.ImportBookViewModel
import io.legado.app.ui.association.ImportBookSourceViewModel
import io.legado.app.ui.book.search.SearchActivity
import io.legado.app.ui.book.search.SearchScope
import io.legado.app.ui.book.search.SearchViewModel
import io.legado.app.ui.book.source.edit.BookSourceEditViewModel
import io.legado.app.ui.welcome.WelcomeActivity
import io.legado.app.ui.widget.dialog.TextDialog
import io.legado.app.utils.GSON
import io.legado.app.utils.FileDoc
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.defaultSharedPreferences
import io.legado.app.utils.putPrefBoolean
import io.legado.app.utils.compress.ZipUtils
import io.legado.app.web.HttpServer
import io.legado.app.web.WebSocketServer
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.Job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.nodes.Element
import org.junit.Test
import org.junit.runner.RunWith
import org.seimicrawler.xpath.JXNode
import fi.iki.elonen.NanoHTTPD
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.lang.reflect.InvocationTargetException
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.CopyOnWriteArrayList
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine
import okhttp3.OkHttpClient
import okhttp3.Headers
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

@RunWith(AndroidJUnit4::class)
class LegadoOracleInstrumentedTest {
    private val arguments = InstrumentationRegistry.getArguments()
    private val logicalOrigin = requiredArgument("logicalOrigin").trimEnd('/')
    private val scenarioId = requiredArgument("scenarioId")
    private val isAndroidRuntimeScenario = scenarioId.startsWith("rl-")
    private val isIntegrationLabScenario = scenarioId.startsWith("il-")
    private val isRealSourceScenario = scenarioId.startsWith("rs-")
    private val isPlatformIntegrationScenario =
        scenarioId == "il-integration-system-text-to-speech-001"
    private val input = JSONObject(
        String(
            Base64.decode(
                requiredArgument("inputBase64"),
                Base64.DEFAULT
            ),
            Charsets.UTF_8
        )
    )
    private val sourceJson by lazy {
        val encoded = arguments.getString("sourceBase64")
        require(!encoded.isNullOrEmpty()) {
            "Source scenario requires sourceBase64"
        }
        String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
    }
    private val source: BookSource by lazy {
        GSON.fromJson(sourceJson, BookSource::class.java)
    }
    private val deviceOrigin by lazy {
        when {
            isAndroidRuntimeScenario -> "android-runtime://local"
            isIntegrationLabScenario ->
                requiredArgument("deviceOrigin").trimEnd('/')
            else -> source.bookSourceUrl.trimEnd('/')
        }
    }
    private val cases = JSONArray()
    private val requestPlan = JSONArray()

    @Test
    fun runCharacterization() = runBlocking {
        if (
            !isAndroidRuntimeScenario &&
            !isIntegrationLabScenario &&
            !isRealSourceScenario
        ) {
            require(deviceOrigin.startsWith("http://127.0.0.1:")) {
                "Oracle source must use the run-scoped device loopback origin"
            }
            source.enabledCookieJar =
                scenarioId == "sl-source-request-header-cookie-retry-layering-001" ||
                    scenarioId == "sl-source-cookie-persistent-session-merge-runtime-001"
        }
        if (isIntegrationLabScenario) {
            if (isPlatformIntegrationScenario) {
                require(deviceOrigin == "android-platform://text-to-speech") {
                    "TTS Integration Oracle must use the Android platform origin"
                }
            } else {
                require(deviceOrigin.startsWith("http://127.0.0.1:")) {
                    "Integration Oracle must use the run-scoped loopback origin"
                }
            }
        }
        if (isRealSourceScenario) {
            require(deviceOrigin == "https://zh.wikisource.org") {
                "Real-source capture origin is not allowlisted"
            }
            require(source.loginUrl.isNullOrBlank()) {
                "Real-source capture must not use credentials"
            }
        }

        when (scenarioId) {
            "rs-wikisource-public-domain-001" ->
                runRealWikisourceCases()
            "il-integration-backup-webdav-001" ->
                runWebDavIntegrationCases()
            "il-integration-remote-http-websocket-management-001" ->
                runRemoteManagementIntegrationCases()
            "il-integration-system-text-to-speech-001" ->
                runSystemTextToSpeechIntegrationCases()
            "rl-library-shelf-group-bit-boundary-risk-001" ->
                runBookGroupBoundaryCases()
            "rl-library-local-book-relocation-runtime-001" ->
                runLocalBookRelocationCases()
            "rl-discovery-search-book-persistence-lifecycle-001" ->
                runSearchBookLifecycleCases()
            "rl-library-book-import-channel-runtime-001" ->
                runBookImportChannelCases()
            "rl-library-book-detail-staging-runtime-001" ->
                runBookDetailStagingCases()
            "rl-library-book-source-switch-migration-runtime-001" ->
                runBookSourceMigrationCases()
            "rl-library-chapter-toc-update-runtime-001" ->
                runChapterTocUpdateCases()
            "rl-ui-reader-toc-result-001" ->
                runTocActivityResultCases()
            "rl-reader-chapter-source-override-runtime-001" ->
                runChapterSourceOverrideCases()
            "rl-reader-bookmark-search-runtime-risk-001" ->
                runBookmarkRuntimeCases()
            "rl-reader-history-read-record-runtime-risk-001" ->
                runReadRecordRuntimeCases()
            "rl-reader-progress-read-duration-session-001" ->
                runReadDurationSessionCases()
            "rl-reader-layout-incremental-stream-001" ->
                runReaderLayoutIncrementalStreamCases()
            "rl-reader-layout-page-projection-001" ->
                runReaderLayoutPageProjectionCases()
            "rl-reader-progress-layout-save-runtime-001" ->
                runReaderProgressRuntimeCases()
            "rl-reader-progress-webdav-conflict-runtime-001" ->
                runReaderProgressWebDavConflictCases()
            "rl-reader-progress-save-runtime-001" ->
                runReaderProgressSaveRuntimeCases()
            "rl-ui-book-detail-conditional-actions-001" ->
                runBookDetailConditionalActionCases()
            "rl-ui-discovery-search-flow-001" ->
                runSearchFlowCases()
            "rl-ui-source-editor-debug-routes-001" ->
                runSourceEditorDebugRouteCases()
            "rl-app-source-import-runtime-001" ->
                runSourceImportRuntimeCases()
            "rl-reader-cache-prefetch-policy-001" ->
                runReaderPrefetchPolicyCases()
            "rl-reader-progress-toc-remap-001" ->
                runReaderProgressTocRemapCases()
            "rl-reader-session-reset-from-book-001" ->
                runReaderSessionResetCases()
            "rl-reader-content-cache-first-acquisition-001" ->
                runReaderContentAcquisitionCases()
            "rl-reader-content-index-load-dedup-001" ->
                runReaderIndexLoadDedupCases()
            "rl-reader-content-display-normalization-001" ->
                runReaderContentNormalizationCases()
            "rl-reader-session-chapter-navigation-001" ->
                runReaderChapterNavigationCases()
            "rl-reader-session-close-cancellation-001" ->
                runReaderSessionCloseCases()
            "rl-app-startup-first-use-and-restore-001" ->
                runAppStartupCases()
            "rl-integration-backup-archive-001" ->
                runBackupArchiveCases()
            "rl-integration-backup-ios-to-android-001" ->
                runIOSBackupAndroidRestoreCases()
            "rl-integration-backup-ios-replacerule-to-android-001" ->
                runIOSReplaceRuleBackupAndroidRestoreCases()
            "rl-integration-backup-ios-library-to-android-001" ->
                runIOSLibraryBackupAndroidRestoreCases()
            "sl-post-form-001" -> runPostFormCases()
            "sl-source-response-xml-declaration-normalization-001" ->
                runXmlResponseCases()
            "sl-source-request-header-cookie-retry-layering-001" ->
                runRequestOptionCases()
            "sl-source-request-field-encoding-runtime-001" ->
                runFieldEncodingCases()
            "sl-source-request-url-template-compilation-001" ->
                runURLTemplateCompilationCases()
            "sl-source-session-rate-limit-shared-state-001" ->
                runRateLimitStateCases()
            "sl-source-transport-request-dispatch-contract-001" ->
                runTransportDispatchCases()
            "sl-source-transport-response-decoding-runtime-001" ->
                runResponseDecodingCases()
            "sl-source-transport-retry-redirect-runtime-001" ->
                runRetryRedirectCases()
            "sl-source-cookie-persistent-session-merge-runtime-001" ->
                runCookieSessionCases()
            "sl-source-transport-dynamic-web-runtime-001" ->
                runDynamicWebCases()
            "sl-source-session-rule-variable-scope-001" ->
                runRuleVariableScopeCases()
            "sl-source-rule-backend-dispatch-runtime-001" ->
                runRuleBackendDispatchCases()
            "sl-source-rule-combination-and-coercion-runtime-001" ->
                runRuleCombinationCases()
            "sl-source-rule-dom-selector-backends-001" ->
                runDOMSelectorBackendCases()
            "sl-source-rule-url-normalization-runtime-001" ->
                runDOMSelectorBackendCases()
            "sl-source-rule-jsonpath-regex-backends-001" ->
                runJSONPathRegexBackendCases()
            "sl-source-debug-android-truth-001" ->
                runSourceDebugRuntimeCases()
            "sl-source-pipeline-toc-runtime-001" ->
                runTOCPipelineCases()
            "sl-source-pipeline-search-runtime-001" ->
                runSearchPipelineCases()
            "sl-source-pipeline-explore-runtime-001" ->
                runExplorePipelineCases()
            "sl-content-cache-queue-completion-runtime-001" ->
                runContentCacheQueueCompletionCases()
            else -> {
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
            }
        }

        val raw = JSONObject()
            .put("schema_version", 1)
            .put("scenario_id", scenarioId)
            .put("device_origin", deviceOrigin)
            .put("logical_origin", logicalOrigin)
            .put("request_plan", requestPlan)
            .put("cases", cases)
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        File(target.filesDir, OUTPUT_FILE).writeText(raw.toString(), Charsets.UTF_8)
    }

    private suspend fun runRealWikisourceCases() {
        val keyword = input.getString("keyword")
        val selectedTitle = input.getString("book_title")
        val selectedChapter = input.getString("chapter_title")
        var searchBook: SearchBook? = null
        var book: Book? = null
        var chapters: List<BookChapter> = emptyList()

        runCase("real-search", "search", searchRequest(keyword)) {
            val values = WebBook.searchBookAwait(source, keyword)
            searchBook = values.firstOrNull { it.name == selectedTitle }
                ?: error("Selected public-domain work was not found")
            searchProjection(values.take(5))
        }
        runCase(
            "real-book-info",
            "book_info",
            request(searchBook?.bookUrl ?: source.bookSourceUrl)
        ) {
            val selected = requireNotNull(searchBook).toBook()
            book = WebBook.getBookInfoAwait(source, selected)
            bookProjection(requireNotNull(book))
        }
        runCase(
            "real-toc",
            "chapters",
            request(book?.tocUrl ?: book?.bookUrl ?: source.bookSourceUrl)
        ) {
            chapters = WebBook.getChapterListAwait(
                source,
                requireNotNull(book)
            ).getOrThrow()
            chapterProjection(chapters.take(32))
        }
        runCase(
            "real-content",
            "content",
            request(
                chapters.firstOrNull { it.title == selectedChapter }
                    ?.getAbsoluteURL()
                    ?: source.bookSourceUrl
            )
        ) {
            val chapter = chapters.firstOrNull {
                it.title == selectedChapter
            } ?: error("Selected public-domain chapter was not found")
            val content = WebBook.getContentAwait(
                source,
                requireNotNull(book),
                chapter,
                needSave = false
            )
            JSONObject()
                .put("chapter_title", chapter.title)
                .put("chapter_url", logical(chapter.getAbsoluteURL()))
                .put("content_characters", content.length)
                .put("content_sample", content.take(240))
        }
    }

    private suspend fun runWebDavIntegrationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation in setOf(
                    "webdav_check",
                    "webdav_exists",
                    "webdav_make_directory",
                    "webdav_list",
                    "webdav_get_file",
                    "webdav_download",
                    "webdav_upload",
                    "webdav_delete"
                )
            ) {
                "Unsupported WebDAV integration operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                webDavProjection(operation, arguments)
            }
        }
    }

    private suspend fun webDavProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        val client = WebDav(
            "$deviceOrigin${arguments.getString("target")}",
            Authorization("oracle-user", "oracle-password")
        )
        return when (operation) {
            "webdav_check" -> JSONObject()
                .put("accepted", client.check())
            "webdav_exists" -> JSONObject()
                .put("exists", client.exists())
            "webdav_make_directory" -> JSONObject()
                .put("created", client.makeAsDir())
            "webdav_list" -> JSONObject().put(
                "files",
                JSONArray().apply {
                    client.listFiles().forEach { put(webDavFileProjection(it)) }
                }
            )
            "webdav_get_file" -> JSONObject().put(
                "file",
                client.getWebDavFile()?.let(::webDavFileProjection)
                    ?: JSONObject.NULL
            )
            "webdav_download" -> {
                val bytes = client.download()
                JSONObject()
                    .put(
                        "body_base64",
                        Base64.encodeToString(bytes, Base64.NO_WRAP)
                    )
                    .put("body_bytes", bytes.size)
            }
            "webdav_upload" -> {
                val bytes = arguments
                    .getString("payload_utf8")
                    .toByteArray(Charsets.UTF_8)
                client.upload(
                    bytes,
                    arguments.getString("media_type")
                )
                JSONObject()
                    .put("completed", true)
                    .put("body_bytes", bytes.size)
            }
            "webdav_delete" -> JSONObject()
                .put("deleted", client.delete())
            else -> error("Unsupported WebDAV operation: $operation")
        }
    }

    private fun webDavFileProjection(value: WebDavFile): JSONObject =
        JSONObject()
            .put("path", logical(value.path))
            .put("display_name", value.displayName)
            .put("url_name", value.urlName)
            .put("size", value.size)
            .put("content_type", value.contentType)
            .put("resource_type", value.resourceType)
            .put("last_modify", value.lastModify)
            .put("is_directory", value.isDir)

    private suspend fun runBackupArchiveCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "backup_archive_restore") {
                "Backup archive scenario only accepts backup_archive_restore stimuli"
            }
            val stimulus = JSONObject()
                .put("operation", "backup_archive_restore")
                .put(
                    "arguments",
                    JSONObject(value.getJSONObject("arguments").toString())
                )
            runCase(
                value.getString("id"),
                "backup_archive_restore",
                stimulus
            ) {
                backupArchiveProjection()
            }
        }
    }

    private suspend fun backupArchiveProjection(): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val workspace = File(target.cacheDir, "legado-oracle-backup-archive")
        val output = File(workspace, "output")
        val extracted = File(workspace, "extracted")
        val source = BookSource(
            bookSourceUrl = "https://oracle.invalid/source",
            bookSourceName = "Oracle Source",
            bookSourceGroup = "oracle",
            enabled = true,
            enabledExplore = false,
            searchUrl = "https://oracle.invalid/search?key={{key}}"
        )
        val replaceRule = ReplaceRule(
            id = 7_001L,
            name = "Oracle Replace",
            pattern = "oracle-pattern",
            replacement = "oracle-replacement",
            order = 17
        )
        val server = Server(
            id = 7_002L,
            name = "Oracle Server",
            config = GSON.toJson(
                Server.WebDavConfig(
                    url = "https://oracle.invalid/dav/",
                    username = "oracle-user",
                    password = "oracle-server-secret"
                )
            ),
            sortNumber = 23
        )
        val publicVectorPlaintext = "legado-public-backup-vector-v1"
        val publicTestKey = "legado-public-oracle-key-v1"
        val webDavPassword = "oracle-webdav-secret"

        workspace.deleteRecursively()
        output.mkdirs()
        extracted.mkdirs()
        appDb.clearAllTables()
        val preferences = target.defaultSharedPreferences
        preferences.edit()
            .putBoolean(PreferKey.onlyLatestBackup, true)
            .putString(PreferKey.webDavPassword, webDavPassword)
            .remove(PreferKey.webDavAccount)
            .remove(PreferKey.webDavUrl)
            .commit()
        LocalConfig.password = publicTestKey
        appDb.bookSourceDao.insert(source)
        appDb.replaceRuleDao.insert(replaceRule)
        appDb.serverDao.insert(server)

        try {
            Backup.backup(target, output.absolutePath)
            val archiveFile = File(output, "backup.zip")
            require(archiveFile.isFile) { "Android backup.zip was not created" }

            val archiveProjection = ZipFile(archiveFile).use { archive ->
                val entries = java.util.Collections.list(archive.entries())
                val names = entries.map { it.name }.sorted()
                val sourceEntry = requireNotNull(archive.getEntry("bookSource.json"))
                val sourceArray = JSONArray(
                    archive.getInputStream(sourceEntry)
                        .bufferedReader(Charsets.UTF_8)
                        .use { it.readText() }
                )
                val sourceObject = (0 until sourceArray.length())
                    .map { sourceArray.getJSONObject(it) }
                    .first { it.optString("bookSourceName") == source.bookSourceName }
                val serverEntry = requireNotNull(archive.getEntry("servers.json"))
                val encryptedServers = archive.getInputStream(serverEntry)
                    .bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                val decryptedServers = BackupAES().decryptStr(encryptedServers)
                val publicCiphertext = BackupAES().encryptBase64(publicVectorPlaintext)

                JSONObject()
                    .put("file_name", archiveFile.name)
                    .put("member_names", JSONArray(names))
                    .put(
                        "compression_methods",
                        JSONArray(entries.map { it.method }.distinct().sorted())
                    )
                    .put("book_source_count", sourceArray.length())
                    .put(
                        "book_source_field_names",
                        JSONArray(sourceObject.keys().asSequence().toList().sorted())
                    )
                    .put(
                        "servers_is_plain_json_array",
                        encryptedServers.trim().startsWith("[")
                    )
                    .put("servers_decrypted_count", JSONArray(decryptedServers).length())
                    .put(
                        "aes_public_vector",
                        JSONObject()
                            .put("plaintext_id", "legado-public-backup-vector-v1")
                            .put("ciphertext_base64", publicCiphertext)
                            .put(
                                "roundtrip_equal",
                                BackupAES().decryptStr(publicCiphertext) == publicVectorPlaintext
                            )
                    )
            }

            appDb.bookSourceDao.delete(source)
            appDb.replaceRuleDao.delete(replaceRule)
            appDb.serverDao.delete(server.id)
            preferences.edit().remove(PreferKey.webDavPassword).commit()
            ZipUtils.unZipToPath(archiveFile, extracted)
            Restore.restore(extracted.absolutePath)

            return JSONObject()
                .put("archive", archiveProjection)
                .put(
                    "restore",
                    JSONObject()
                        .put(
                            "book_source_restored",
                            appDb.bookSourceDao.getBookSource(source.bookSourceUrl) != null
                        )
                        .put(
                            "replace_rule_restored",
                            appDb.replaceRuleDao.findById(replaceRule.id) != null
                        )
                        .put("server_restored", appDb.serverDao.get(server.id) != null)
                        .put(
                            "webdav_password_restored",
                            preferences.getString(PreferKey.webDavPassword, null) == webDavPassword
                        )
                )
        } finally {
            appDb.bookSourceDao.delete(source.bookSourceUrl)
            appDb.replaceRuleDao.findById(replaceRule.id)?.let {
                appDb.replaceRuleDao.delete(it)
            }
            appDb.serverDao.delete(server.id)
            preferences.edit()
                .remove(PreferKey.webDavPassword)
                .remove(PreferKey.onlyLatestBackup)
                .commit()
            LocalConfig.password = null
            Backup.clearCache()
            workspace.deleteRecursively()
        }
    }

    private suspend fun runIOSBackupAndroidRestoreCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "ios_backup_android_restore") {
                "iOS backup restore scenario only accepts ios_backup_android_restore stimuli"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "ios_backup_android_restore")
                .put(
                    "arguments",
                    JSONObject()
                        .put("archive_sha256", arguments.getString("archive_sha256"))
                        .put("profile", arguments.getString("profile"))
                )
            runCase(
                value.getString("id"),
                "ios_backup_android_restore",
                stimulus
            ) {
                iosBackupAndroidRestoreProjection(
                    arguments.getString("archive_base64")
                )
            }
        }
    }

    private suspend fun iosBackupAndroidRestoreProjection(
        archiveBase64: String
    ): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val workspace = File(target.cacheDir, "legado-oracle-ios-backup-restore")
        val archiveFile = File(workspace, "backup.zip")
        val extracted = File(workspace, "extracted")
        val sourceURL = "https://ios-oracle.invalid/source"

        workspace.deleteRecursively()
        extracted.mkdirs()
        appDb.clearAllTables()
        try {
            archiveFile.writeBytes(
                Base64.decode(archiveBase64, Base64.DEFAULT)
            )
            val archiveProjection = ZipFile(archiveFile).use { archive ->
                val entries = java.util.Collections.list(archive.entries())
                JSONObject()
                    .put(
                        "member_names",
                        JSONArray(entries.map { it.name }.sorted())
                    )
                    .put(
                        "compression_methods",
                        JSONArray(entries.map { it.method }.distinct().sorted())
                    )
                    .put("has_book_source", archive.getEntry("bookSource.json") != null)
            }

            ZipUtils.unZipToPath(archiveFile, extracted)
            Restore.restore(extracted.absolutePath)
            val restored = appDb.bookSourceDao.getBookSource(sourceURL)

            return JSONObject()
                .put("archive", archiveProjection)
                .put(
                    "restore",
                    JSONObject()
                        .put("book_source_restored", restored != null)
                        .put("book_source_url", restored?.bookSourceUrl)
                        .put("book_source_name", restored?.bookSourceName)
                        .put("enabled", restored?.enabled)
                        .put("enabled_explore", restored?.enabledExplore)
                )
        } finally {
            appDb.bookSourceDao.delete(sourceURL)
            workspace.deleteRecursively()
        }
    }

    private suspend fun runIOSReplaceRuleBackupAndroidRestoreCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "ios_replacerule_backup_android_restore"
            ) {
                "iOS replacement rule restore scenario operation is invalid"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "ios_replacerule_backup_android_restore")
                .put(
                    "arguments",
                    JSONObject()
                        .put("archive_sha256", arguments.getString("archive_sha256"))
                        .put("profile", arguments.getString("profile"))
                )
            runCase(
                value.getString("id"),
                "ios_replacerule_backup_android_restore",
                stimulus
            ) {
                iosReplaceRuleBackupAndroidRestoreProjection(
                    arguments.getString("archive_base64")
                )
            }
        }
    }

    private suspend fun iosReplaceRuleBackupAndroidRestoreProjection(
        archiveBase64: String
    ): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val workspace = File(
            target.cacheDir,
            "legado-oracle-ios-replacerule-backup-restore"
        )
        val archiveFile = File(workspace, "backup.zip")
        val extracted = File(workspace, "extracted")
        val ruleId = 7_003L

        workspace.deleteRecursively()
        extracted.mkdirs()
        appDb.clearAllTables()
        try {
            archiveFile.writeBytes(
                Base64.decode(archiveBase64, Base64.DEFAULT)
            )
            val archiveProjection = ZipFile(archiveFile).use { archive ->
                val entries = java.util.Collections.list(archive.entries())
                JSONObject()
                    .put(
                        "member_names",
                        JSONArray(entries.map { it.name }.sorted())
                    )
                    .put(
                        "compression_methods",
                        JSONArray(entries.map { it.method }.distinct().sorted())
                    )
                    .put(
                        "has_replace_rule",
                        archive.getEntry("replaceRule.json") != null
                    )
            }

            ZipUtils.unZipToPath(archiveFile, extracted)
            Restore.restore(extracted.absolutePath)
            val restored = appDb.replaceRuleDao.findById(ruleId)

            return JSONObject()
                .put("archive", archiveProjection)
                .put(
                    "restore",
                    JSONObject()
                        .put("replace_rule_restored", restored != null)
                        .put("id", restored?.id)
                        .put("name", restored?.name)
                        .put("group", restored?.group)
                        .put("pattern", restored?.pattern)
                        .put("replacement", restored?.replacement)
                        .put("scope_title", restored?.scopeTitle)
                        .put("scope_content", restored?.scopeContent)
                        .put("is_enabled", restored?.isEnabled)
                        .put("is_regex", restored?.isRegex)
                        .put("timeout_millisecond", restored?.timeoutMillisecond)
                        .put("order", restored?.order)
                )
        } finally {
            appDb.replaceRuleDao.findById(ruleId)?.let {
                appDb.replaceRuleDao.delete(it)
            }
            workspace.deleteRecursively()
        }
    }

    private suspend fun runIOSLibraryBackupAndroidRestoreCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "ios_library_backup_android_restore"
            ) {
                "iOS library restore scenario operation is invalid"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "ios_library_backup_android_restore")
                .put(
                    "arguments",
                    JSONObject()
                        .put("archive_sha256", arguments.getString("archive_sha256"))
                        .put("profile", arguments.getString("profile"))
                )
            runCase(
                value.getString("id"),
                "ios_library_backup_android_restore",
                stimulus
            ) {
                iosLibraryBackupAndroidRestoreProjection(
                    arguments.getString("archive_base64")
                )
            }
        }
    }

    private suspend fun iosLibraryBackupAndroidRestoreProjection(
        archiveBase64: String
    ): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val workspace = File(
            target.cacheDir,
            "legado-oracle-ios-library-backup-restore"
        )
        val archiveFile = File(workspace, "backup.zip")
        val extracted = File(workspace, "extracted")
        val bookURL = "https://ios-oracle.invalid/book"
        val groupID = 8L
        val bookName = "iOS Oracle Book"
        val bookAuthor = "Oracle Author"

        workspace.deleteRecursively()
        extracted.mkdirs()
        appDb.clearAllTables()
        try {
            archiveFile.writeBytes(Base64.decode(archiveBase64, Base64.DEFAULT))
            val archiveProjection = ZipFile(archiveFile).use { archive ->
                val entries = java.util.Collections.list(archive.entries())
                JSONObject()
                    .put("member_names", JSONArray(entries.map { it.name }.sorted()))
                    .put(
                        "compression_methods",
                        JSONArray(entries.map { it.method }.distinct().sorted())
                    )
                    .put("has_bookshelf", archive.getEntry("bookshelf.json") != null)
                    .put("has_book_group", archive.getEntry("bookGroup.json") != null)
                    .put("has_bookmark", archive.getEntry("bookmark.json") != null)
            }

            ZipUtils.unZipToPath(archiveFile, extracted)
            Restore.restore(extracted.absolutePath)
            val restoredBook = appDb.bookDao.getBook(bookURL)
            val restoredGroup = appDb.bookGroupDao.getByID(groupID)
            val restoredBookmark = appDb.bookmarkDao
                .getByBook(bookName, bookAuthor)
                .singleOrNull { it.time == 1_700_000_000_123L }

            return JSONObject()
                .put("archive", archiveProjection)
                .put(
                    "book",
                    JSONObject()
                        .put("restored", restoredBook != null)
                        .put("book_url", restoredBook?.bookUrl)
                        .put("name", restoredBook?.name)
                        .put("author", restoredBook?.author)
                        .put("group", restoredBook?.group)
                        .put("latest_chapter_title", restoredBook?.latestChapterTitle)
                        .put("latest_chapter_time", restoredBook?.latestChapterTime)
                        .put("last_check_time", restoredBook?.lastCheckTime)
                        .put("last_check_count", restoredBook?.lastCheckCount)
                        .put("total_chapter_count", restoredBook?.totalChapterNum)
                        .put("current_chapter_title", restoredBook?.durChapterTitle)
                        .put("current_chapter_index", restoredBook?.durChapterIndex)
                        .put("current_chapter_position", restoredBook?.durChapterPos)
                        .put("last_read_time", restoredBook?.durChapterTime)
                        .put("can_update", restoredBook?.canUpdate)
                        .put("order", restoredBook?.order)
                        .put("origin_order", restoredBook?.originOrder)
                        .put("reverse_toc", restoredBook?.readConfig?.reverseToc)
                        .put(
                            "split_long_chapter",
                            restoredBook?.readConfig?.splitLongChapter
                        )
                )
                .put(
                    "group",
                    JSONObject()
                        .put("restored", restoredGroup != null)
                        .put("group_id", restoredGroup?.groupId)
                        .put("group_name", restoredGroup?.groupName)
                        .put("order", restoredGroup?.order)
                        .put("enable_refresh", restoredGroup?.enableRefresh)
                        .put("show", restoredGroup?.show)
                        .put("book_sort", restoredGroup?.bookSort)
                )
                .put(
                    "bookmark",
                    JSONObject()
                        .put("restored", restoredBookmark != null)
                        .put("time", restoredBookmark?.time)
                        .put("chapter_index", restoredBookmark?.chapterIndex)
                        .put("chapter_position", restoredBookmark?.chapterPos)
                        .put("chapter_name", restoredBookmark?.chapterName)
                        .put("book_text", restoredBookmark?.bookText)
                        .put("content", restoredBookmark?.content)
                )
        } finally {
            appDb.clearAllTables()
            workspace.deleteRecursively()
        }
    }

    private suspend fun runRemoteManagementIntegrationCases() {
        val httpServer = HttpServer(0)
        val webSocketServer = WebSocketServer(0)
        val context =
            InstrumentationRegistry.getInstrumentation().targetContext
        try {
            httpServer.start(5_000, true)
            webSocketServer.start(5_000, true)
            require(httpServer.isAlive && webSocketServer.isAlive) {
                "Remote management listeners did not start"
            }
            val values = input.getJSONArray("cases")
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val operation = value.getString("operation")
                require(
                    operation in setOf(
                        "remote_listener_contract",
                        "remote_http_request",
                        "remote_websocket_handshake"
                    )
                ) {
                    "Unsupported remote integration operation: $operation"
                }
                val arguments = value.getJSONObject("arguments")
                val stimulus = JSONObject()
                    .put("operation", operation)
                    .put("arguments", JSONObject(arguments.toString()))
                runCase(
                    value.getString("id"),
                    operation,
                    stimulus
                ) {
                    when (operation) {
                        "remote_listener_contract" ->
                            remoteListenerProjection(
                                httpServer,
                                webSocketServer
                            )
                        "remote_http_request" ->
                            remoteHttpProjection(
                                httpServer.listeningPort,
                                arguments
                            )
                        "remote_websocket_handshake" ->
                            remoteWebSocketProjection(
                                webSocketServer.listeningPort,
                                arguments.getString("path")
                            )
                        else -> error(
                            "Unsupported remote operation: $operation"
                        )
                    }
                }
            }
        } finally {
            httpServer.stop()
            webSocketServer.stop()
            WebService.stop(context)
        }
    }

    private fun remoteListenerProjection(
        httpServer: HttpServer,
        webSocketServer: WebSocketServer
    ): JSONObject =
        JSONObject()
            .put("http_listening", httpServer.isAlive)
            .put("websocket_listening", webSocketServer.isAlive)
            .put(
                "http_bind_scope",
                if (httpServer.hostname.isNullOrBlank()) {
                    "all_interfaces"
                } else {
                    "explicit_host"
                }
            )
            .put(
                "websocket_bind_scope",
                if (webSocketServer.hostname.isNullOrBlank()) {
                    "all_interfaces"
                } else {
                    "explicit_host"
                }
            )
            .put("http_port_assigned", httpServer.listeningPort > 0)
            .put(
                "websocket_port_assigned",
                webSocketServer.listeningPort > 0
            )
            .put(
                "separate_ports",
                httpServer.listeningPort != webSocketServer.listeningPort
            )

    private fun remoteHttpProjection(
        port: Int,
        arguments: JSONObject
    ): JSONObject {
        val seed = arguments.optBoolean("seed_bookshelf", false)
        val seededBook = Book(
            bookUrl = "oracle://remote-management/book",
            origin = "oracle://remote-management/source",
            originName = "Oracle Remote Source",
            name = "Oracle Remote Book",
            author = "Oracle",
            latestChapterTime = 0,
            lastCheckTime = 0,
            durChapterTime = 0
        )
        if (seed) {
            appDb.bookDao.insert(seededBook)
        }
        return try {
            val method = arguments.getString("method")
            val path = arguments.getString("path")
            val builder = Request.Builder()
                .url("http://127.0.0.1:$port$path")
                .method(method, null)
            if (arguments.has("origin")) {
                builder.header(
                    "Origin",
                    "http://${arguments.getString("origin")}"
                )
            }
            OkHttpClient()
                .newCall(builder.build())
                .execute()
                .use { response ->
                    val body = response.body?.string().orEmpty()
                    val projection = JSONObject()
                        .put("status", response.code)
                        .put(
                            "content_type",
                            nullable(response.header("Content-Type"))
                        )
                        .put(
                            "allow_methods",
                            nullable(
                                response.header(
                                    "Access-Control-Allow-Methods"
                                )
                            )
                        )
                        .put(
                            "allow_headers",
                            nullable(
                                response.header(
                                    "Access-Control-Allow-Headers"
                                )
                            )
                        )
                        .put(
                            "allow_origin",
                            nullable(
                                response.header(
                                    "Access-Control-Allow-Origin"
                                )
                            )
                        )
                        .put("body_empty", body.isEmpty())
                    when {
                        seed -> {
                            val envelope = JSONObject(body)
                            val data = envelope.optJSONArray("data")
                            projection
                                .put(
                                    "return_success",
                                    envelope.getBoolean("isSuccess")
                                )
                                .put(
                                    "seed_visible",
                                    data != null &&
                                        (0 until data.length()).any {
                                            data
                                                .getJSONObject(it)
                                                .getString("name") ==
                                                seededBook.name
                                        }
                                )
                        }
                        path == "/" -> projection.put(
                            "asset_index_visible",
                            body.contains("Legado web")
                        )
                        else -> projection.put(
                            "missing_path_reported",
                            body.contains("oracle-missing")
                        )
                    }
                    projection
                }
        } finally {
            if (seed) {
                appDb.bookDao.delete(seededBook)
            }
        }
    }

    private fun remoteWebSocketProjection(
        port: Int,
        path: String
    ): JSONObject {
        return try {
            Socket("127.0.0.1", port).use { socket ->
                socket.soTimeout = 5_000
                val writer = OutputStreamWriter(
                    socket.getOutputStream(),
                    Charsets.US_ASCII
                )
                writer.write(
                    "GET $path HTTP/1.1\r\n" +
                        "Host: 127.0.0.1:$port\r\n" +
                        "Connection: Upgrade\r\n" +
                        "Upgrade: websocket\r\n" +
                        "Sec-WebSocket-Version: 13\r\n" +
                        "Sec-WebSocket-Key: " +
                        "dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
                )
                writer.flush()
                val reader = BufferedReader(
                    InputStreamReader(
                        socket.getInputStream(),
                        Charsets.US_ASCII
                    )
                )
                val statusLine = reader.readLine()
                val headers = mutableMapOf<String, String>()
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    val delimiter = line.indexOf(':')
                    if (delimiter > 0) {
                        headers[line.substring(0, delimiter).lowercase()] =
                            line.substring(delimiter + 1).trim()
                    }
                }
                val status = statusLine
                    ?.split(' ')
                    ?.getOrNull(1)
                    ?.toIntOrNull()
                JSONObject()
                    .put("accepted", status == 101)
                    .put("status", status ?: JSONObject.NULL)
                    .put("upgrade", nullable(headers["upgrade"]))
                    .put("connection", nullable(headers["connection"]))
                    .put("failure_type", JSONObject.NULL)
            }
        } catch (error: Throwable) {
            JSONObject()
                .put("accepted", false)
                .put("status", JSONObject.NULL)
                .put("upgrade", JSONObject.NULL)
                .put("connection", JSONObject.NULL)
                .put("failure_type", error.javaClass.name)
        }
    }

    private suspend fun runSystemTextToSpeechIntegrationCases() {
        val supported = setOf(
            "tts_helper_queue",
            "tts_helper_initialization",
            "tts_helper_lifecycle",
            "tts_service_speech_rate",
            "tts_service_progress",
            "tts_platform_engine_probe"
        )
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported system TTS integration operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                when (operation) {
                    "tts_helper_queue" ->
                        ttsHelperQueueProjection(arguments)
                    "tts_helper_initialization" ->
                        ttsHelperInitializationProjection(arguments)
                    "tts_helper_lifecycle" ->
                        ttsHelperLifecycleProjection(arguments)
                    "tts_service_speech_rate" ->
                        ttsServiceSpeechRateProjection(arguments)
                    "tts_service_progress" ->
                        ttsServiceProgressProjection(arguments)
                    "tts_platform_engine_probe" ->
                        ttsPlatformEngineProjection()
                    else -> error(
                        "Unsupported system TTS operation: $operation"
                    )
                }
            }
        }
    }

    private fun ttsHelperQueueProjection(
        arguments: JSONObject
    ): JSONObject {
        val helper = TTS()
        val recorder = recordingTextToSpeech()
        setPrivateField(
            TTS::class.java,
            helper,
            "textToSpeech",
            recorder
        )
        return try {
            helper.speak(arguments.getString("text"))
            JSONObject()
                .put("calls", recorder.callProjection())
                .put("stop_count", recorder.stopCount)
                .put("shutdown_count", recorder.shutdownCount)
        } finally {
            helper.clearTts()
            recorder.releaseBaseEngine()
        }
    }

    private fun ttsHelperInitializationProjection(
        arguments: JSONObject
    ): JSONObject {
        val helper = TTS()
        val recorder = recordingTextToSpeech()
        setPrivateField(
            TTS::class.java,
            helper,
            "textToSpeech",
            recorder
        )
        setPrivateField(TTS::class.java, helper, "onInit", true)
        return try {
            val texts = arguments.getJSONArray("texts")
            for (index in 0 until texts.length()) {
                helper.speak(texts.getString(index))
            }
            JSONObject()
                .put(
                    "retained_text",
                    privateField(TTS::class.java, helper, "text")
                )
                .put("queue_call_count", recorder.calls.size)
                .put(
                    "initialization_in_flight",
                    privateField(TTS::class.java, helper, "onInit")
                )
        } finally {
            setPrivateField(TTS::class.java, helper, "onInit", false)
            helper.clearTts()
            recorder.releaseBaseEngine()
        }
    }

    private fun ttsHelperLifecycleProjection(
        arguments: JSONObject
    ): JSONObject {
        val helper = TTS()
        val recorder = recordingTextToSpeech()
        setPrivateField(
            TTS::class.java,
            helper,
            "textToSpeech",
            recorder
        )
        return try {
            when (arguments.getString("action")) {
                "stop" -> helper.stop()
                "clear" -> helper.clearTts()
                else -> error("Unsupported TTS helper lifecycle action")
            }
            JSONObject()
                .put("stop_count", recorder.stopCount)
                .put("shutdown_count", recorder.shutdownCount)
                .put(
                    "engine_reference_present",
                    privateField(
                        TTS::class.java,
                        helper,
                        "textToSpeech"
                    ) != null
                )
        } finally {
            helper.clearTts()
            recorder.releaseBaseEngine()
        }
    }

    private fun ttsServiceSpeechRateProjection(
        arguments: JSONObject
    ): JSONObject = onMainThread {
        val service = TTSReadAloudService()
        val recorder = recordingTextToSpeech()
        val oldFollowSystem = AppConfig.ttsFlowSys
        val oldPreference = AppConfig.ttsSpeechRate
        setPrivateField(
            TTSReadAloudService::class.java,
            service,
            "textToSpeech",
            recorder
        )
        try {
            AppConfig.ttsFlowSys =
                arguments.getBoolean("follow_system")
            AppConfig.ttsSpeechRate = arguments.getInt("preference")
            service.upSpeechRate(arguments.getBoolean("reset"))
            JSONObject()
                .put("speech_rates", recorder.speechRateProjection())
                .put("engine_reinitialized", recorder.shutdownCount > 0)
        } finally {
            AppConfig.ttsFlowSys = oldFollowSystem
            AppConfig.ttsSpeechRate = oldPreference
            service.clearTTS()
            recorder.releaseBaseEngine()
        }
    }

    private fun ttsServiceProgressProjection(
        arguments: JSONObject
    ): JSONObject = onMainThread {
        val service = TTSReadAloudService()
        val content = arguments.getJSONArray("content")
        val contentList = (0 until content.length()).map(content::getString)
        setPrivateField(
            BaseReadAloudService::class.java,
            service,
            "contentList",
            contentList
        )
        setPrivateField(
            BaseReadAloudService::class.java,
            service,
            "nowSpeak",
            arguments.getInt("now_speak")
        )
        setPrivateField(
            BaseReadAloudService::class.java,
            service,
            "readAloudNumber",
            arguments.getInt("read_aloud_number")
        )
        service.paragraphStartPos =
            arguments.getInt("paragraph_start_pos")
        val listener = privateField(
            TTSReadAloudService::class.java,
            service,
            "ttsUtteranceListener"
        ) as UtteranceProgressListener
        listener.onDone("oracle")
        JSONObject()
            .put(
                "now_speak",
                privateField(
                    BaseReadAloudService::class.java,
                    service,
                    "nowSpeak"
                )
            )
            .put(
                "read_aloud_number",
                privateField(
                    BaseReadAloudService::class.java,
                    service,
                    "readAloudNumber"
                )
            )
            .put("paragraph_start_pos", service.paragraphStartPos)
    }

    private fun ttsPlatformEngineProjection(): JSONObject {
        val context =
            InstrumentationRegistry.getInstrumentation().targetContext
        val initStatus = AtomicInteger(Int.MIN_VALUE)
        val latch = CountDownLatch(1)
        val engine = TextToSpeech(context) { status ->
            initStatus.set(status)
            latch.countDown()
        }
        return try {
            val callbackReceived = latch.await(20, TimeUnit.SECONDS)
            val status = initStatus.get()
            JSONObject()
                .put("callback_received", callbackReceived)
                .put(
                    "init_status",
                    when (status) {
                        TextToSpeech.SUCCESS -> "success"
                        TextToSpeech.ERROR -> "error"
                        else -> "unknown"
                    }
                )
                .put("default_engine", nullable(engine.defaultEngine))
                .put(
                    "installed_engines",
                    JSONArray().apply {
                        engine.engines
                            .map { it.name }
                            .distinct()
                            .sorted()
                            .forEach(::put)
                    }
                )
                .put(
                    "max_input_length",
                    TextToSpeech.getMaxSpeechInputLength()
                )
        } finally {
            engine.shutdown()
        }
    }

    private fun recordingTextToSpeech(): RecordingTextToSpeech =
        RecordingTextToSpeech(
            InstrumentationRegistry.getInstrumentation().targetContext
        )

    private fun <T : Any> onMainThread(block: () -> T): T {
        val value = AtomicReference<T>()
        val failure = AtomicReference<Throwable>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            try {
                value.set(block())
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        failure.get()?.let { throw it }
        return requireNotNull(value.get())
    }

    private fun setPrivateField(
        owner: Class<*>,
        target: Any,
        name: String,
        value: Any?
    ) {
        owner.getDeclaredField(name)
            .apply { isAccessible = true }
            .set(target, value)
    }

    private fun privateField(
        owner: Class<*>,
        target: Any,
        name: String
    ): Any? =
        owner.getDeclaredField(name)
            .apply { isAccessible = true }
            .get(target)

    private class RecordingTextToSpeech(
        context: Context
    ) : TextToSpeech(context, OnInitListener {}) {
        val calls = mutableListOf<SpeechCall>()
        val speechRates = mutableListOf<Float>()
        var stopCount = 0
        var shutdownCount = 0

        override fun speak(
            text: CharSequence,
            queueMode: Int,
            params: Bundle?,
            utteranceId: String?
        ): Int {
            calls += SpeechCall(
                text.toString(),
                queueMode,
                utteranceId
            )
            return SUCCESS
        }

        override fun stop(): Int {
            stopCount++
            return SUCCESS
        }

        override fun shutdown() {
            shutdownCount++
        }

        override fun setSpeechRate(speechRate: Float): Int {
            speechRates += speechRate
            return SUCCESS
        }

        fun callProjection(): JSONArray =
            JSONArray().apply {
                calls.forEach { value ->
                    put(
                        JSONObject()
                            .put("text", value.text)
                            .put(
                                "queue",
                                when (value.queueMode) {
                                    QUEUE_FLUSH -> "flush"
                                    QUEUE_ADD -> "add"
                                    else -> "unknown"
                                }
                            )
                            .put(
                                "utterance_id",
                                value.utteranceId ?: JSONObject.NULL
                            )
                    )
                }
            }

        fun speechRateProjection(): JSONArray =
            JSONArray().apply {
                speechRates.forEach { put(it.toDouble()) }
            }

        fun releaseBaseEngine() {
            super.shutdown()
        }
    }

    private data class SpeechCall(
        val text: String,
        val queueMode: Int,
        val utteranceId: String?
    )

    private suspend fun runBookGroupBoundaryCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "book_group_allocation",
            "book_group_selection"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported book-group boundary operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                bookGroupBoundaryProjection(operation, arguments)
            }
        }
    }

    private suspend fun runLocalBookRelocationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation == "local_book_uri_resolution") {
                "Unsupported local-book relocation operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                localBookRelocationProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun runSearchBookLifecycleCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "search_book_merge",
            "search_book_room_replace",
            "search_book_source_cascade",
            "search_book_ttl_cleanup"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported search-book lifecycle operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                searchBookLifecycleProjection(
                    operation,
                    arguments
                )
            }
        }
    }

    private suspend fun runBookImportChannelCases() {
        val server = OracleBookInfoServer()
        server.start(5_000, true)
        try {
            val values = input.getJSONArray("cases")
            val supported = setOf(
                "url_book_import",
                "local_file_import",
                "local_directory_scan"
            )
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val operation = value.getString("operation")
                require(operation in supported) {
                    "Unsupported book-import operation: $operation"
                }
                val arguments = value.getJSONObject("arguments")
                val stimulus = JSONObject()
                    .put("operation", operation)
                    .put(
                        "arguments",
                        JSONObject(arguments.toString())
                    )
                runCase(
                    value.getString("id"),
                    operation,
                    stimulus
                ) {
                    bookImportChannelProjection(
                        value.getString("id"),
                        operation,
                        arguments,
                        server
                    )
                }
            }
        } finally {
            server.stop()
        }
    }

    private suspend fun bookImportChannelProjection(
        caseId: String,
        operation: String,
        arguments: JSONObject,
        server: OracleBookInfoServer
    ): JSONObject {
        val target =
            InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(
            target.filesDir,
            "oracle-book-import/$caseId"
        )
        root.deleteRecursively()
        require(root.mkdirs()) {
            "Unable to create book-import fixture root"
        }
        val previousNameRule = AppConfig.bookImportFileName
        val previousDefaultDirectory = AppConfig.defaultBookTreeUri
        AppConfig.bookImportFileName = null
        server.reset()
        return try {
            when (operation) {
                "url_book_import" ->
                    urlBookImportProjection(
                        caseId,
                        arguments,
                        server,
                        target.applicationContext as Application
                    )
                "local_file_import" ->
                    localFileImportProjection(
                        arguments,
                        root
                    )
                "local_directory_scan" ->
                    localDirectoryScanProjection(
                        root,
                        target.applicationContext as Application
                    )
                else -> error(
                    "Unsupported book-import operation: $operation"
                )
            }
        } finally {
            AppConfig.bookImportFileName = previousNameRule
            AppConfig.defaultBookTreeUri = previousDefaultDirectory
            val rootPath = root.absolutePath
            appDb.bookDao.all
                .filter {
                    it.bookUrl.startsWith(rootPath) ||
                        it.bookUrl.contains("/book/$caseId")
                }
                .forEach { appDb.bookDao.delete(it) }
            listOf(
                server.baseUrl,
                "oracle-pattern://invalid-$caseId",
                "oracle-pattern://valid-$caseId"
            ).forEach { appDb.bookSourceDao.delete(it) }
            root.deleteRecursively()
        }
    }

    private suspend fun urlBookImportProjection(
        caseId: String,
        arguments: JSONObject,
        server: OracleBookInfoServer,
        application: Application
    ): JSONObject {
        val sourceDao = appDb.bookSourceDao
        val previousSources = sourceDao.all.map { it.copy() }
        previousSources.forEach { sourceDao.delete(it) }
        val bookUrl = "${server.baseUrl}/book/$caseId"
        return try {
            appDb.bookDao.getBook(bookUrl)?.let {
                appDb.bookDao.delete(it)
            }
            val sourceMode = arguments.getString("source_mode")
            val exactSource = importBookSource(
                url = server.baseUrl,
                name = "Oracle Exact Source",
                pattern = null,
                order = 0
            )
            val invalidSource = importBookSource(
                url = "oracle-pattern://invalid-$caseId",
                name = "Oracle Invalid Pattern",
                pattern = "[",
                order = 0
            )
            val patternSource = importBookSource(
                url = "oracle-pattern://valid-$caseId",
                name = "Oracle Pattern Source",
                pattern = ".*/book/$caseId$",
                order = 1
            )
            when (sourceMode) {
                "existing" -> appDb.bookDao.insert(
                    Book(
                        bookUrl = bookUrl,
                        origin = "oracle-existing://seed",
                        originName = "Oracle Existing",
                        name = "Existing Oracle Book",
                        author = "Seed"
                    )
                )
                "exact_base" -> sourceDao.insert(exactSource)
                "pattern_after_invalid" ->
                    sourceDao.insert(
                        invalidSource,
                        patternSource
                    )
                "none" -> Unit
                else -> error(
                    "Unsupported URL source mode: $sourceMode"
                )
            }
            val inputValue =
                if (
                    arguments.getString("input_shape")
                        == "blank_lines_and_trim"
                ) {
                    "\n  $bookUrl  \n\n"
                } else {
                    "  $bookUrl  "
                }
            val viewModel = BookshelfViewModel(application)
            viewModel.addBookByUrl(inputValue)
            withTimeout(10_000) {
                while (
                    viewModel.addBookJob == null ||
                    viewModel.addBookJob?.isCompleted != true
                ) {
                    delay(20)
                }
            }
            val stored = appDb.bookDao.getBook(bookUrl)
            val selection = when (stored?.origin) {
                "oracle-existing://seed" ->
                    "existing_short_circuit"
                exactSource.bookSourceUrl -> "exact_base"
                patternSource.bookSourceUrl -> "pattern"
                else -> "none"
            }
            JSONObject()
                .put("channel", "url")
                .put(
                    "outcome",
                    when (selection) {
                        "existing_short_circuit" -> "existing"
                        "exact_base", "pattern" -> "added"
                        else -> "skipped"
                    }
                )
                .put("source_selection", selection)
                .put(
                    "network_request_count",
                    server.requestPaths.size
                )
                .put(
                    "stored_book",
                    stored?.let {
                        importedBookProjection(it, selection)
                    } ?: JSONObject.NULL
                )
        } finally {
            sourceDao.all.forEach { sourceDao.delete(it) }
            if (previousSources.isNotEmpty()) {
                sourceDao.insert(*previousSources.toTypedArray())
            }
        }
    }

    private fun importBookSource(
        url: String,
        name: String,
        pattern: String?,
        order: Int
    ): BookSource =
        BookSource(
            bookSourceUrl = url,
            bookSourceName = name,
            bookUrlPattern = pattern,
            customOrder = order,
            enabled = true,
            ruleBookInfo = BookInfoRule(
                name = "@CSS:h1.book-name@text",
                author = "@CSS:.book-author@text",
                intro = "@CSS:.book-intro@text",
                tocUrl = "@CSS:a.toc-link@href"
            )
        )

    private fun localFileImportProjection(
        arguments: JSONObject,
        root: File
    ): JSONObject {
        val mode = arguments.getString("mode")
        val file = File(root, arguments.getString("file_name"))
        val output = File(root, "output").apply {
            require(mkdirs())
        }
        AppConfig.defaultBookTreeUri = output.absolutePath
        var failure: Throwable? = null
        val books = when (mode) {
            "new_file" -> {
                file.writeText("第一章\n正文")
                listOf(LocalBook.importFile(Uri.fromFile(file)))
            }
            "reimport" -> {
                file.writeText("第一章\n正文")
                val first = LocalBook.importFile(Uri.fromFile(file))
                appDb.bookChapterDao.insert(
                    BookChapter(
                        url = "${first.bookUrl}#old",
                        title = "旧目录",
                        bookUrl = first.bookUrl,
                        index = 0
                    )
                )
                listOf(LocalBook.importFile(Uri.fromFile(file)))
            }
            "empty" -> {
                require(file.createNewFile())
                kotlin.runCatching {
                    LocalBook.importFile(Uri.fromFile(file))
                }.onFailure {
                    failure = it
                }
                emptyList()
            }
            "archive" -> {
                createImportArchive(
                    file,
                    arguments.getString("book_entry"),
                    arguments.getString("ignored_entry")
                )
                LocalBook.importFiles(Uri.fromFile(file))
            }
            else -> error("Unsupported local import mode: $mode")
        }
        return JSONObject()
            .put("channel", "local_file")
            .put(
                "outcome",
                when {
                    failure != null -> "rejected"
                    mode == "reimport" -> "updated"
                    mode == "archive" -> "archive_added"
                    else -> "added"
                }
            )
            .put(
                "exception",
                failure?.javaClass?.simpleName ?: JSONObject.NULL
            )
            .put("imported_count", books.size)
            .put(
                "books",
                JSONArray().apply {
                    books.sortedBy { it.originName }.forEach {
                        put(
                            importedBookProjection(
                                it,
                                if (it.isArchive) {
                                    "archive"
                                } else {
                                    "local_file"
                                }
                            )
                        )
                    }
                }
            )
            .put(
                "database_contains_input",
                appDb.bookDao.has(file.absolutePath) == true
            )
    }

    private fun createImportArchive(
        archive: File,
        bookEntry: String,
        ignoredEntry: String
    ) {
        ZipOutputStream(FileOutputStream(archive)).use { output ->
            listOf(
                bookEntry to "第一章\n压缩正文",
                ignoredEntry to "ignored"
            ).forEach { (name, body) ->
                output.putNextEntry(ZipEntry(name))
                output.write(body.toByteArray(Charsets.UTF_8))
                output.closeEntry()
            }
        }
    }

    private suspend fun localDirectoryScanProjection(
        root: File,
        application: Application
    ): JSONObject {
        File(root, "visible.txt").writeText("visible")
        File(root, ".hidden.txt").writeText("hidden")
        File(root, "bundle.zip").writeText("scan only")
        File(root, "ignore.md").writeText("ignored")
        val nested = File(root, "nested").apply {
            require(mkdirs())
        }
        File(nested, "inner.epub").writeText("epub")
        val hiddenDirectory = File(root, ".hidden-dir").apply {
            require(mkdirs())
        }
        File(hiddenDirectory, "secret.pdf").writeText("pdf")

        val discovered = mutableListOf<String>()
        val batchSizes = mutableListOf<Int>()
        var clearCount = 0
        var finallyCount = 0
        val viewModel = ImportBookViewModel(application)
        viewModel.dataCallback =
            object : ImportBookViewModel.DataCallback {
                override fun setItems(fileDocs: List<FileDoc>) = Unit

                override fun addItems(fileDocs: List<FileDoc>) {
                    batchSizes += fileDocs.size
                    discovered += fileDocs.map { it.name }
                }

                override fun clear() {
                    clearCount++
                }

                override fun screen(key: String?) = Unit
            }
        viewModel.scanDoc(
            FileDoc.fromFile(root),
            true
        ) {
            finallyCount++
        }
        return JSONObject()
            .put("channel", "local_scan")
            .put(
                "discovered_names",
                JSONArray().apply {
                    discovered.sorted().forEach { put(it) }
                }
            )
            .put("discovered_count", discovered.size)
            .put("add_batch_count", batchSizes.size)
            .put("clear_count", clearCount)
            .put("finally_count", finallyCount)
    }

    private fun importedBookProjection(
        book: Book,
        originKind: String
    ): JSONObject =
        JSONObject()
            .put("name", book.name)
            .put("author", book.author)
            .put("origin_name", book.originName)
            .put("origin_kind", originKind)
            .put("is_local", book.isLocal)
            .put("is_archive", book.isArchive)
            .put(
                "chapter_count",
                appDb.bookChapterDao.getChapterCount(book.bookUrl)
            )

    private class OracleBookInfoServer : NanoHTTPD(0) {
        val requestPaths = CopyOnWriteArrayList<String>()

        val baseUrl: String
            get() = "http://127.0.0.1:$listeningPort"

        fun reset() {
            requestPaths.clear()
        }

        override fun serve(session: IHTTPSession): Response {
            requestPaths += session.uri
            val caseId = session.uri.substringAfterLast('/')
            val body = """
                <html><body>
                <h1 class="book-name">Fetched $caseId</h1>
                <span class="book-author">Oracle Author</span>
                <p class="book-intro">Offline import fixture</p>
                <a class="toc-link" href="/toc/$caseId">目录</a>
                </body></html>
            """.trimIndent()
            return newFixedLengthResponse(
                Response.Status.OK,
                "text/html; charset=utf-8",
                body
            )
        }
    }

    private suspend fun searchBookLifecycleProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject =
        when (operation) {
            "search_book_merge" ->
                searchBookMergeProjection(arguments)
            "search_book_room_replace" ->
                searchBookReplaceProjection(arguments)
            "search_book_source_cascade" ->
                searchBookCascadeProjection(arguments)
            "search_book_ttl_cleanup" ->
                searchBookTTLProjection(arguments)
            else -> error(
                "Unsupported search-book lifecycle operation: $operation"
            )
        }

    private suspend fun searchBookMergeProjection(
        arguments: JSONObject
    ): JSONObject {
        val model = SearchModel(
            CoroutineScope(coroutineContext),
            object : SearchModel.CallBack {
                override fun getSearchScope() =
                    SearchScope(emptyList<String>())

                override fun onSearchStart() = Unit

                override fun onSearchSuccess(
                    searchBooks: List<SearchBook>
                ) = Unit

                override fun onSearchFinish(isEmpty: Boolean) = Unit

                override fun onSearchCancel(exception: Throwable?) = Unit
            }
        )
        searchModelField("searchKey").set(
            model,
            arguments.getString("keyword")
        )
        val precision = arguments.getBoolean("precision")
        val batches = arguments.getJSONArray("batches")
        for (index in 0 until batches.length()) {
            val values = batches.getJSONArray(index)
            val books = ArrayList<SearchBook>()
            for (bookIndex in 0 until values.length()) {
                books += searchBook(values.getJSONObject(bookIndex))
            }
            invokeSearchBookMerge(model, books, precision)
        }
        @Suppress("UNCHECKED_CAST")
        val merged = searchModelField("searchBooks").get(model)
            as ArrayList<SearchBook>
        return JSONObject()
            .put("count", merged.size)
            .put(
                "books",
                JSONArray().apply {
                    merged.forEach { book ->
                        put(
                            JSONObject()
                                .put("name", book.name)
                                .put("author", book.author)
                                .put("book_url", book.bookUrl)
                                .put("representative_origin", book.origin)
                                .put("origin_order", book.originOrder)
                                .put(
                                    "origins",
                                    JSONArray().apply {
                                        book.origins.forEach(::put)
                                    }
                                )
                        )
                    }
                }
            )
    }

    private suspend fun invokeSearchBookMerge(
        model: SearchModel,
        books: List<SearchBook>,
        precision: Boolean
    ) {
        val method = SearchModel::class.java.declaredMethods
            .single {
                it.name.startsWith("mergeItems") &&
                    it.parameterTypes.size == 3
            }
            .apply { isAccessible = true }
        suspendCoroutine<Unit> { continuation ->
            try {
                val result = method.invoke(
                    model,
                    books,
                    precision,
                    continuation
                )
                if (result !== COROUTINE_SUSPENDED) {
                    continuation.resume(Unit)
                }
            } catch (error: InvocationTargetException) {
                continuation.resumeWithException(
                    error.targetException ?: error
                )
            } catch (error: Throwable) {
                continuation.resumeWithException(error)
            }
        }
    }

    private fun searchModelField(name: String) =
        SearchModel::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }

    private fun searchBook(value: JSONObject) =
        SearchBook(
            name = value.getString("name"),
            author = value.getString("author"),
            bookUrl = value.getString("book_url"),
            origin = value.getString("origin"),
            originName = value.getString("origin"),
            originOrder = value.getInt("origin_order")
        )

    private fun searchBookReplaceProjection(
        arguments: JSONObject
    ): JSONObject {
        val origin = arguments.getString("origin")
        val bookURL = arguments.getString("book_url")
        prepareSearchBookSource(origin)
        return try {
            val dao = appDb.searchBookDao
            val first = SearchBook(
                bookUrl = bookURL,
                origin = origin,
                originName = origin,
                name = arguments.getString("first_name"),
                author = "Oracle"
            )
            val second = first.copy(
                name = arguments.getString("second_name")
            )
            val insertResults = JSONArray().apply {
                dao.insert(first).forEach(::put)
                dao.insert(second).forEach(::put)
            }
            val stored = requireNotNull(dao.getSearchBook(bookURL))
            JSONObject()
                .put("insert_results", insertResults)
                .put("stored_name", stored.name)
                .put("stored_origin", stored.origin)
        } finally {
            clearSearchBookFixture(origin)
        }
    }

    private fun searchBookCascadeProjection(
        arguments: JSONObject
    ): JSONObject {
        val origin = arguments.getString("origin")
        val bookURL = arguments.getString("book_url")
        prepareSearchBookSource(origin)
        return try {
            appDb.searchBookDao.insert(
                SearchBook(
                    bookUrl = bookURL,
                    origin = origin,
                    originName = origin,
                    name = "Cascade",
                    author = "Oracle"
                )
            )
            val before = appDb.searchBookDao
                .getSearchBook(bookURL) != null
            appDb.bookSourceDao.delete(origin)
            val after = appDb.searchBookDao
                .getSearchBook(bookURL) != null
            JSONObject()
                .put("exists_before_source_delete", before)
                .put("exists_after_source_delete", after)
        } finally {
            clearSearchBookFixture(origin)
        }
    }

    private fun searchBookTTLProjection(
        arguments: JSONObject
    ): JSONObject {
        val origin = arguments.getString("origin")
        val threshold = arguments.getLong("threshold")
        val rows = listOf(
            "stale" to arguments.getLong("stale_time"),
            "boundary" to arguments.getLong("boundary_time"),
            "fresh" to arguments.getLong("fresh_time")
        )
        prepareSearchBookSource(origin)
        return try {
            val dao = appDb.searchBookDao
            rows.forEach { (label, time) ->
                dao.insert(
                    SearchBook(
                        bookUrl = "book://ttl/$label",
                        origin = origin,
                        originName = origin,
                        name = label,
                        author = "Oracle",
                        time = time
                    )
                )
            }
            dao.clearExpired(threshold)
            JSONObject()
                .put("threshold", threshold)
                .put(
                    "remaining",
                    JSONArray().apply {
                        rows.forEach { (label, _) ->
                            if (
                                dao.getSearchBook(
                                    "book://ttl/$label"
                                ) != null
                            ) {
                                put(label)
                            }
                        }
                    }
                )
        } finally {
            clearSearchBookFixture(origin)
        }
    }

    private fun prepareSearchBookSource(origin: String) {
        clearSearchBookFixture(origin)
        appDb.bookSourceDao.insert(
            BookSource(
                bookSourceUrl = origin,
                bookSourceName = "Oracle $origin",
                customOrder = 1
            )
        )
    }

    private fun clearSearchBookFixture(origin: String) {
        appDb.bookSourceDao.delete(origin)
    }

    private suspend fun localBookRelocationProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        val target =
            InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(
            target.filesDir,
            "oracle-local-book-relocation/$caseId"
        )
        root.deleteRecursively()
        require(root.mkdirs()) {
            "Unable to create local-book relocation fixture root"
        }
        val originalDir = File(root, "original").apply {
            require(mkdirs())
        }
        val defaultDir = File(root, "default").apply {
            require(mkdirs())
        }
        val importDir = File(root, "import").apply {
            require(mkdirs())
        }
        val originName = "oracle-book.txt"
        val originalFile = File(originalDir, originName)
        val defaultFile = File(defaultDir, originName)
        val importFile = File(importDir, originName)
        val content = "第一章 起点\n这是迁移后的本地正文。\n第二章 继续\n结束。"
        if (arguments.getBoolean("original_exists")) {
            originalFile.writeText(content)
        }
        configureRelocationDirectory(
            defaultDir,
            defaultFile,
            arguments.getString("default_directory"),
            content
        )
        configureRelocationDirectory(
            importDir,
            importFile,
            arguments.getString("import_directory"),
            content
        )

        val oldBookUrl = originalFile.absolutePath
        val book = Book(
            bookUrl = oldBookUrl,
            tocUrl = "",
            origin = BookType.localTag,
            originName = originName,
            name = "Oracle Relocation $caseId",
            author = "Oracle",
            type = BookType.local
        )
        val previousDefaultDirectory = AppConfig.defaultBookTreeUri
        val previousImportDirectory = AppConfig.importBookPath
        val previousTxtTocRules =
            appDb.txtTocRuleDao.all.map { it.copy() }
        clearLocalBookRelocationState()
        book.removeLocalUriCache()
        appDb.bookDao.insert(book)
        appDb.bookChapterDao.insert(
            BookChapter(
                url = "$oldBookUrl#old",
                title = "旧目录",
                bookUrl = oldBookUrl,
                index = 0
            )
        )
        AppConfig.defaultBookTreeUri =
            relocationDirectoryValue(
                defaultDir,
                arguments.getString("default_directory")
            )
        AppConfig.importBookPath =
            relocationDirectoryValue(
                importDir,
                arguments.getString("import_directory")
            )

        return try {
            val firstUri = book.getLocalUri()
            val relocatedBookUrl = book.bookUrl
            val firstLocation = relocationLocation(
                firstUri.path,
                originalFile,
                defaultFile,
                importFile
            )
            val databaseAfterResolution = JSONObject()
                .put(
                    "old_book_exists",
                    appDb.bookDao.has(oldBookUrl) == true
                )
                .put(
                    "current_book_exists",
                    appDb.bookDao.has(relocatedBookUrl) == true
                )
                .put(
                    "old_chapter_count",
                    appDb.bookChapterDao
                        .getChapterCount(oldBookUrl)
                )
                .put(
                    "current_chapter_count",
                    appDb.bookChapterDao
                        .getChapterCount(relocatedBookUrl)
                )

            var chapterReload = JSONObject.NULL
            if (arguments.getBoolean("load_chapter_list")) {
                replaceTxtTocRulesForRelocation()
                ReadBook.resetData(book)
                val viewModel = ReadBookViewModel(
                    target.applicationContext as Application
                )
                viewModel.loadChapterList(book)
                withTimeout(5_000) {
                    while (
                        appDb.bookChapterDao
                            .getChapterCount(book.bookUrl) == 0
                    ) {
                        delay(20)
                    }
                }
                chapterReload = JSONObject()
                    .put(
                        "book_exists",
                        appDb.bookDao.has(book.bookUrl) == true
                    )
                    .put(
                        "chapter_count",
                        appDb.bookChapterDao
                            .getChapterCount(book.bookUrl)
                    )
                    .put(
                        "old_chapter_count",
                        appDb.bookChapterDao
                            .getChapterCount(oldBookUrl)
                    )
                    .put(
                        "read_book_identity_is_current",
                        ReadBook.book?.bookUrl == book.bookUrl
                    )
            }

            var secondLocation: Any = JSONObject.NULL
            var secondBookUrlState: Any = JSONObject.NULL
            if (
                arguments.getBoolean(
                    "create_default_match_after_first_resolution"
                )
            ) {
                defaultFile.writeText(content)
                val secondUri = book.getLocalUri()
                secondLocation = relocationLocation(
                    secondUri.path,
                    originalFile,
                    defaultFile,
                    importFile
                )
                secondBookUrlState =
                    if (book.bookUrl == oldBookUrl) {
                        "unchanged"
                    } else {
                        "relocated"
                    }
            }

            JSONObject()
                .put("first_location", firstLocation)
                .put(
                    "book_url_state",
                    when (book.bookUrl) {
                        oldBookUrl -> "unchanged"
                        defaultFile.absolutePath ->
                            "relocated_to_default"
                        importFile.absolutePath ->
                            "relocated_to_import"
                        else -> "other"
                    }
                )
                .put(
                    "returned_uri_readable",
                    firstUri.path?.let { File(it).isFile } == true
                )
                .put(
                    "database_after_resolution",
                    databaseAfterResolution
                )
                .put("chapter_reload", chapterReload)
                .put("second_location", secondLocation)
                .put(
                    "second_book_url_state",
                    secondBookUrlState
                )
        } finally {
            AppConfig.defaultBookTreeUri = previousDefaultDirectory
            AppConfig.importBookPath = previousImportDirectory
            Book(bookUrl = oldBookUrl).removeLocalUriCache()
            Book(bookUrl = defaultFile.absolutePath)
                .removeLocalUriCache()
            Book(bookUrl = importFile.absolutePath)
                .removeLocalUriCache()
            restoreTxtTocRules(previousTxtTocRules)
            ReadBook.book = null
            clearLocalBookRelocationState()
            root.deleteRecursively()
        }
    }

    private fun configureRelocationDirectory(
        directory: File,
        matchingFile: File,
        state: String,
        content: String
    ) {
        when (state) {
            "absent" -> Unit
            "matching" -> matchingFile.writeText(content)
            "nonmatching" ->
                File(directory, "another-book.txt")
                    .writeText(content)
            else -> error(
                "Unsupported relocation directory state: $state"
            )
        }
    }

    private fun relocationDirectoryValue(
        directory: File,
        state: String
    ): String? = if (state == "absent") {
        null
    } else {
        directory.absolutePath
    }

    private fun relocationLocation(
        path: String?,
        originalFile: File,
        defaultFile: File,
        importFile: File
    ): String = when (path) {
        originalFile.absolutePath -> "original"
        defaultFile.absolutePath -> "default"
        importFile.absolutePath -> "import"
        else -> "other"
    }

    private fun clearLocalBookRelocationState() {
        appDb.bookDao.all
            .filter {
                it.name.startsWith("Oracle Relocation ")
            }
            .forEach {
                appDb.bookDao.delete(it)
            }
    }

    private fun replaceTxtTocRulesForRelocation() {
        val dao = appDb.txtTocRuleDao
        val existing = dao.all
        if (existing.isNotEmpty()) {
            dao.delete(*existing.toTypedArray())
        }
        dao.insert(
            TxtTocRule(
                id = 9_223_372_036_854_775_000L,
                name = "Oracle relocation headings",
                rule = "^第[一二]章.{0,30}$",
                serialNumber = 0,
                enable = true
            )
        )
    }

    private fun restoreTxtTocRules(
        previous: List<TxtTocRule>
    ) {
        val dao = appDb.txtTocRuleDao
        val current = dao.all
        if (current.isNotEmpty()) {
            dao.delete(*current.toTypedArray())
        }
        if (previous.isNotEmpty()) {
            dao.insert(*previous.toTypedArray())
        }
    }

    private suspend fun bookGroupBoundaryProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        val dao = appDb.bookGroupDao
        val previous = dao.all.map { it.copy() }
        clearBookGroups()
        return try {
            when (operation) {
                "book_group_allocation" ->
                    bookGroupAllocationProjection(arguments)
                "book_group_selection" ->
                    bookGroupSelectionProjection(arguments)
                else -> error(
                    "Unsupported book-group boundary operation"
                )
            }
        } finally {
            clearBookGroups()
            if (previous.isNotEmpty()) {
                dao.insert(*previous.toTypedArray())
            }
        }
    }

    private suspend fun bookGroupAllocationProjection(
        arguments: JSONObject
    ): JSONObject {
        val dao = appDb.bookGroupDao
        val positiveBitCount =
            arguments.getInt("positive_bit_count")
        seedPositiveBookGroups(positiveBitCount)
        val canAddBefore = dao.canAddGroup
        val allocatedId = dao.getUnusedId()
        val existingBeforeInsert = dao.getByID(allocatedId) != null
        val inserted = arguments.getBoolean("insert_allocated")
        if (inserted) {
            dao.insert(
                BookGroup(
                    groupId = allocatedId,
                    groupName = "allocated-boundary",
                    order = positiveBitCount + 1
                )
            )
        }
        val visibleIds = dao.flowSelect().first().map { it.groupId }
        val repeatedUnusedId = dao.getUnusedId()
        return JSONObject()
            .put("positive_bit_count", positiveBitCount)
            .put("can_add_before", canAddBefore)
            .put("allocated_id", allocatedId)
            .put("allocated_hex", longHex(allocatedId))
            .put("allocated_is_negative", allocatedId < 0)
            .put(
                "allocated_is_valid_one_hot",
                dao.isInRules(allocatedId)
            )
            .put(
                "allocated_existed_before_insert",
                existingBeforeInsert
            )
            .put("inserted", inserted)
            .put("can_add_after", dao.canAddGroup)
            .put(
                "allocated_visible_in_flow_select",
                allocatedId in visibleIds
            )
            .put(
                "allocated_group_names",
                JSONArray(dao.getGroupNames(allocatedId))
            )
            .put("repeated_unused_id", repeatedUnusedId)
            .put("repeated_unused_hex", longHex(repeatedUnusedId))
            .put(
                "repeated_id_collides_with_allocated",
                inserted && repeatedUnusedId == allocatedId
            )
            .put("stored_group_count", dao.all.size)
    }

    private suspend fun bookGroupSelectionProjection(
        arguments: JSONObject
    ): JSONObject {
        val dao = appDb.bookGroupDao
        val positiveBitCount =
            arguments.getInt("positive_bit_count")
        seedPositiveBookGroups(positiveBitCount)
        val includeMinValue =
            arguments.getBoolean("include_min_value")
        if (includeMinValue) {
            dao.insert(
                BookGroup(
                    groupId = Long.MIN_VALUE,
                    groupName = "bit-min-value",
                    order = positiveBitCount + 1
                )
            )
        }
        val mixedPositiveBitIndex =
            arguments.getInt("mixed_positive_bit_index")
        require(
            mixedPositiveBitIndex in 0 until positiveBitCount
        ) {
            "mixed_positive_bit_index must reference a seeded bit"
        }
        val positiveId = 1L shl mixedPositiveBitIndex
        val boundaryMask = Long.MIN_VALUE
        val mixedMask = boundaryMask or positiveId
        val all = dao.all
        val selectable = dao.flowSelect().first()
        return JSONObject()
            .put("positive_bit_count", positiveBitCount)
            .put("stored_group_count", all.size)
            .put("flow_select_count", selectable.size)
            .put(
                "boundary_present_in_all",
                all.any { it.groupId == Long.MIN_VALUE }
            )
            .put(
                "boundary_present_in_flow_select",
                selectable.any { it.groupId == Long.MIN_VALUE }
            )
            .put(
                "boundary_group_names",
                JSONArray(dao.getGroupNames(boundaryMask))
            )
            .put(
                "mixed_mask_group_names",
                JSONArray(dao.getGroupNames(mixedMask))
            )
            .put("mixed_mask", mixedMask)
            .put("mixed_mask_hex", longHex(mixedMask))
            .put(
                "boundary_is_valid_one_hot",
                dao.isInRules(Long.MIN_VALUE)
            )
            .put("can_add_group", dao.canAddGroup)
    }

    private fun seedPositiveBookGroups(count: Int) {
        require(count in 0..63) {
            "positive_bit_count must be between 0 and 63"
        }
        if (count == 0) {
            return
        }
        appDb.bookGroupDao.insert(
            *(0 until count).map { index ->
                BookGroup(
                    groupId = 1L shl index,
                    groupName = "bit-${index.toString().padStart(2, '0')}",
                    order = index + 1
                )
            }.toTypedArray()
        )
    }

    private fun clearBookGroups() {
        val values = appDb.bookGroupDao.all
        if (values.isNotEmpty()) {
            appDb.bookGroupDao.delete(*values.toTypedArray())
        }
    }

    private fun longHex(value: Long): String =
        java.lang.Long.toUnsignedString(value, 16).padStart(16, '0')

    private suspend fun runChapterSourceOverrideCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "chapter_source_fetch",
            "chapter_source_replace",
            "chapter_source_overwrite",
            "chapter_source_invalidate_recover"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported chapter-source operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            val caseId = value.getString("id")
            runCase(caseId, operation, stimulus) {
                chapterSourceOverrideProjection(
                    caseId,
                    operation,
                    arguments
                )
            }
        }
    }

    private suspend fun chapterSourceOverrideProjection(
        caseId: String,
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        val fixture = chapterSourceFixture(caseId, arguments)
        clearChapterSourceFixture(fixture)
        appDb.bookSourceDao.insert(
            fixture.currentSource,
            fixture.alternativeSource
        )
        appDb.bookDao.insert(fixture.currentBook)
        appDb.bookChapterDao.insert(fixture.currentChapter)
        return try {
            when (operation) {
                "chapter_source_fetch" ->
                    chapterSourceFetchProjection(fixture)
                "chapter_source_replace" ->
                    chapterSourceReplaceProjection(fixture)
                "chapter_source_overwrite" ->
                    chapterSourceOverwriteProjection(
                        fixture,
                        arguments.getString(
                            "existing_cache_content"
                        )
                    )
                "chapter_source_invalidate_recover" ->
                    chapterSourceRecoveryProjection(fixture)
                else -> error(
                    "Unsupported chapter-source operation"
                )
            }
        } finally {
            delay(100)
            clearChapterSourceFixture(fixture)
        }
    }

    private suspend fun chapterSourceFetchProjection(
        fixture: ChapterSourceFixture
    ): JSONObject {
        val fetched = fetchAlternativeChapter(fixture)
        return JSONObject()
            .put("fetched_content", fetched)
            .put(
                "current_cache_content",
                BookHelp.getContent(
                    fixture.currentBook,
                    fixture.currentChapter
                ) ?: JSONObject.NULL
            )
            .put(
                "alternative_cache_content",
                BookHelp.getContent(
                    fixture.alternativeBook,
                    fixture.alternativeChapter
                ) ?: JSONObject.NULL
            )
            .put(
                "alternative_book_persisted",
                appDb.bookDao.getBook(
                    fixture.alternativeBook.bookUrl
                ) != null
            )
            .put(
                "alternative_chapter_persisted",
                appDb.bookChapterDao.getChapter(
                    fixture.alternativeBook.bookUrl,
                    fixture.alternativeChapter.index
                ) != null
            )
    }

    private suspend fun chapterSourceReplaceProjection(
        fixture: ChapterSourceFixture
    ): JSONObject {
        val fetched = fetchAlternativeChapter(fixture)
        saveReplacementUnderCurrentIdentity(fixture, fetched)
        val persistedBook = requireNotNull(
            appDb.bookDao.getBook(fixture.currentBook.bookUrl)
        )
        val persistedChapter = requireNotNull(
            appDb.bookChapterDao.getChapter(
                fixture.currentBook.bookUrl,
                fixture.currentChapter.index
            )
        )
        return JSONObject()
            .put("fetched_content", fetched)
            .put(
                "current_cache_content",
                BookHelp.getContent(
                    fixture.currentBook,
                    fixture.currentChapter
                ) ?: JSONObject.NULL
            )
            .put(
                "alternative_cache_content",
                BookHelp.getContent(
                    fixture.alternativeBook,
                    fixture.alternativeChapter
                ) ?: JSONObject.NULL
            )
            .put("persisted_book_origin", persistedBook.origin)
            .put(
                "persisted_chapter_book_url",
                persistedChapter.bookUrl
            )
            .put(
                "persisted_chapter_url",
                persistedChapter.url
            )
            .put(
                "alternative_origin_persisted_in_current_book",
                persistedBook.origin ==
                    fixture.alternativeSource.bookSourceUrl
            )
            .put(
                "alternative_book_persisted",
                appDb.bookDao.getBook(
                    fixture.alternativeBook.bookUrl
                ) != null
            )
            .put(
                "alternative_chapter_persisted",
                appDb.bookChapterDao.getChapter(
                    fixture.alternativeBook.bookUrl,
                    fixture.alternativeChapter.index
                ) != null
            )
    }

    private suspend fun chapterSourceOverwriteProjection(
        fixture: ChapterSourceFixture,
        existingContent: String
    ): JSONObject {
        BookHelp.saveText(
            fixture.currentBook,
            fixture.currentChapter,
            existingContent
        )
        val before = BookHelp.getContent(
            fixture.currentBook,
            fixture.currentChapter
        )
        val fetched = fetchAlternativeChapter(fixture)
        saveReplacementUnderCurrentIdentity(fixture, fetched)
        return JSONObject()
            .put(
                "existing_cache_before",
                before ?: JSONObject.NULL
            )
            .put("fetched_content", fetched)
            .put(
                "current_cache_after",
                BookHelp.getContent(
                    fixture.currentBook,
                    fixture.currentChapter
                ) ?: JSONObject.NULL
            )
            .put(
                "alternative_cache_content",
                BookHelp.getContent(
                    fixture.alternativeBook,
                    fixture.alternativeChapter
                ) ?: JSONObject.NULL
            )
    }

    private suspend fun chapterSourceRecoveryProjection(
        fixture: ChapterSourceFixture
    ): JSONObject {
        val fetched = fetchAlternativeChapter(fixture)
        saveReplacementUnderCurrentIdentity(fixture, fetched)
        val beforeInvalidation = BookHelp.getContent(
            fixture.currentBook,
            fixture.currentChapter
        )
        BookHelp.delContent(
            fixture.currentBook,
            fixture.currentChapter
        )
        val afterInvalidation = BookHelp.getContent(
            fixture.currentBook,
            fixture.currentChapter
        )
        val recovered = WebBook.getContentAwait(
            fixture.currentSource,
            fixture.currentBook,
            fixture.currentChapter,
            null,
            true
        )
        return JSONObject()
            .put(
                "replacement_cache_before_invalidation",
                beforeInvalidation ?: JSONObject.NULL
            )
            .put(
                "cache_after_invalidation",
                afterInvalidation ?: JSONObject.NULL
            )
            .put("recovered_content", recovered)
            .put(
                "cache_after_recovery",
                BookHelp.getContent(
                    fixture.currentBook,
                    fixture.currentChapter
                ) ?: JSONObject.NULL
            )
            .put(
                "recovery_source_origin",
                fixture.currentSource.bookSourceUrl
            )
            .put(
                "alternative_cache_content",
                BookHelp.getContent(
                    fixture.alternativeBook,
                    fixture.alternativeChapter
                ) ?: JSONObject.NULL
            )
    }

    private suspend fun fetchAlternativeChapter(
        fixture: ChapterSourceFixture
    ): String {
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        val deferred = CompletableDeferred<String>()
        ChangeChapterSourceViewModel(application).getContent(
            fixture.alternativeBook,
            fixture.alternativeChapter,
            null,
            success = {
                deferred.complete(it)
            },
            error = {
                deferred.completeExceptionally(
                    IllegalStateException(it)
                )
            }
        )
        return withTimeout(5_000) {
            deferred.await()
        }
    }

    private suspend fun saveReplacementUnderCurrentIdentity(
        fixture: ChapterSourceFixture,
        content: String
    ) {
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        ReadBook.resetData(fixture.currentBook)
        ReadBookViewModel(application).saveContent(
            fixture.currentBook,
            content
        )
        withTimeout(5_000) {
            while (
                BookHelp.getContent(
                    fixture.currentBook,
                    fixture.currentChapter
                ) != content
            ) {
                delay(10)
            }
        }
    }

    private fun chapterSourceFixture(
        caseId: String,
        arguments: JSONObject
    ): ChapterSourceFixture {
        val currentSource = BookSource(
            bookSourceUrl = "oracle-current://$caseId",
            bookSourceName = "Oracle 当前书源 $caseId",
            ruleContent = ContentRule(
                content = "@CSS:#current-content@text"
            )
        )
        val alternativeSource = BookSource(
            bookSourceUrl = "oracle-alternative://$caseId",
            bookSourceName = "Oracle 替代书源 $caseId",
            ruleContent = ContentRule()
        )
        val currentBook = Book(
            bookUrl = "oracle-current-book://$caseId",
            tocUrl = "oracle-current-book://$caseId",
            origin = currentSource.bookSourceUrl,
            originName = currentSource.bookSourceName,
            name = "Oracle 当前书 $caseId",
            author = "Oracle",
            totalChapterNum = 1,
            durChapterIndex = 0
        ).apply {
            tocHtml = (
                "<div id=\"current-content\">" +
                    arguments.getString("current_content") +
                    "</div>"
            )
        }
        val alternativeBook = Book(
            bookUrl = "oracle-alternative-book://$caseId",
            tocUrl = "oracle-alternative-book://$caseId",
            origin = alternativeSource.bookSourceUrl,
            originName = alternativeSource.bookSourceName,
            name = "Oracle 替代书 $caseId",
            author = "Oracle"
        )
        val currentChapter = BookChapter(
            url = currentBook.bookUrl,
            title = "当前章节 $caseId",
            baseUrl = currentBook.tocUrl,
            bookUrl = currentBook.bookUrl,
            index = 0
        )
        val alternativeChapter = BookChapter(
            url = arguments.getString("alternative_content"),
            title = "替代章节 $caseId",
            baseUrl = alternativeBook.tocUrl,
            bookUrl = alternativeBook.bookUrl,
            index = 0
        )
        return ChapterSourceFixture(
            currentSource,
            alternativeSource,
            currentBook,
            alternativeBook,
            currentChapter,
            alternativeChapter
        )
    }

    private fun clearChapterSourceFixture(
        fixture: ChapterSourceFixture
    ) {
        ReadBook.clearTextChapter()
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.chapterSize = 0
        BookHelp.clearCache(fixture.currentBook)
        BookHelp.clearCache(fixture.alternativeBook)
        appDb.bookDao.getBook(fixture.currentBook.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookDao.getBook(fixture.alternativeBook.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookSourceDao.delete(
            fixture.currentSource.bookSourceUrl
        )
        appDb.bookSourceDao.delete(
            fixture.alternativeSource.bookSourceUrl
        )
    }

    private data class ChapterSourceFixture(
        val currentSource: BookSource,
        val alternativeSource: BookSource,
        val currentBook: Book,
        val alternativeBook: Book,
        val currentChapter: BookChapter,
        val alternativeChapter: BookChapter
    )

    private suspend fun runBookmarkRuntimeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation == "bookmark_search" ||
                    operation == "bookmark_insert_conflict"
            ) {
                "Unsupported bookmark runtime operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                bookmarkRuntimeProjection(operation, arguments)
            }
        }
    }

    private suspend fun bookmarkRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearBookmarks()
        return try {
            val rows = arguments.getJSONArray("rows")
            for (index in 0 until rows.length()) {
                appDb.bookmarkDao.insert(bookmark(rows.getJSONObject(index)))
            }
            val selected = when (operation) {
                "bookmark_search" -> appDb.bookmarkDao.flowSearch(
                    arguments.getString("book_name"),
                    arguments.getString("book_author"),
                    arguments.getString("key")
                ).first()
                "bookmark_insert_conflict" -> appDb.bookmarkDao.all
                else -> error("Unsupported bookmark runtime operation")
            }
            JSONObject()
                .put("row_count", selected.size)
                .put(
                    "rows",
                    JSONArray().apply {
                        selected.forEach { put(bookmarkProjection(it)) }
                    }
                )
        } finally {
            clearBookmarks()
        }
    }

    private fun clearBookmarks() {
        val existing = appDb.bookmarkDao.all
        if (existing.isNotEmpty()) {
            appDb.bookmarkDao.delete(*existing.toTypedArray())
        }
    }

    private fun bookmark(value: JSONObject): Bookmark = Bookmark(
        time = value.getLong("time"),
        bookName = value.getString("bookName"),
        bookAuthor = value.getString("bookAuthor"),
        chapterIndex = value.getInt("chapterIndex"),
        chapterPos = value.getInt("chapterPos"),
        chapterName = value.getString("chapterName"),
        bookText = value.getString("bookText"),
        content = value.getString("content")
    )

    private fun bookmarkProjection(value: Bookmark): JSONObject =
        JSONObject()
            .put("time", value.time)
            .put("book_name", value.bookName)
            .put("book_author", value.bookAuthor)
            .put("chapter_index", value.chapterIndex)
            .put("chapter_pos", value.chapterPos)
            .put("chapter_name", value.chapterName)
            .put("book_text", value.bookText)
            .put("content", value.content)

    private suspend fun runReadRecordRuntimeCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "read_record_query",
            "read_record_reset",
            "read_record_session_write",
            "read_record_pause_boundary",
            "read_record_disabled",
            "read_record_insert_conflict"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported read-record runtime operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                readRecordRuntimeProjection(operation, arguments)
            }
        }
    }

    private fun readRecordRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearReadRecords()
        return try {
            when (operation) {
                "read_record_query" ->
                    readRecordQueryProjection(arguments)
                "read_record_reset" ->
                    readRecordResetProjection(arguments)
                "read_record_session_write" ->
                    readRecordSessionWriteProjection(arguments)
                "read_record_pause_boundary" ->
                    readRecordPauseProjection(arguments)
                "read_record_disabled" ->
                    readRecordDisabledProjection(arguments)
                "read_record_insert_conflict" ->
                    readRecordConflictProjection(arguments)
                else -> error("Unsupported read-record runtime operation")
            }
        } finally {
            drainReadBookExecutor()
            ReadBook.book = null
            clearReadRecords()
        }
    }

    private fun readRecordQueryProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val deviceIds = arguments.getJSONArray("device_ids")
        return JSONObject()
            .put(
                "all_device_read_time",
                appDb.readRecordDao.getReadTime(bookName)
                    ?: JSONObject.NULL
            )
            .put("all_books_read_time", appDb.readRecordDao.allTime)
            .put(
                "per_device",
                JSONArray().apply {
                    for (index in 0 until deviceIds.length()) {
                        val deviceId = deviceIds.getString(index)
                        put(
                            JSONObject()
                                .put("device_id", deviceId)
                                .put(
                                    "read_time",
                                    appDb.readRecordDao.getReadTime(
                                        deviceId,
                                        bookName
                                    ) ?: JSONObject.NULL
                                )
                        )
                    }
                }
            )
    }

    private fun readRecordResetProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val aggregate = requireNotNull(
            appDb.readRecordDao.getReadTime(bookName)
        )
        ReadBook.resetData(readRecordBook(bookName, "reset"))
        val session = currentSessionReadRecord()
        return JSONObject()
            .put("aggregate_before_reset", aggregate)
            .put("session_device_id", session.deviceId)
            .put("session_book_name", session.bookName)
            .put("session_read_time", session.readTime)
            .put(
                "session_uses_all_device_total",
                session.readTime == aggregate
            )
    }

    private fun readRecordSessionWriteProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val aggregateBefore = requireNotNull(
            appDb.readRecordDao.getReadTime(bookName)
        )
        val foreignRowsBefore = readRecordRows()
            .filter { it.bookName == bookName && it.deviceId.isNotEmpty() }
        val foreignTotal = foreignRowsBefore.sumOf { it.readTime }
        val previousEnabled = AppConfig.enableReadRecord
        return try {
            AppConfig.enableReadRecord = true
            ReadBook.resetData(readRecordBook(bookName, "session-write"))
            ReadBook.readStartTime = System.currentTimeMillis()
            ReadBook.upReadTime()
            drainReadBookExecutor()
            val empty = requireNotNull(
                readRecordRows().firstOrNull {
                    it.bookName == bookName && it.deviceId.isEmpty()
                }
            )
            val foreignRowsAfter = readRecordRows()
                .filter {
                    it.bookName == bookName && it.deviceId.isNotEmpty()
                }
            val aggregateAfter = requireNotNull(
                appDb.readRecordDao.getReadTime(bookName)
            )
            JSONObject()
                .put("aggregate_before", aggregateBefore)
                .put("foreign_device_total", foreignTotal)
                .put("inserted_device_id", empty.deviceId)
                .put(
                    "inserted_at_least_aggregate_before",
                    empty.readTime >= aggregateBefore
                )
                .put(
                    "session_delta_nonnegative",
                    empty.readTime - aggregateBefore >= 0
                )
                .put(
                    "foreign_rows_preserved",
                    readRecordRowsEqual(
                        foreignRowsBefore,
                        foreignRowsAfter
                    )
                )
                .put(
                    "aggregate_after_minus_empty_row",
                    aggregateAfter - empty.readTime
                )
                .put(
                    "foreign_time_counted_twice",
                    aggregateAfter >= aggregateBefore + foreignTotal
                )
        } finally {
            AppConfig.enableReadRecord = previousEnabled
        }
    }

    private fun readRecordPauseProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        ReadBook.resetData(readRecordBook(bookName, "pause"))
        val session = currentSessionReadRecord()
        val fixedStart = arguments.getLong("read_start_time")
        ReadBook.readStartTime = fixedStart
        val before = readRecordRows()
        ReadBook.saveRead()
        drainReadBookExecutor()
        val after = readRecordRows()
        val persistedEmpty = requireNotNull(
            after.firstOrNull {
                it.bookName == bookName && it.deviceId.isEmpty()
            }
        )
        return JSONObject()
            .put(
                "database_rows_unchanged",
                readRecordRowsEqual(before, after)
            )
            .put(
                "read_start_time_unchanged",
                ReadBook.readStartTime == fixedStart
            )
            .put("session_in_memory_read_time", session.readTime)
            .put(
                "persisted_empty_device_read_time",
                persistedEmpty.readTime
            )
            .put(
                "save_read_settled_session_time",
                session.readTime != currentSessionReadRecord().readTime ||
                    !readRecordRowsEqual(before, after)
            )
    }

    private fun readRecordDisabledProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        ReadBook.resetData(readRecordBook(bookName, "disabled"))
        val fixedStart = arguments.getLong("read_start_time")
        val previousEnabled = AppConfig.enableReadRecord
        return try {
            AppConfig.enableReadRecord = false
            ReadBook.readStartTime = fixedStart
            ReadBook.upReadTime()
            drainReadBookExecutor()
            JSONObject()
                .put("persisted_row_count", readRecordRows().size)
                .put(
                    "read_start_time_unchanged",
                    ReadBook.readStartTime == fixedStart
                )
                .put(
                    "session_read_time",
                    currentSessionReadRecord().readTime
                )
        } finally {
            AppConfig.enableReadRecord = previousEnabled
        }
    }

    private fun readRecordConflictProjection(
        arguments: JSONObject
    ): JSONObject {
        seedReadRecords(arguments)
        val bookName = arguments.getString("book_name")
        val rows = readRecordRows().filter { it.bookName == bookName }
        return JSONObject()
            .put("row_count", rows.size)
            .put("aggregate_read_time", appDb.readRecordDao.getReadTime(bookName))
            .put(
                "rows",
                JSONArray().apply {
                    rows.forEach { put(readRecordProjection(it)) }
                }
            )
    }

    private fun seedReadRecords(arguments: JSONObject) {
        val rows = arguments.getJSONArray("rows")
        for (index in 0 until rows.length()) {
            appDb.readRecordDao.insert(
                readRecord(rows.getJSONObject(index))
            )
        }
    }

    private fun clearReadRecords() {
        appDb.readRecordDao.clear()
    }

    private fun drainReadBookExecutor() {
        ReadBook.executor.submit {}.get(5, TimeUnit.SECONDS)
    }

    private fun readRecordRows(): List<ReadRecord> =
        appDb.readRecordDao.all.sortedWith(
            compareBy<ReadRecord> { it.bookName }
                .thenBy { it.deviceId }
        )

    private fun readRecordRowsEqual(
        left: List<ReadRecord>,
        right: List<ReadRecord>
    ): Boolean =
        left.map(::readRecordProjection).map(JSONObject::toString) ==
            right.map(::readRecordProjection).map(JSONObject::toString)

    private fun currentSessionReadRecord(): ReadRecord {
        val field = ReadBook::class.java.getDeclaredField("readRecord")
        field.isAccessible = true
        return field.get(ReadBook) as ReadRecord
    }

    private fun readRecordBook(
        bookName: String,
        suffix: String
    ): Book = Book(
        bookUrl = "/android-runtime/read-record/$suffix.txt",
        originName = "RuntimeLab",
        name = bookName,
        author = "RuntimeLab"
    )

    private fun readRecord(value: JSONObject): ReadRecord = ReadRecord(
        deviceId = value.getString("deviceId"),
        bookName = value.getString("bookName"),
        readTime = value.getLong("readTime"),
        lastRead = value.getLong("lastRead")
    )

    private fun readRecordProjection(value: ReadRecord): JSONObject =
        JSONObject()
            .put("device_id", value.deviceId)
            .put("book_name", value.bookName)
            .put("read_time", value.readTime)
            .put("last_read", value.lastRead)

    private suspend fun runReadDurationSessionCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "read_duration_single",
            "read_duration_repeated",
            "read_duration_disabled_gap",
            "read_duration_config_race",
            "read_duration_reset_race",
            "read_duration_durability_window"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported read-duration session operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                operation,
                stimulus
            ) {
                readDurationSessionProjection(operation, arguments)
            }
        }
    }

    private fun readDurationSessionProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearReadRecords()
        val previousEnabled = AppConfig.enableReadRecord
        return try {
            when (operation) {
                "read_duration_single" ->
                    readDurationSingleProjection(arguments)
                "read_duration_repeated" ->
                    readDurationRepeatedProjection(arguments)
                "read_duration_disabled_gap" ->
                    readDurationDisabledGapProjection(arguments)
                "read_duration_config_race" ->
                    readDurationConfigRaceProjection(arguments)
                "read_duration_reset_race" ->
                    readDurationResetRaceProjection(arguments)
                "read_duration_durability_window" ->
                    readDurationDurabilityWindowProjection(arguments)
                else -> error("Unsupported read-duration session operation")
            }
        } finally {
            drainReadBookExecutor()
            AppConfig.enableReadRecord = previousEnabled
            ReadBook.book = null
            clearReadRecords()
        }
    }

    private fun readDurationSingleProjection(
        arguments: JSONObject
    ): JSONObject {
        val bookName = arguments.getString("book_name")
        val baseline = arguments.getLong("baseline_read_time")
        prepareReadDurationSession(bookName, baseline)
        val fixedStart = elapsedSessionStart(arguments)
        val session = currentSessionReadRecord()
        AppConfig.enableReadRecord = true
        ReadBook.readStartTime = fixedStart
        ReadBook.upReadTime()
        drainReadBookExecutor()
        val persisted = requireNotNull(readRecordFor("", bookName))
        return JSONObject()
            .put("one_persisted_record", readRecordRows().size == 1)
            .put("duration_increased", session.readTime > baseline)
            .put(
                "requested_elapsed_was_included",
                session.readTime - baseline >=
                    arguments.getLong("elapsed_before_call_ms")
            )
            .put(
                "session_start_advanced",
                ReadBook.readStartTime > fixedStart
            )
            .put(
                "last_read_not_before_session_start",
                session.lastRead >= ReadBook.readStartTime
            )
            .put(
                "persisted_matches_session",
                persisted.readTime == session.readTime &&
                    persisted.lastRead == session.lastRead
            )
    }

    private fun readDurationRepeatedProjection(
        arguments: JSONObject
    ): JSONObject {
        val bookName = arguments.getString("book_name")
        val baseline = arguments.getLong("baseline_read_time")
        prepareReadDurationSession(bookName, baseline)
        AppConfig.enableReadRecord = true
        ReadBook.readStartTime = elapsedSessionStart(arguments)
        ReadBook.upReadTime()
        drainReadBookExecutor()
        val firstReadTime = currentSessionReadRecord().readTime
        val firstStart = ReadBook.readStartTime
        val firstLastRead = currentSessionReadRecord().lastRead
        Thread.sleep(arguments.getLong("between_calls_ms"))
        ReadBook.upReadTime()
        drainReadBookExecutor()
        val session = currentSessionReadRecord()
        val persisted = requireNotNull(readRecordFor("", bookName))
        return JSONObject()
            .put("first_settlement_increased_duration", firstReadTime > baseline)
            .put(
                "second_settlement_increased_duration",
                session.readTime > firstReadTime
            )
            .put(
                "session_start_advanced_twice",
                ReadBook.readStartTime > firstStart
            )
            .put(
                "last_read_monotonic",
                session.lastRead >= firstLastRead
            )
            .put("replacement_kept_one_record", readRecordRows().size == 1)
            .put(
                "persisted_matches_latest_session",
                persisted.readTime == session.readTime &&
                    persisted.lastRead == session.lastRead
            )
    }

    private fun readDurationDisabledGapProjection(
        arguments: JSONObject
    ): JSONObject {
        val bookName = arguments.getString("book_name")
        val baseline = arguments.getLong("baseline_read_time")
        prepareReadDurationSession(bookName, baseline)
        val fixedStart = elapsedSessionStart(arguments)
        ReadBook.readStartTime = fixedStart
        AppConfig.enableReadRecord = false
        ReadBook.upReadTime()
        drainReadBookExecutor()
        val afterDisabled = requireNotNull(readRecordFor("", bookName))
        val disabledPreservedStart = ReadBook.readStartTime == fixedStart
        val disabledPreservedDuration = afterDisabled.readTime == baseline
        AppConfig.enableReadRecord = true
        ReadBook.upReadTime()
        drainReadBookExecutor()
        val afterEnabled = requireNotNull(readRecordFor("", bookName))
        return JSONObject()
            .put("disabled_preserved_session_start", disabledPreservedStart)
            .put("disabled_preserved_duration", disabledPreservedDuration)
            .put(
                "reenabled_settlement_included_disabled_gap",
                afterEnabled.readTime - baseline >=
                    arguments.getLong("elapsed_before_call_ms")
            )
            .put(
                "reenabled_settlement_advanced_start",
                ReadBook.readStartTime > fixedStart
            )
            .put("replacement_kept_one_record", readRecordRows().size == 1)
    }

    private fun readDurationConfigRaceProjection(
        arguments: JSONObject
    ): JSONObject {
        val bookName = arguments.getString("book_name")
        val baseline = arguments.getLong("baseline_read_time")
        prepareReadDurationSession(bookName, baseline)
        val fixedStart = elapsedSessionStart(arguments)
        ReadBook.readStartTime = fixedStart
        val enabledAtCall = arguments.getBoolean("enabled_at_call")
        val enabledAtExecution =
            arguments.getBoolean("enabled_at_execution")
        val release = startReadBookExecutorBarrier()
        try {
            AppConfig.enableReadRecord = enabledAtCall
            ReadBook.upReadTime()
            AppConfig.enableReadRecord = enabledAtExecution
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val persisted = requireNotNull(readRecordFor("", bookName))
        val settled = persisted.readTime > baseline
        return JSONObject()
            .put("enabled_at_call", enabledAtCall)
            .put("enabled_at_execution", enabledAtExecution)
            .put("settlement_executed", settled)
            .put(
                "execution_time_config_decided",
                settled == enabledAtExecution
            )
            .put(
                "session_start_advanced",
                ReadBook.readStartTime > fixedStart
            )
            .put("replacement_kept_one_record", readRecordRows().size == 1)
    }

    private fun readDurationResetRaceProjection(
        arguments: JSONObject
    ): JSONObject {
        val fromBook = arguments.getString("from_book_name")
        val toBook = arguments.getString("to_book_name")
        AppConfig.enableReadRecord = true
        ReadBook.resetData(readRecordBook(fromBook, "queued-from"))
        val fixedStart = elapsedSessionStart(arguments)
        ReadBook.readStartTime = fixedStart
        val release = startReadBookExecutorBarrier()
        try {
            ReadBook.upReadTime()
            ReadBook.resetData(readRecordBook(toBook, "queued-to"))
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val fromRecord = readRecordFor("", fromBook)
        val toRecord = readRecordFor("", toBook)
        return JSONObject()
            .put("old_book_record_absent", fromRecord == null)
            .put("new_book_record_present", toRecord != null)
            .put(
                "elapsed_duration_was_written_to_new_book",
                toRecord != null &&
                    toRecord.readTime >=
                    arguments.getLong("elapsed_before_call_ms")
            )
            .put(
                "session_record_now_names_new_book",
                currentSessionReadRecord().bookName == toBook
            )
            .put(
                "queued_call_captured_original_book",
                fromRecord != null && toRecord == null
            )
    }

    private fun readDurationDurabilityWindowProjection(
        arguments: JSONObject
    ): JSONObject {
        val bookName = arguments.getString("book_name")
        val baseline = arguments.getLong("baseline_read_time")
        prepareReadDurationSession(bookName, baseline)
        AppConfig.enableReadRecord = true
        ReadBook.readStartTime = elapsedSessionStart(arguments)
        val release = startReadBookExecutorBarrier()
        val beforeExecution: ReadRecord
        try {
            ReadBook.upReadTime()
            beforeExecution = requireNotNull(readRecordFor("", bookName))
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val afterExecution = requireNotNull(readRecordFor("", bookName))
        return JSONObject()
            .put(
                "persisted_duration_unchanged_while_queued",
                beforeExecution.readTime == baseline
            )
            .put(
                "persisted_duration_increased_after_execution",
                afterExecution.readTime > baseline
            )
            .put(
                "queued_write_has_durability_window",
                beforeExecution.readTime == baseline &&
                    afterExecution.readTime > baseline
            )
            .put("replacement_kept_one_record", readRecordRows().size == 1)
    }

    private fun prepareReadDurationSession(
        bookName: String,
        baselineReadTime: Long
    ) {
        appDb.readRecordDao.insert(
            ReadRecord(
                deviceId = "",
                bookName = bookName,
                readTime = baselineReadTime,
                lastRead = 1L
            )
        )
        ReadBook.resetData(readRecordBook(bookName, "duration"))
    }

    private fun elapsedSessionStart(arguments: JSONObject): Long =
        System.currentTimeMillis() -
            arguments.getLong("elapsed_before_call_ms")

    private fun readRecordFor(
        deviceId: String,
        bookName: String
    ): ReadRecord? = readRecordRows().firstOrNull {
        it.deviceId == deviceId && it.bookName == bookName
    }

    private fun startReadBookExecutorBarrier(): CountDownLatch {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        ReadBook.executor.execute {
            started.countDown()
            check(release.await(5, TimeUnit.SECONDS)) {
                "ReadBook executor barrier timed out"
            }
        }
        check(started.await(5, TimeUnit.SECONDS)) {
            "ReadBook executor barrier did not start"
        }
        return release
    }

    private suspend fun runReaderLayoutIncrementalStreamCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "current_layout_stream",
            "adjacent_layout_stream"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported reader layout stream operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                readerLayoutIncrementalStreamProjection(
                    value.getString("id"),
                    operation,
                    arguments
                )
            }
        }
    }

    private suspend fun readerLayoutIncrementalStreamProjection(
        caseId: String,
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearLayoutStreamRuntimeState()
        val previousConfig = ReadBookConfig.durConfig
        val previousShareLayout = ReadBookConfig.shareLayout
        val previousUseZhLayout = ReadBookConfig.useZhLayout
        val previousReview = AppConfig.enableReview
        val previousConverter = AppConfig.chineseConverterType
        val previousReadRecord = AppConfig.enableReadRecord
        val previousTypeface = AppConfig.systemTypefaces
        val preferences =
            InstrumentationRegistry.getInstrumentation()
                .targetContext.defaultSharedPreferences
        val doublePageKey = PreferKey.doublePageHorizontal
        val hadDoublePagePreference = preferences.contains(doublePageKey)
        val previousDoublePage = preferences.getString(
            doublePageKey,
            null
        )
        return try {
            ReadBookConfig.shareLayout = false
            ReadBookConfig.useZhLayout = false
            ReadBookConfig.durConfig = previousConfig.copy(
                textFont = "",
                textBold = 0,
                textSize = 18,
                letterSpacing = 0f,
                lineSpacingExtra = 10,
                paragraphSpacing = 0,
                titleMode = 2,
                titleSize = 0,
                titleTopSpacing = 0,
                titleBottomSpacing = 0,
                paragraphIndent = "",
                paddingBottom = 8,
                paddingLeft = 8,
                paddingRight = 8,
                paddingTop = 8
            ).apply {
                initColorInt()
            }
            AppConfig.enableReview = false
            AppConfig.chineseConverterType = 0
            AppConfig.enableReadRecord = false
            AppConfig.systemTypefaces = 0
            preferences.edit()
                .putString(doublePageKey, "0")
                .commit()
            ChapterProvider.upStyle()
            ChapterProvider.upViewSize(240, 180)

            val offset = arguments.getInt("chapter_offset")
            require(
                (operation == "current_layout_stream" && offset == 0) ||
                    (operation == "adjacent_layout_stream" &&
                        offset in setOf(-1, 1))
            )
            val failureMode = arguments.getString("failure_mode")
            require(
                failureMode in setOf(
                    "none",
                    "cancel_after_first_page",
                    "throw_after_first_page"
                )
            )
            val callback = LayoutStreamCallback(failureMode)
            val book = Book(
                bookUrl = "/android-runtime/reader-layout-stream/$caseId.txt",
                originName = "RuntimeLab",
                name = "RuntimeLab 增量排版 $caseId",
                author = "RuntimeLab"
            ).apply {
                setUseReplaceRule(false)
                setReSegment(false)
                setPageAnim(arguments.getInt("page_anim"))
            }
            val currentIndex = 1
            val chapter = BookChapter(
                url = "/android-runtime/reader-layout-stream/$caseId/" +
                    (currentIndex + offset),
                title = "第${currentIndex + offset + 1}章",
                bookUrl = book.bookUrl,
                index = currentIndex + offset
            )
            ReadBook.book = book
            ReadBook.chapterSize = 3
            ReadBook.durChapterIndex = currentIndex
            ReadBook.durChapterPos =
                arguments.getInt("dur_chapter_pos")
            ReadBook.callBack = callback

            ReadBook.contentLoadFinish(
                book = book,
                chapter = chapter,
                content = layoutStreamContent(arguments),
                upContent = arguments.getBoolean("up_content"),
                resetPageOffset =
                    arguments.getBoolean("reset_page_offset"),
                success = callback::markSuccess
            )

            when (failureMode) {
                "none" -> withTimeout(5_000) {
                    callback.successSignal.await()
                }
                "cancel_after_first_page" -> {
                    withTimeout(5_000) {
                        callback.failureSignal.await()
                    }
                    awaitStableLayoutPages(offset)
                }
                "throw_after_first_page" -> {
                    withTimeout(5_000) {
                        callback.failureSignal.await()
                        while (
                            layoutStreamChapter(offset)
                                ?.isCompleted != true
                        ) {
                            delay(10)
                        }
                    }
                    awaitStableLayoutPages(offset)
                }
            }

            val textChapter = requireNotNull(
                layoutStreamChapter(offset)
            )
            val isFailure = failureMode != "none"
            val schedulerDependentStream =
                caseId == "current-scroll-mode-refreshes-near-persisted-page"
            val cancellationStream =
                failureMode == "cancel_after_first_page"
            JSONObject()
                .put("chapter_offset", offset)
                .put("page_anim", arguments.getInt("page_anim"))
                .put(
                    "requested_character_anchor",
                    arguments.getInt("dur_chapter_pos")
                )
                .put("failure_mode", failureMode)
                .put("layout_completed", textChapter.isCompleted)
                .put("has_materialized_pages", textChapter.pages.isNotEmpty())
                .put(
                    "materialized_page_count",
                    if (isFailure) {
                        JSONObject.NULL
                    } else {
                        textChapter.pageSize
                    }
                )
                .put(
                    "additional_pages_after_consumer_stop",
                    if (cancellationStream) {
                        JSONObject.NULL
                    } else {
                        textChapter.pageSize >
                            callback.layoutPageCallbackCount.get()
                    }
                )
                .put(
                    "layout_page_callback_count",
                    if (cancellationStream) {
                        JSONObject.NULL
                    } else {
                        callback.layoutPageCallbackCount.get()
                    }
                )
                .put(
                    "layout_page_callbacks_before_cancel",
                    if (cancellationStream) 1 else JSONObject.NULL
                )
                .put(
                    "content_refresh_count",
                    if (schedulerDependentStream) {
                        JSONObject.NULL
                    } else {
                        callback.contentRefreshCount.get()
                    }
                )
                .put(
                    "content_refresh_count_is_scheduler_dependent",
                    schedulerDependentStream
                )
                .put(
                    "terminal_content_callback",
                    callback.contentFinished.get()
                )
                .put(
                    "success_callback",
                    callback.successCalled.get()
                )
                .put(
                    "events",
                    projectLayoutStreamEvents(
                        caseId,
                        callback.snapshot()
                    )
                )
        } finally {
            clearLayoutStreamRuntimeState()
            ReadBookConfig.durConfig = previousConfig
            ReadBookConfig.shareLayout = previousShareLayout
            ReadBookConfig.useZhLayout = previousUseZhLayout
            AppConfig.enableReview = previousReview
            AppConfig.chineseConverterType = previousConverter
            AppConfig.enableReadRecord = previousReadRecord
            AppConfig.systemTypefaces = previousTypeface
            val editor = preferences.edit()
            if (hadDoublePagePreference) {
                editor.putString(doublePageKey, previousDoublePage)
            } else {
                editor.remove(doublePageKey)
            }
            editor.commit()
            ChapterProvider.upStyle()
        }
    }

    private fun layoutStreamContent(arguments: JSONObject): String {
        val paragraphCount = arguments.getInt("paragraph_count")
        val characterCount =
            arguments.getInt("characters_per_paragraph")
        require(paragraphCount > 0 && characterCount > 0)
        val alphabet = "甲乙丙丁戊己庚辛壬癸"
        return (0 until paragraphCount).joinToString("\n") { paragraph ->
            buildString {
                append("段")
                append(paragraph)
                append("：")
                repeat(characterCount) { index ->
                    append(
                        alphabet[
                            (paragraph + index) % alphabet.length
                        ]
                    )
                }
            }
        }
    }

    private fun layoutStreamChapter(offset: Int): TextChapter? =
        when (offset) {
            -1 -> ReadBook.prevTextChapter
            0 -> ReadBook.curTextChapter
            1 -> ReadBook.nextTextChapter
            else -> null
        }

    private suspend fun awaitStableLayoutPages(offset: Int) {
        withTimeout(5_000) {
            var previous = -1
            var stableCount = 0
            while (stableCount < 5) {
                delay(20)
                val current =
                    layoutStreamChapter(offset)?.pageSize ?: -1
                if (current == previous) {
                    stableCount++
                } else {
                    previous = current
                    stableCount = 0
                }
            }
        }
    }

    private fun projectLayoutStreamEvents(
        caseId: String,
        events: JSONArray
    ): JSONArray {
        val values = (0 until events.length()).map {
            events.getJSONObject(it)
        }
        return when (caseId) {
            "current-scroll-mode-refreshes-near-persisted-page" ->
                projectScrollLayoutStreamEvents(values)
            "current-layout-cancelled-after-first-page" -> {
                val cancelIndex = values.indexOfFirst {
                    it.getString("type") == "cancel_requested"
                }
                require(cancelIndex >= 0)
                layoutStreamEventProjection(
                    values.subList(0, cancelIndex + 1)
                )
            }
            else -> layoutStreamEventProjection(values)
        }
    }

    private fun projectScrollLayoutStreamEvents(
        events: List<JSONObject>
    ): JSONArray {
        val firstPageIndex = events.indexOfFirst {
            it.getString("type") == "layout_page"
        }
        val anchorPageIndex = events.indexOfFirst {
            it.getString("type") == "layout_page" &&
                it.optBoolean("contains_character_anchor")
        }
        val lastPageIndex = events.indexOfLast {
            it.getString("type") == "layout_page"
        }
        require(
            firstPageIndex >= 0 &&
                anchorPageIndex > firstPageIndex &&
                lastPageIndex > anchorPageIndex
        )
        val anchorRefreshIndex = events.indexOfFirst {
            it.getString("type") == "up_content" &&
                it.optBoolean("reset_page_offset") &&
                events.indexOf(it) < anchorPageIndex
        }
        val scrollAtAnchorIndex = events.indexOfLast {
            it.getString("type") == "up_content" &&
                !it.optBoolean("reset_page_offset") &&
                events.indexOf(it) < anchorPageIndex
        }
        val scrollAfterAnchorIndex = events.indexOfFirst {
            it.getString("type") == "up_content" &&
                !it.optBoolean("reset_page_offset") &&
                events.indexOf(it) > anchorPageIndex &&
                events.indexOf(it) < lastPageIndex
        }
        val terminalRefreshIndex = events.indexOfFirst {
            it.getString("type") == "up_content" &&
                events.indexOf(it) > lastPageIndex
        }
        require(
            anchorRefreshIndex >= 0 &&
                scrollAtAnchorIndex > anchorRefreshIndex &&
                scrollAfterAnchorIndex > anchorPageIndex &&
                terminalRefreshIndex > lastPageIndex
        )
        val selected = listOf(
            events.first { it.getString("type") == "up_menu" },
            layoutStreamMilestone(
                "first_layout_page",
                events[firstPageIndex],
                "page_index",
                "page_start"
            ),
            layoutStreamMilestone(
                "anchor_refresh",
                events[anchorRefreshIndex],
                "relative_position",
                "reset_page_offset"
            ),
            layoutStreamMilestone(
                "scroll_refresh_before_anchor_callback",
                events[scrollAtAnchorIndex],
                "relative_position",
                "reset_page_offset"
            ),
            layoutStreamMilestone(
                "anchor_layout_page",
                events[anchorPageIndex],
                "page_index",
                "page_start",
                "contains_character_anchor"
            ),
            layoutStreamMilestone(
                "scroll_refresh_after_anchor_callback",
                events[scrollAfterAnchorIndex],
                "relative_position",
                "reset_page_offset"
            ),
            layoutStreamMilestone(
                "last_layout_page",
                events[lastPageIndex],
                "page_index",
                "page_start"
            ),
            layoutStreamMilestone(
                "terminal_refresh",
                events[terminalRefreshIndex],
                "relative_position",
                "reset_page_offset"
            ),
            events.first { it.getString("type") == "page_changed" },
            events.first {
                it.getString("type") == "content_load_finish"
            },
            events.first { it.getString("type") == "success" }
        )
        return layoutStreamEventProjection(selected)
    }

    private fun layoutStreamMilestone(
        type: String,
        source: JSONObject,
        vararg keys: String
    ): JSONObject = JSONObject()
        .put("type", type)
        .apply {
            keys.forEach { key ->
                put(key, source.get(key))
            }
        }

    private fun layoutStreamEventProjection(
        events: List<JSONObject>
    ): JSONArray = JSONArray().apply {
        events.forEachIndexed { index, event ->
            put(
                JSONObject(event.toString())
                    .put("sequence", index)
            )
        }
    }

    private suspend fun clearLayoutStreamRuntimeState() {
        ReadBook.coroutineContext.cancelChildren()
        ReadBook.clearTextChapter()
        delay(20)
        ReadBook.callBack = null
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.contentProcessor = null
        ReadBook.chapterSize = 0
        ReadBook.durChapterIndex = 0
        ReadBook.durChapterPos = 0
    }

    private class LayoutStreamCallback(
        private val failureMode: String
    ) : ReadBook.CallBack {
        private val sequence = AtomicInteger()
        private val events = arrayListOf<JSONObject>()
        val layoutPageCallbackCount = AtomicInteger()
        val contentRefreshCount = AtomicInteger()
        val contentFinished = AtomicBoolean()
        val successCalled = AtomicBoolean()
        val failureSignal = CompletableDeferred<Unit>()
        val successSignal = CompletableDeferred<Unit>()

        private fun record(
            type: String,
            block: JSONObject.() -> Unit = {}
        ) {
            val event = JSONObject()
                .put("sequence", sequence.getAndIncrement())
                .put("type", type)
                .apply(block)
            synchronized(events) {
                events.add(event)
            }
        }

        fun markSuccess() {
            successCalled.set(true)
            record("success")
            successSignal.complete(Unit)
        }

        fun snapshot(): JSONArray =
            JSONArray().apply {
                synchronized(events) {
                    events.forEach {
                        put(JSONObject(it.toString()))
                    }
                }
            }

        override fun upMenuView() {
            record("up_menu")
        }

        override fun loadChapterList(book: Book) {
            record("load_chapter_list")
        }

        override fun upContent(
            relativePosition: Int,
            resetPageOffset: Boolean,
            success: (() -> Unit)?
        ) {
            contentRefreshCount.incrementAndGet()
            record("up_content") {
                put("relative_position", relativePosition)
                put("reset_page_offset", resetPageOffset)
                put("dur_page_index", ReadBook.durPageIndex)
                put("layout_available", ReadBook.isLayoutAvailable)
            }
            success?.invoke()
        }

        override fun pageChanged() {
            record("page_changed")
        }

        override fun contentLoadFinish() {
            contentFinished.set(true)
            record("content_load_finish")
        }

        override fun upPageAnim(upRecorder: Boolean) {
            record("up_page_anim") {
                put("up_recorder", upRecorder)
            }
        }

        override fun notifyBookChanged() {
            record("notify_book_changed")
        }

        override fun onLayoutPageCompleted(
            index: Int,
            page: TextPage
        ) {
            layoutPageCallbackCount.incrementAndGet()
            val firstLine = page.lines.firstOrNull()
            record("layout_page") {
                put("page_index", index)
                put(
                    "page_start",
                    firstLine?.chapterPosition ?: JSONObject.NULL
                )
                put(
                    "contains_character_anchor",
                    firstLine != null &&
                        page.containPos(ReadBook.durChapterPos)
                )
            }
            if (index == 0) {
                when (failureMode) {
                    "cancel_after_first_page" -> {
                        record("cancel_requested")
                        failureSignal.complete(Unit)
                        ReadBook.curTextChapter?.cancelLayout()
                    }
                    "throw_after_first_page" -> {
                        record("callback_exception")
                        failureSignal.complete(Unit)
                        throw IllegalStateException(
                            "oracle layout callback failure"
                        )
                    }
                }
            }
        }

        override fun onLayoutCompleted() {
            record("listener_layout_completed")
        }

        override fun onLayoutException(e: Throwable) {
            record("listener_layout_exception") {
                put("exception_type", e.javaClass.name)
            }
        }
    }

    private suspend fun runReaderLayoutPageProjectionCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "layout_projection",
            "layout_reflow_projection"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported reader layout projection operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "layout_projection" ->
                        layoutProjection(arguments)
                    "layout_reflow_projection" ->
                        layoutReflowProjection(arguments)
                    else -> error(
                        "Unsupported reader layout projection operation"
                    )
                }
            }
        }
    }

    private fun layoutProjection(arguments: JSONObject): JSONObject {
        val chapter = projectionTextChapter(
            arguments.getJSONObject("layout"),
            "single"
        )
        val charIndices = arguments.getJSONArray("char_indices")
        val pageIndices = arguments.getJSONArray("page_indices")
        return JSONObject()
            .put("layout_completed", chapter.isCompleted)
            .put("page_size", chapter.pageSize)
            .put("page_starts", pageStarts(chapter))
            .put(
                "char_mappings",
                JSONArray().apply {
                    for (index in 0 until charIndices.length()) {
                        val charIndex = charIndices.getInt(index)
                        val pageIndex =
                            chapter.getPageIndexByCharIndex(charIndex)
                        val page = chapter.getPageByReadPos(charIndex)
                        put(
                            JSONObject()
                                .put("char_index", charIndex)
                                .put("page_index", pageIndex)
                                .put(
                                    "selected_page_start",
                                    page?.lines?.firstOrNull()
                                        ?.chapterPosition
                                        ?: JSONObject.NULL
                                )
                                .put(
                                    "selected_page_contains_position",
                                    page?.containPos(charIndex)
                                        ?: JSONObject.NULL
                                )
                                .put(
                                    "previous_page_start",
                                    chapter.getPrevPageLength(charIndex)
                                )
                                .put(
                                    "next_page_start",
                                    chapter.getNextPageLength(charIndex)
                                )
                        )
                    }
                }
            )
            .put(
                "page_mappings",
                JSONArray().apply {
                    for (index in 0 until pageIndices.length()) {
                        val pageIndex = pageIndices.getInt(index)
                        put(readLengthProjection(chapter, pageIndex))
                    }
                }
            )
    }

    private fun layoutReflowProjection(
        arguments: JSONObject
    ): JSONObject {
        val before = projectionTextChapter(
            arguments.getJSONObject("before_layout"),
            "before"
        )
        val after = projectionTextChapter(
            arguments.getJSONObject("after_layout"),
            "after"
        )
        val charIndices = arguments.getJSONArray("char_indices")
        return JSONObject()
            .put("before_page_starts", pageStarts(before))
            .put("after_page_starts", pageStarts(after))
            .put(
                "mappings",
                JSONArray().apply {
                    for (index in 0 until charIndices.length()) {
                        val charIndex = charIndices.getInt(index)
                        val beforePageIndex =
                            before.getPageIndexByCharIndex(charIndex)
                        val afterPageIndex =
                            after.getPageIndexByCharIndex(charIndex)
                        put(
                            JSONObject()
                                .put("char_index", charIndex)
                                .put(
                                    "before_page_index",
                                    beforePageIndex
                                )
                                .put(
                                    "before_page_start",
                                    pageStart(before, beforePageIndex)
                                )
                                .put(
                                    "after_page_index",
                                    afterPageIndex
                                )
                                .put(
                                    "after_page_start",
                                    pageStart(after, afterPageIndex)
                                )
                                .put(
                                    "page_index_changed",
                                    beforePageIndex != afterPageIndex
                                )
                        )
                    }
                }
            )
    }

    private fun projectionTextChapter(
        layout: JSONObject,
        suffix: String
    ): TextChapter {
        val starts = layout.getJSONArray("page_starts")
        val texts = layout.getJSONArray("page_texts")
        require(starts.length() == texts.length())
        val chapter = TextChapter(
            chapter = BookChapter(
                url = "/android-runtime/reader-layout/$suffix",
                title = "投影章节",
                bookUrl = "/android-runtime/reader-layout/book.txt",
                index = 0
            ),
            position = 0,
            title = "投影章节",
            chaptersSize = 1,
            sameTitleRemoved = false,
            isVip = false,
            isPay = false,
            effectiveReplaceRules = null
        )
        val field = TextChapter::class.java.getDeclaredField("textPages")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pages = field.get(chapter) as ArrayList<TextPage>
        for (index in 0 until starts.length()) {
            val text = texts.getString(index)
            val page = TextPage(
                index = index,
                text = text,
                title = chapter.title,
                chapterSize = 1,
                chapterIndex = 0
            )
            page.addLine(
                TextLine(
                    text = text,
                    chapterPosition = starts.getInt(index)
                )
            )
            page.textChapter = chapter
            pages.add(page)
        }
        chapter.isCompleted = layout.getBoolean("layout_completed")
        return chapter
    }

    private fun pageStarts(chapter: TextChapter): JSONArray =
        JSONArray().apply {
            chapter.pages.forEach { page ->
                put(page.lines.first().chapterPosition)
            }
        }

    private fun pageStart(
        chapter: TextChapter,
        pageIndex: Int
    ): Any =
        chapter.getPage(pageIndex)?.lines?.firstOrNull()?.chapterPosition
            ?: JSONObject.NULL

    private fun readLengthProjection(
        chapter: TextChapter,
        pageIndex: Int
    ): JSONObject =
        try {
            JSONObject()
                .put("page_index", pageIndex)
                .put("status", "value")
                .put("read_length", chapter.getReadLength(pageIndex))
        } catch (error: IndexOutOfBoundsException) {
            JSONObject()
                .put("page_index", pageIndex)
                .put("status", "exception")
                .put("exception_type", error.javaClass.name)
        }

    private suspend fun runReaderProgressRuntimeCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "layout_set_page_index",
            "layout_char_to_page",
            "save_read_page_changed",
            "reset_progress",
            "audio_save_read"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported reader progress operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                readerProgressRuntimeProjection(operation, arguments)
            }
        }
    }

    private suspend fun runReaderProgressWebDavConflictCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation == "single_book_progress_sync") {
                "Unsupported WebDAV progress operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                readerProgressWebDavConflictProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun readerProgressWebDavConflictProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        clearProgressRuntimeState()
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val preferences = target.defaultSharedPreferences
        val authorizationField = AppWebDav::class.java
            .getDeclaredField("authorization")
            .apply { isAccessible = true }
        val book = Book(
            bookUrl = "/android-runtime/reader-progress/webdav-book.txt",
            originName = "RuntimeLab",
            name = "SyncBook",
            author = "SyncAuthor",
            totalChapterNum = 3,
            durChapterTitle = "Local Chapter",
            durChapterIndex = arguments.getInt("local_chapter_index"),
            durChapterPos = arguments.getInt("local_chapter_pos"),
            durChapterTime = 100L
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        preferences.edit()
            .putString(
                PreferKey.webDavUrl,
                "$deviceOrigin/dav/$caseId/"
            )
            .putBoolean(PreferKey.syncBookProgress, true)
            .commit()
        authorizationField.set(
            AppWebDav,
            Authorization("oracle-user", "oracle-password")
        )
        val prompted = CompletableDeferred<BookProgress>()
        return try {
            val viewModel = ReadBookViewModel(
                target.applicationContext as Application
            )
            viewModel.syncBookProgress(book) { progress ->
                prompted.complete(progress)
            }
            withTimeout(5_000) {
                while (
                    !prompted.isCompleted &&
                    ReadBook.durChapterIndex == book.durChapterIndex &&
                    ReadBook.durChapterPos == book.durChapterPos
                ) {
                    delay(10)
                }
            }
            val beforeConfirmationIndex = ReadBook.durChapterIndex
            val beforeConfirmationPos = ReadBook.durChapterPos
            val promptedProgress = if (prompted.isCompleted) {
                prompted.await()
            } else {
                null
            }
            if (
                arguments.getBoolean("confirm_rollback") &&
                promptedProgress != null
            ) {
                ReadBook.setProgress(promptedProgress)
            }
            JSONObject()
                .put("local_chapter_index", book.durChapterIndex)
                .put("local_char_position", book.durChapterPos)
                .put("confirmation_requested", promptedProgress != null)
                .put(
                    "before_confirmation_chapter_index",
                    beforeConfirmationIndex
                )
                .put(
                    "before_confirmation_char_position",
                    beforeConfirmationPos
                )
                .put(
                    "confirmation_accepted",
                    arguments.getBoolean("confirm_rollback")
                )
                .put("final_chapter_index", ReadBook.durChapterIndex)
                .put("final_char_position", ReadBook.durChapterPos)
        } finally {
            authorizationField.set(AppWebDav, null)
            preferences.edit()
                .remove(PreferKey.webDavUrl)
                .remove(PreferKey.syncBookProgress)
                .commit()
            clearProgressRuntimeState()
        }
    }

    private suspend fun readerProgressRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearProgressRuntimeState()
        val previousReadRecordEnabled = AppConfig.enableReadRecord
        AppConfig.enableReadRecord = false
        return try {
            when (operation) {
                "layout_set_page_index" ->
                    layoutSetPageIndexProjection(arguments)
                "layout_char_to_page" ->
                    layoutCharToPageProjection(arguments)
                "save_read_page_changed" ->
                    saveReadPageChangedProjection(arguments)
                "reset_progress" ->
                    resetProgressProjection(arguments)
                "audio_save_read" ->
                    audioSaveReadProjection(arguments)
                else -> error("Unsupported reader progress operation")
            }
        } finally {
            drainReadBookExecutor()
            AppConfig.enableReadRecord = previousReadRecordEnabled
            clearProgressRuntimeState()
        }
    }

    private fun layoutSetPageIndexProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = 0,
            chapterPos = 0,
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.curTextChapter = textChapter(arguments, book, 0)
        val requestedPageIndex = arguments.getInt("page_index")
        ReadBook.setPageIndex(requestedPageIndex)
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("requested_page_index", requestedPageIndex)
            .put("runtime_char_position", ReadBook.durChapterPos)
            .put("runtime_page_index", ReadBook.durPageIndex)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
    }

    private fun layoutCharToPageProjection(
        arguments: JSONObject
    ): JSONObject {
        val chapter = textChapter(
            arguments,
            progressBook(),
            chapterIndex = 0
        )
        val values = arguments.getJSONArray("char_indices")
        return JSONObject()
            .put("layout_completed", chapter.isCompleted)
            .put(
                "mappings",
                JSONArray().apply {
                    for (index in 0 until values.length()) {
                        val charIndex = values.getInt(index)
                        put(
                            JSONObject()
                                .put("char_index", charIndex)
                                .put(
                                    "page_index",
                                    chapter.getPageIndexByCharIndex(charIndex)
                                )
                        )
                    }
                }
            )
    }

    private fun saveReadPageChangedProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = 5,
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("runtime_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("runtime_chapter_pos")
        val pageChanged = arguments.getBoolean("page_changed")
        ReadBook.saveRead(pageChanged)
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("page_changed", pageChanged)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
            .put("last_check_count", persisted.lastCheckCount)
            .put("timestamp_was_refreshed", persisted.durChapterTime > 1L)
    }

    private fun resetProgressProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = arguments.getInt("stored_chapter_pos"),
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("chapter_size", ReadBook.chapterSize)
            .put("runtime_chapter_index", ReadBook.durChapterIndex)
            .put("runtime_char_position", ReadBook.durChapterPos)
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
    }

    private suspend fun audioSaveReadProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressBook(
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = arguments.getInt("stored_chapter_pos"),
            chapterTitle = "既有标题"
        )
        seedProgressBook(book)
        AudioPlay.book = book
        AudioPlay.saveRead()
        val persisted = withTimeout(5_000) {
            while (true) {
                val current = appDb.bookDao.getBook(book.bookUrl)
                if (
                    current?.durChapterTitle == "第二章" &&
                    current.lastCheckCount == 0
                ) {
                    return@withTimeout current
                }
                delay(10)
            }
            error("unreachable")
        }
        return JSONObject()
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put("persisted_chapter_title", persisted.durChapterTitle)
            .put("last_check_count", persisted.lastCheckCount)
            .put("timestamp_was_refreshed", persisted.durChapterTime > 1L)
    }

    private fun progressBook(
        chapterIndex: Int = 0,
        chapterPos: Int = 0,
        chapterTitle: String = "既有标题"
    ): Book = Book(
        bookUrl = "/android-runtime/reader-progress/book.txt",
        originName = "RuntimeLab",
        name = "RuntimeLab 阅读进度",
        author = "RuntimeLab",
        totalChapterNum = 3,
        durChapterTitle = chapterTitle,
        durChapterIndex = chapterIndex,
        durChapterPos = chapterPos,
        durChapterTime = 1L,
        lastCheckCount = 7
    )

    private fun seedProgressBook(book: Book) {
        appDb.bookDao.insert(book)
        val titles = listOf("第一章", "第二章", "第三章")
        appDb.bookChapterDao.insert(
            *titles.mapIndexed { index, title ->
                BookChapter(
                    url = "/android-runtime/reader-progress/$index",
                    title = title,
                    bookUrl = book.bookUrl,
                    index = index
                )
            }.toTypedArray()
        )
    }

    private fun textChapter(
        arguments: JSONObject,
        book: Book,
        chapterIndex: Int
    ): TextChapter {
        val starts = arguments.getJSONArray("page_starts")
        val texts = arguments.getJSONArray("page_texts")
        require(starts.length() == texts.length() && starts.length() > 0)
        val chapter = TextChapter(
            chapter = BookChapter(
                url = "/android-runtime/reader-progress/$chapterIndex",
                title = "第${chapterIndex + 1}章",
                bookUrl = book.bookUrl,
                index = chapterIndex
            ),
            position = chapterIndex,
            title = "第${chapterIndex + 1}章",
            chaptersSize = 3,
            sameTitleRemoved = false,
            isVip = false,
            isPay = false,
            effectiveReplaceRules = null
        )
        val field = TextChapter::class.java.getDeclaredField("textPages")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pages = field.get(chapter) as ArrayList<TextPage>
        for (index in 0 until starts.length()) {
            val text = texts.getString(index)
            val page = TextPage(
                index = index,
                text = text,
                title = chapter.title,
                chapterSize = 3,
                chapterIndex = chapterIndex
            )
            page.addLine(
                TextLine(
                    text = text,
                    chapterPosition = starts.getInt(index)
                )
            )
            page.textChapter = chapter
            pages.add(page)
        }
        chapter.isCompleted = arguments.getBoolean("layout_completed")
        return chapter
    }

    private fun clearProgressRuntimeState() {
        drainReadBookExecutor()
        AudioPlay.book = null
        AudioPlay.durChapter = null
        ReadBook.book = null
        ReadBook.prevTextChapter = null
        ReadBook.curTextChapter = null
        ReadBook.nextTextChapter = null
        clearReadRecords()
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/reader-progress/"
                )
            }
            .forEach {
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private suspend fun runBookDetailConditionalActionCases() {
        val values = input.getJSONArray("cases")
        val target =
            InstrumentationRegistry.getInstrumentation().targetContext
        val scenario = ActivityScenario.launch<BookInfoActivity>(
            Intent(target, BookInfoActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        var activity: BookInfoActivity? = null
        scenario.onActivity { activity = it }
        val previousDeleteAlert = LocalConfig.bookInfoDeleteAlert
        try {
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val operation = value.getString("operation")
                require(operation == "book_detail_action_projection") {
                    "Unsupported book detail operation: $operation"
                }
                val arguments = value.getJSONObject("arguments")
                val stimulus = JSONObject()
                    .put("operation", operation)
                    .put(
                        "arguments",
                        JSONObject(arguments.toString())
                    )
                runCase(
                    value.getString("id"),
                    operation,
                    stimulus
                ) {
                    bookDetailConditionalActionProjection(
                        requireNotNull(activity),
                        value.getString("id"),
                        arguments
                    )
                }
            }
        } finally {
            LocalConfig.bookInfoDeleteAlert = previousDeleteAlert
            scenario.close()
        }
    }

    private suspend fun runBookSourceMigrationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put(
                    "arguments",
                    value.optJSONObject("arguments") ?: JSONObject()
                )
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "book_source_migrate" ->
                        bookSourceMigrateProjection(value.getString("id"))
                    "book_source_migrate_empty_toc" ->
                        bookSourceEmptyTocProjection(value.getString("id"))
                    "book_detail_source_switch" ->
                        bookDetailSourceSwitchProjection(
                            value.getString("id"),
                            value.getJSONObject("arguments")
                                .getBoolean("in_bookshelf")
                        )
                    else -> error(
                        "Unsupported book source migration operation: $operation"
                    )
                }
            }
        }
        clearBookSourceMigrationState()
    }

    private fun bookSourceMigrateProjection(caseId: String): JSONObject {
        val oldBook = sourceMigrationOldBook(caseId)
        val newBook = sourceMigrationNewBook(caseId)
        val toc = sourceMigrationToc(newBook)

        oldBook.migrateTo(newBook, toc)

        return sourceMigrationProjection(oldBook, newBook)
            .put("target_chapter_count", toc.size)
    }

    private fun bookSourceEmptyTocProjection(caseId: String): JSONObject {
        val oldBook = sourceMigrationOldBook(caseId)
        val newBook = sourceMigrationNewBook(caseId)
        var error: String? = null
        try {
            oldBook.migrateTo(newBook, emptyList())
        } catch (throwable: Throwable) {
            error = throwable::class.java.simpleName
        }
        return JSONObject()
            .put("error", error ?: JSONObject.NULL)
            .put("target_progress_index", newBook.durChapterIndex)
            .put("target_progress_title", newBook.durChapterTitle)
            .put("target_progress_position", newBook.durChapterPos)
    }

    private suspend fun bookDetailSourceSwitchProjection(
        caseId: String,
        inBookshelf: Boolean
    ): JSONObject {
        clearBookSourceMigrationState()
        val oldBook = sourceMigrationOldBook(caseId)
        val newBook = sourceMigrationNewBook(caseId).apply {
            addType(BookType.updateError)
        }
        val oldToc = sourceMigrationToc(oldBook)
        val newToc = sourceMigrationToc(newBook)
        if (inBookshelf) {
            appDb.bookDao.insert(oldBook)
            appDb.bookChapterDao.insert(*oldToc.toTypedArray())
        }
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        val viewModel = BookInfoViewModel(application)
        onMainThread {
            viewModel.bookData.value = oldBook
            viewModel.chapterListData.value = oldToc
            viewModel.inBookshelf = inBookshelf
        }
        viewModel.changeTo(
            BookSource(
                bookSourceUrl = newBook.origin,
                bookSourceName = newBook.originName
            ),
            newBook,
            newToc
        )
        withTimeout(10_000) {
            while (
                viewModel.bookData.value?.bookUrl != newBook.bookUrl
                || (
                    inBookshelf
                        && appDb.bookDao.getBook(newBook.bookUrl) == null
                )
            ) {
                delay(25)
            }
        }
        if (inBookshelf) {
            withTimeout(10_000) {
                while (
                    appDb.bookChapterDao.getChapterCount(newBook.bookUrl)
                        != newToc.size
                ) {
                    delay(25)
                }
            }
        }
        val stored = appDb.bookDao.getBook(newBook.bookUrl)
        val projected = sourceMigrationProjection(
            oldBook,
            viewModel.bookData.value ?: newBook
        )
            .put("in_bookshelf", viewModel.inBookshelf)
            .put(
                "old_book_persisted",
                appDb.bookDao.getBook(oldBook.bookUrl) != null
            )
            .put("new_book_persisted", stored != null)
            .put(
                "old_chapter_count",
                appDb.bookChapterDao.getChapterCount(oldBook.bookUrl)
            )
            .put(
                "new_chapter_count",
                appDb.bookChapterDao.getChapterCount(newBook.bookUrl)
            )
            .put(
                "view_model_chapter_count",
                viewModel.chapterListData.value?.size ?: 0
            )
            .put(
                "update_error_removed",
                !((stored ?: newBook).isUpError)
            )
        clearBookSourceMigrationState()
        return projected
    }

    private fun sourceMigrationOldBook(caseId: String): Book =
        Book(
            bookUrl = "/android-runtime/source-migration/$caseId/old",
            tocUrl = "/android-runtime/source-migration/$caseId/old/toc",
            origin = "android-runtime://source-migration-old",
            originName = "Old Source",
            name = "Oracle Migration Book",
            author = "Oracle Author",
            durChapterIndex = 1,
            durChapterTitle = "Chapter 1",
            durChapterPos = 37,
            durChapterTime = 123456789L,
            totalChapterNum = 3,
            group = 5L,
            order = -7,
            customCoverUrl = "cover://custom",
            customIntro = "custom intro",
            customTag = "custom tag",
            canUpdate = false
        ).apply {
            setReverseToc(true)
        }

    private fun sourceMigrationNewBook(caseId: String): Book =
        Book(
            bookUrl = "/android-runtime/source-migration/$caseId/new",
            tocUrl = "/android-runtime/source-migration/$caseId/new/toc",
            origin = "android-runtime://source-migration-new",
            originName = "New Source",
            name = "Oracle Migration Book",
            author = "Oracle Author",
            totalChapterNum = 3
        )

    private fun sourceMigrationToc(book: Book): List<BookChapter> =
        (0 until 3).map { index ->
            BookChapter(
                url = "${book.bookUrl}/chapter/$index",
                title = "Chapter $index",
                bookUrl = book.bookUrl,
                index = index
            )
        }

    private fun sourceMigrationProjection(
        oldBook: Book,
        newBook: Book
    ): JSONObject = JSONObject()
        .put("source_identity_changed", oldBook.origin != newBook.origin)
        .put("target_book_url", newBook.bookUrl)
        .put("target_origin", newBook.origin)
        .put("progress_index", newBook.durChapterIndex)
        .put("progress_title", newBook.durChapterTitle)
        .put("progress_position", newBook.durChapterPos)
        .put("progress_time", newBook.durChapterTime)
        .put("group", newBook.group)
        .put("order", newBook.order)
        .put("custom_cover", newBook.customCoverUrl)
        .put("custom_intro", newBook.customIntro)
        .put("custom_tag", newBook.customTag)
        .put("can_update", newBook.canUpdate)
        .put("reverse_toc", newBook.getReverseToc())

    private fun clearBookSourceMigrationState() {
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/source-migration/"
                )
            }
            .forEach {
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private suspend fun runBookDetailStagingCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                bookDetailStagingProjection(
                    value.getString("id"),
                    operation,
                    arguments
                )
            }
        }
        clearBookDetailStagingState()
    }

    private suspend fun bookDetailStagingProjection(
        caseId: String,
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearBookDetailStagingState()
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        val viewModel = BookInfoViewModel(application)
        val bookUrl =
            "/android-runtime/book-detail-staging/$caseId/candidate"
        val name = "Oracle Detail $caseId"
        val book = Book(
            bookUrl = bookUrl,
            tocUrl = "$bookUrl/toc",
            origin = "android-runtime://detail-staging-source",
            originName = "Oracle Detail Source",
            name = name,
            author = "Oracle Author"
        )
        val chapters = (0 until arguments.getInt("chapter_count"))
            .map { index ->
                BookChapter(
                    url = "$bookUrl/chapter/$index",
                    title = "Chapter $index",
                    bookUrl = bookUrl,
                    index = index
                )
            }
        var previousMinimum: Int? = null
        if (arguments.optBoolean("seed_existing_progress", false)) {
            val existing = Book(
                bookUrl =
                    "/android-runtime/book-detail-staging/$caseId/existing",
                origin = "android-runtime://detail-staging-source",
                originName = "Oracle Detail Source",
                name = name,
                author = "Oracle Author",
                durChapterTitle = "Existing Progress",
                durChapterPos = 23,
                order = -8
            )
            appDb.bookDao.insert(existing)
            previousMinimum = appDb.bookDao.minOrder
        }
        onMainThread {
            viewModel.bookData.value = book
            viewModel.chapterListData.value = chapters
            viewModel.inBookshelf = false
        }
        var observedInBookshelf: Boolean? = null

        when (operation) {
            "detail_candidate_save" ->
                awaitBookInfoAction { done ->
                    viewModel.saveBook(book, done)
                }
            "detail_explicit_add" ->
                awaitBookInfoAction { done ->
                    viewModel.addToBookshelf(done)
                }
            "detail_toc_stage" -> {
                awaitBookInfoAction { done ->
                    viewModel.saveBook(book, done)
                }
                awaitBookInfoAction { done ->
                    viewModel.saveChapterList(done)
                }
            }
            "detail_group_selection" -> {
                observedInBookshelf = runBookDetailGroupSelection(
                    book,
                    chapters,
                    arguments.getLong("group_id")
                )
            }
            "reader_discard_staged" -> {
                awaitBookInfoAction { done ->
                    viewModel.saveBook(book, done)
                }
                awaitBookInfoAction { done ->
                    viewModel.saveChapterList(done)
                }
                ReadBook.book = appDb.bookDao.getBook(bookUrl)
                val readViewModel = ReadBookViewModel(application)
                awaitBookInfoAction { done ->
                    readViewModel.removeFromBookshelf(done)
                }
            }
            else -> error(
                "Unsupported book detail staging operation: $operation"
            )
        }

        val stored = appDb.bookDao.getBook(bookUrl)
        val chapterCount =
            appDb.bookChapterDao.getChapterCount(bookUrl)
        return JSONObject()
            .put("book_persisted", stored != null)
            .put("chapter_count", chapterCount)
            .put(
                "in_bookshelf",
                observedInBookshelf ?: viewModel.inBookshelf
            )
            .put(
                "group",
                stored?.group ?: book.group
            )
            .put(
                "copied_progress",
                stored?.let {
                    it.durChapterPos == 23 &&
                        it.durChapterTitle == "Existing Progress"
                } ?: false
            )
            .put(
                "order_before_previous_minimum",
                if (previousMinimum == null || stored == null) {
                    false
                } else {
                    stored.order == previousMinimum - 1
                }
            )
    }

    private suspend fun runBookDetailGroupSelection(
        book: Book,
        chapters: List<BookChapter>,
        groupId: Long
    ): Boolean {
        val target =
            InstrumentationRegistry.getInstrumentation().targetContext
        val scenario = ActivityScenario.launch<BookInfoActivity>(
            Intent(target, BookInfoActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        var observed = false
        try {
            scenario.onActivity { activity ->
                val activityViewModel = ViewModelProvider(activity)[
                    BookInfoViewModel::class.java
                ]
                activityViewModel.bookData.value = book
                activityViewModel.chapterListData.value = chapters
                activityViewModel.inBookshelf = false
                activity.upGroup(0, groupId)
            }
            if (groupId > 0) {
                withTimeout(10_000) {
                    while (appDb.bookDao.getBook(book.bookUrl) == null) {
                        delay(25)
                    }
                }
            } else {
                InstrumentationRegistry
                    .getInstrumentation()
                    .waitForIdleSync()
            }
            scenario.onActivity { activity ->
                observed = ViewModelProvider(activity)[
                    BookInfoViewModel::class.java
                ].inBookshelf
            }
        } finally {
            finishTargetActivities()
            if (scenario.state != Lifecycle.State.DESTROYED) {
                scenario.close()
            }
        }
        return observed
    }

    private suspend fun awaitBookInfoAction(
        action: ((() -> Unit) -> Unit)
    ) {
        val completed = CompletableDeferred<Unit>()
        onMainThread {
            action { completed.complete(Unit) }
        }
        withTimeout(10_000) {
            completed.await()
        }
    }

    private suspend fun runChapterTocUpdateCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "shelf_toc_queue" ->
                        shelfTocQueueProjection(value.getString("id"))
                    "shelf_toc_update" ->
                        shelfTocUpdateProjection(
                            value.getString("id"),
                            arguments
                        )
                    "reader_toc_update" ->
                        readerTocUpdateProjection(
                            value.getString("id"),
                            arguments
                        )
                    else -> error(
                        "Unsupported chapter TOC update operation: $operation"
                    )
                }
            }
        }
        clearChapterTocUpdateState()
    }

    private suspend fun runTocActivityResultCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "toc_result_contract" ->
                        tocActivityResultProjection(arguments)
                    else -> error(
                        "Unsupported TOC result operation: $operation"
                    )
                }
            }
        }
    }

    private fun tocActivityResultProjection(
        arguments: JSONObject
    ): JSONObject {
        val producer = arguments.getString("producer")
        val intent = when (producer) {
            "null_intent" -> null
            "empty_intent" -> Intent()
            "chapter" -> Intent().apply {
                val selected = arguments.getInt("selected_index")
                val current = arguments.getInt("current_index")
                putExtra("index", selected)
                putExtra("chapterChanged", selected != current)
            }
            "bookmark" -> Intent().apply {
                putExtra("index", arguments.getInt("selected_index"))
                putExtra("chapterPos", arguments.getInt("chapter_pos"))
            }
            "reverse" -> Intent().apply {
                putExtra("index", arguments.getInt("current_index"))
                putExtra("chapterPos", 0)
            }
            else -> error("Unsupported TOC result producer: $producer")
        }
        val resultCode =
            if (arguments.getString("completion_code") == "ok") {
                Activity.RESULT_OK
            } else {
                Activity.RESULT_CANCELED
            }
        val parsed = TocActivityResult().parseResult(resultCode, intent)
        return JSONObject()
            .put("producer", producer)
            .put("result_present", parsed != null)
            .put("chapter_index", parsed?.first ?: JSONObject.NULL)
            .put("chapter_pos", parsed?.second ?: JSONObject.NULL)
            .put("chapter_changed", parsed?.third ?: JSONObject.NULL)
            .put(
                "reader_open_arguments",
                parsed?.let {
                    JSONArray().put(it.first).put(it.second)
                } ?: JSONObject.NULL
            )
            .put(
                "detail_progress_write",
                parsed?.let {
                    JSONObject()
                        .put("dur_chapter_index", it.first)
                        .put("dur_chapter_pos", it.second)
                        .put("chapter_changed", it.third)
                } ?: JSONObject.NULL
            )
    }

    private suspend fun shelfTocQueueProjection(
        caseId: String
    ): JSONObject {
        clearChapterTocUpdateState()
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        val viewModel = MainViewModel(application)
        val guardJob = Job()
        mainViewModelField("upTocJob").set(viewModel, guardJob)
        val acceptedUrl = "/android-runtime/toc-update/$caseId/remote"
        val values = listOf(
            tocUpdateBook(
                "$acceptedUrl/local",
                local = true,
                canUpdate = true
            ),
            tocUpdateBook(
                "$acceptedUrl/disabled",
                local = false,
                canUpdate = false
            ),
            tocUpdateBook(
                acceptedUrl,
                local = false,
                canUpdate = true
            ),
            tocUpdateBook(
                acceptedUrl,
                local = false,
                canUpdate = true
            )
        )
        try {
            viewModel.upToc(values)
            withTimeout(5_000) {
                while (mainViewModelWaitQueue(viewModel).isEmpty()) {
                    delay(10)
                }
            }
            val queued = synchronized(viewModel) {
                mainViewModelWaitQueue(viewModel).toList()
            }
            return JSONObject()
                .put(
                    "queued_urls",
                    JSONArray().apply { queued.forEach(::put) }
                )
                .put("queued_count", queued.size)
                .put(
                    "local_filtered",
                    !queued.contains("$acceptedUrl/local")
                )
                .put(
                    "disabled_filtered",
                    !queued.contains("$acceptedUrl/disabled")
                )
                .put(
                    "duplicate_collapsed",
                    queued.count { it == acceptedUrl } == 1
                )
        } finally {
            guardJob.cancel()
            clearMainViewModel(viewModel)
        }
    }

    private suspend fun shelfTocUpdateProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        clearChapterTocUpdateState()
        val mode = arguments.getString("mode")
        val oldCount = arguments.getInt("old_chapter_count")
        val newCount = arguments.getInt("new_chapter_count")
        val server = OracleTocServer(newCount)
        server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        val source = tocUpdateSource(server.baseUrl, caseId)
        val book = tocUpdateBook(
            "/android-runtime/toc-update/$caseId/book",
            local = false,
            canUpdate = true
        ).apply {
            origin = source.bookSourceUrl
            originName = source.bookSourceName
            tocUrl = "${server.baseUrl}/toc"
            totalChapterNum = oldCount
            if (mode == "success") {
                addType(BookType.updateError)
            }
        }
        seedTocUpdateBook(book, oldCount)
        if (mode != "missing_source") {
            appDb.bookSourceDao.insert(source)
        }
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        val viewModel = MainViewModel(application)
        try {
            invokeMainViewModelUpdateToc(viewModel, book.bookUrl)
            val stored = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
            val storedCount =
                appDb.bookChapterDao.getChapterCount(book.bookUrl)
            return JSONObject()
                .put("request_count", server.requestPaths.size)
                .put("chapter_count_before", oldCount)
                .put("chapter_count_after", storedCount)
                .put(
                    "old_chapters_preserved",
                    storedCount == oldCount
                )
                .put(
                    "chapters_replaced",
                    mode == "success" && storedCount == newCount
                )
                .put("update_error", stored.isUpError)
                .put("last_check_count", stored.lastCheckCount)
                .put("total_chapter_num", stored.totalChapterNum)
        } finally {
            clearMainViewModel(viewModel)
            server.stop()
            appDb.bookSourceDao.delete(source.bookSourceUrl)
            clearChapterTocUpdateState()
        }
    }

    private suspend fun readerTocUpdateProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        clearChapterTocUpdateState()
        val mode = arguments.getString("mode")
        val oldCount = arguments.getInt("old_chapter_count")
        val newCount = arguments.getInt("new_chapter_count")
        val server = OracleTocServer(newCount)
        server.start(NanoHTTPD.SOCKET_READ_TIMEOUT, false)
        val source = tocUpdateSource(server.baseUrl, caseId)
        val book = tocUpdateBook(
            "/android-runtime/toc-update/$caseId/book",
            local = false,
            canUpdate = true
        ).apply {
            origin = source.bookSourceUrl
            originName = source.bookSourceName
            tocUrl = "${server.baseUrl}/toc"
            totalChapterNum = oldCount
            lastCheckTime =
                if (mode == "throttled") {
                    System.currentTimeMillis()
                } else {
                    0
                }
        }
        seedTocUpdateBook(book, oldCount)
        ReadBook.book = book
        ReadBook.bookSource = source
        ReadBook.chapterSize = oldCount
        ReadBook.nextTextChapter = null
        try {
            ReadBook.upToc()
            if (mode == "throttled") {
                delay(300)
            } else {
                withTimeout(10_000) {
                    while (server.requestPaths.isEmpty()) {
                        delay(10)
                    }
                    while (
                        book.lastCheckTime == 0L
                            || (newCount > oldCount
                                && ReadBook.chapterSize != newCount)
                    ) {
                        delay(10)
                    }
                }
                delay(100)
            }
            val storedCount =
                appDb.bookChapterDao.getChapterCount(book.bookUrl)
            return JSONObject()
                .put("request_count", server.requestPaths.size)
                .put("chapter_size_before", oldCount)
                .put("chapter_size_after", ReadBook.chapterSize)
                .put("stored_chapter_count", storedCount)
                .put(
                    "growth_accepted",
                    newCount > oldCount
                        && ReadBook.chapterSize == newCount
                        && storedCount == newCount
                )
                .put(
                    "non_growth_rejected",
                    newCount <= oldCount
                        && ReadBook.chapterSize == oldCount
                        && storedCount == oldCount
                )
        } finally {
            server.stop()
            clearChapterTocUpdateState()
        }
    }

    private fun tocUpdateBook(
        bookUrl: String,
        local: Boolean,
        canUpdate: Boolean
    ) = Book(
        bookUrl = bookUrl,
        origin =
            if (local) BookType.localTag
            else "android-runtime://toc-source",
        originName = "Oracle TOC Source",
        name = "Oracle TOC ${bookUrl.substringAfterLast('/')}",
        author = "Oracle Author",
        type = if (local) BookType.local else BookType.text,
        canUpdate = canUpdate,
        lastCheckTime = 0
    )

    private fun tocUpdateSource(
        baseUrl: String,
        caseId: String
    ) = BookSource(
        bookSourceUrl = "$baseUrl/source/$caseId",
        bookSourceName = "Oracle TOC Source",
        ruleToc = TocRule(
            chapterList = "@CSS:#chapter-list > li.chapter",
            chapterName = "@CSS:a@text",
            chapterUrl = "@CSS:a@href"
        )
    )

    private fun seedTocUpdateBook(book: Book, chapterCount: Int) {
        appDb.bookChapterDao.delByBook(book.bookUrl)
        appDb.bookDao.getBook(book.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookDao.insert(book)
        val chapters = (0 until chapterCount).map { index ->
            BookChapter(
                url = "old://chapter/$index",
                title = "Old Chapter $index",
                bookUrl = book.bookUrl,
                index = index
            )
        }
        appDb.bookChapterDao.insert(*chapters.toTypedArray())
    }

    private suspend fun invokeMainViewModelUpdateToc(
        viewModel: MainViewModel,
        bookUrl: String
    ) {
        val method = MainViewModel::class.java.declaredMethods
            .single {
                it.name.startsWith("updateToc") &&
                    it.parameterTypes.size == 2
            }
            .apply { isAccessible = true }
        suspendCoroutine<Unit> { continuation ->
            try {
                val result = method.invoke(
                    viewModel,
                    bookUrl,
                    continuation
                )
                if (result !== COROUTINE_SUSPENDED) {
                    continuation.resume(Unit)
                }
            } catch (error: InvocationTargetException) {
                continuation.resumeWithException(
                    error.targetException ?: error
                )
            } catch (error: Throwable) {
                continuation.resumeWithException(error)
            }
        }
    }

    private fun mainViewModelField(name: String) =
        MainViewModel::class.java.getDeclaredField(name).apply {
            isAccessible = true
        }

    @Suppress("UNCHECKED_CAST")
    private fun mainViewModelWaitQueue(
        viewModel: MainViewModel
    ): java.util.LinkedList<String> =
        mainViewModelField("waitUpTocBooks").get(viewModel)
            as java.util.LinkedList<String>

    private fun clearMainViewModel(viewModel: MainViewModel) {
        MainViewModel::class.java
            .getDeclaredMethod("onCleared")
            .apply { isAccessible = true }
            .invoke(viewModel)
    }

    private fun clearChapterTocUpdateState() {
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.chapterSize = 0
        ReadBook.nextTextChapter = null
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/toc-update/"
                )
            }
            .forEach {
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
        appDb.bookSourceDao.all
            .filter {
                it.bookSourceUrl.contains("/source/")
                    && it.bookSourceName == "Oracle TOC Source"
            }
            .forEach {
                appDb.bookSourceDao.delete(it.bookSourceUrl)
            }
    }

    private class OracleTocServer(
        private val chapterCount: Int
    ) : NanoHTTPD(0) {
        val requestPaths = CopyOnWriteArrayList<String>()

        val baseUrl: String
            get() = "http://127.0.0.1:$listeningPort"

        override fun serve(session: IHTTPSession): Response {
            requestPaths += session.uri
            val chapters = (0 until chapterCount).joinToString("\n") {
                """
                <li class="chapter">
                  <a href="/chapter/$it">Chapter $it</a>
                </li>
                """.trimIndent()
            }
            val body =
                "<html><body><ul id=\"chapter-list\">$chapters</ul></body></html>"
            return newFixedLengthResponse(
                Response.Status.OK,
                "text/html; charset=utf-8",
                body
            )
        }
    }

    private fun clearBookDetailStagingState() {
        ReadBook.book = null
        listOf(
            "candidate-save-copies-progress",
            "explicit-add-persists-chapters",
            "toc-stages-without-membership",
            "zero-group-remains-candidate",
            "positive-group-commits",
            "reader-discard-removes-staged-book"
        ).forEach { caseId ->
            appDb.bookChapterDao.delByBook(
                "/android-runtime/book-detail-staging/$caseId/candidate"
            )
        }
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/book-detail-staging/"
                )
            }
            .forEach {
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private suspend fun runSearchFlowCases() {
        val values = input.getJSONArray("cases")
        val target =
            InstrumentationRegistry.getInstrumentation().targetContext
        val previousScope = AppConfig.searchScope
        AppConfig.searchScope = ""
        val scenario = ActivityScenario.launch<SearchActivity>(
            Intent(target, SearchActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        var activity: SearchActivity? = null
        scenario.onActivity { activity = it }
        try {
            for (index in 0 until values.length()) {
                val value = values.getJSONObject(index)
                val operation = value.getString("operation")
                val arguments = value.getJSONObject("arguments")
                val stimulus = JSONObject()
                    .put("operation", operation)
                    .put(
                        "arguments",
                        JSONObject(arguments.toString())
                    )
                runCase(
                    value.getString("id"),
                    operation,
                    stimulus
                ) {
                    when (operation) {
                        "search_scope_projection" ->
                            searchScopeProjection(arguments)
                        "search_activity_scope_menu" ->
                            searchScopeMenuProjection(
                                requireNotNull(activity),
                                arguments
                            )
                        "search_activity_loading_projection" ->
                            searchLoadingProjection(
                                requireNotNull(activity)
                            )
                        "search_activity_detail_roundtrip" ->
                            searchDetailRoundtripProjection(
                                scenario,
                                requireNotNull(activity),
                                arguments
                            )
                        else -> error(
                            "Unsupported search UI operation: $operation"
                        )
                    }
                }
            }
        } finally {
            AppConfig.searchScope = previousScope
            finishTargetActivities()
            if (scenario.state != Lifecycle.State.DESTROYED) {
                scenario.close()
            }
        }
    }

    private suspend fun runSourceEditorDebugRouteCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "source_editor_action_matrix" ->
                        sourceEditorActionMatrix(arguments)
                    "source_debug_key_matrix" ->
                        sourceDebugKeyMatrix(arguments)
                    "source_editor_result_matrix" ->
                        sourceEditorResultMatrix(arguments)
                    else -> error(
                        "Unsupported source editor/debug operation: $operation"
                    )
                }
            }
        }
    }

    private suspend fun runSourceDebugRuntimeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val arguments = value.getJSONObject("arguments")
            val debugInput = arguments.getString("input")
            runCase(
                value.getString("id"),
                "debug_runtime",
                searchRequest(debugInput)
            ) {
                sourceDebugRuntimeProjection(debugInput)
            }
        }
    }

    private suspend fun runTOCPipelineCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val arguments = value.getJSONObject("arguments")
            val tocPath = arguments.getString("toc_path")
            val tocURL = "$deviceOrigin$tocPath"
            runCase(
                value.getString("id"),
                "toc_pipeline",
                request(tocURL)
            ) {
                val book = Book(
                    bookUrl = "$deviceOrigin/books/toc-runtime",
                    tocUrl = tocURL,
                    origin = source.bookSourceUrl,
                    originName = source.bookSourceName,
                    name = "目录流水线"
                )
                chapterProjection(
                    WebBook.getChapterListAwait(source, book).getOrThrow()
                )
            }
        }
    }

    private suspend fun sourceDebugRuntimeProjection(
        debugInput: String
    ): JSONObject {
        val messages = java.util.Collections.synchronizedList(
            mutableListOf<String>()
        )
        var terminalState: Int? = null
        Debug.callback = object : Debug.Callback {
            override fun printLog(state: Int, msg: String) {
                messages.add(msg.replace(Regex("^\\[[^]]+]\\s*"), ""))
                if (state == 1000 || state < 0) {
                    terminalState = state
                }
            }
        }
        val scope = CoroutineScope(coroutineContext + Job())
        try {
            Debug.startDebug(scope, source, debugInput)
            val completed = withTimeoutOrNull(5_000) {
                while (terminalState == null) {
                    delay(10)
                }
                terminalState
            }
            require(completed == 1000) {
                "Debug.startDebug did not complete successfully: $completed"
            }
            val stages = JSONArray()
            val markers = listOf(
                "︾开始解析搜索页" to "search",
                "︾开始解析详情页" to "book_info",
                "︾开始解析目录页" to "toc",
                "︾开始解析正文页" to "content"
            )
            markers.forEach { (marker, stage) ->
                if (messages.any { it.contains(marker) }) {
                    stages.put(stage)
                }
            }
            return JSONObject()
                .put("entry_route", "search")
                .put("terminal_state", completed)
                .put("stage_sequence", stages)
                .put(
                    "terminal_message",
                    messages.lastOrNull { it.contains("正文页解析完成") }
                        ?: JSONObject.NULL
                )
        } finally {
            Debug.cancelDebug(destroy = true)
            scope.coroutineContext.cancelChildren()
        }
    }

    private suspend fun sourceEditorActionMatrix(
        arguments: JSONObject
    ): JSONObject {
        val target = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
        val application = target.applicationContext as Application
        val actions = arguments.getJSONArray("actions")
        val projected = JSONArray()
        for (index in 0 until actions.length()) {
            val item = actions.getJSONObject(index)
            val id = item.getString("id")
            val action = item.getString("action")
            val sourceUrl =
                "android-runtime://source-editor/${id}"
            val original = BookSource(
                bookSourceUrl = sourceUrl,
                bookSourceName = "Oracle Source $id"
            )
            original.loginUrl = when (
                item.getString("login_url_state")
            ) {
                "nonblank" -> "https://login.example.test/$id"
                "whitespace" -> " \n "
                else -> ""
            }
            appDb.bookSourceDao.insert(original)
            val edited = original.copy()
            if (item.getBoolean("changed")) {
                edited.bookSourceComment = "changed"
            }
            if (item.getString("name_state") == "blank") {
                edited.bookSourceName = ""
            }
            val dirty = !edited.equal(original)
            val loginVisible = !edited.loginUrl.isNullOrBlank()
            var saveSucceeded = false
            var origin: String? = null
            val actionAvailable = action != "login" || loginVisible
            if (action != "finish" && actionAvailable) {
                val completed = CompletableDeferred<BookSource>()
                val viewModel = BookSourceEditViewModel(application)
                viewModel.bookSource = original
                viewModel.save(edited) {
                    completed.complete(it)
                }
                val saved = withTimeoutOrNull(1500) {
                    completed.await()
                }
                saveSucceeded = saved != null
                origin = saved?.bookSourceUrl
            }
            val destination = when {
                action == "finish" && dirty -> "discard_confirmation"
                action == "finish" -> "dismiss"
                !actionAvailable || !saveSucceeded -> null
                action == "save" -> "dismiss"
                action == "debug" -> "source_debug"
                action == "login" -> "source_login"
                action == "search" -> "single_source_search"
                else -> error("Unsupported editor action: $action")
            }
            projected.put(
                JSONObject()
                    .put("id", id)
                    .put("action", action)
                    .put("login_visible", loginVisible)
                    .put("dirty", dirty)
                    .put("save_succeeded", saveSucceeded)
                    .put(
                        "requires_discard_confirmation",
                        action == "finish" && dirty
                    )
                    .put(
                        "destination",
                        destination ?: JSONObject.NULL
                    )
                    .put(
                        "result_code",
                        if (action == "save" && saveSucceeded) {
                            "ok"
                        } else {
                            JSONObject.NULL
                        }
                    )
                    .put("origin", origin ?: JSONObject.NULL)
            )
            appDb.bookSourceDao.delete(edited)
            appDb.bookSourceDao.delete(original)
        }
        return JSONObject().put("actions", projected)
    }

    private suspend fun sourceDebugKeyMatrix(
        arguments: JSONObject
    ): JSONObject {
        val keys = arguments.getJSONArray("keys")
        val projected = JSONArray()
        val source = BookSource(
            bookSourceUrl = "android-runtime://source-debug",
            bookSourceName = "Oracle Debug Source"
        )
        for (index in 0 until keys.length()) {
            val item = keys.getJSONObject(index)
            val kind = item.getString("kind")
            val payload = item.getString("payload")
            val local = "http://127.0.0.1:1/$payload"
            val key = when (kind) {
                "detail" -> local
                "explore" -> "发现::$local"
                "toc" -> "++$local"
                "content" -> "--$local"
                "search" -> payload
                else -> error("Unsupported debug key kind: $kind")
            }
            val messages = mutableListOf<String>()
            Debug.callback = object : Debug.Callback {
                override fun printLog(state: Int, msg: String) {
                    messages.add(
                        msg.replace(
                            Regex("^\\[[^]]+]\\s*"),
                            ""
                        )
                    )
                }
            }
            val scope = CoroutineScope(coroutineContext + Job())
            Debug.startDebug(scope, source, key)
            val first = messages.firstOrNull().orEmpty()
            val route = when {
                first.startsWith("⇒开始访问详情页:") -> "book_info"
                first.startsWith("⇒开始访问发现页:") -> "explore"
                first.startsWith("⇒开始访目录页:") -> "toc"
                first.startsWith("⇒开始访正文页:") -> "content"
                first.startsWith("⇒开始搜索关键字:") -> "search"
                else -> "unknown"
            }
            projected.put(
                JSONObject()
                    .put("id", item.getString("id"))
                    .put("kind", kind)
                    .put("payload", payload)
                    .put("route", route)
                    .put(
                        "first_log_event",
                        when (route) {
                            "book_info" -> "visit_book_info"
                            "explore" -> "visit_explore"
                            "toc" -> "visit_toc"
                            "content" -> "visit_content"
                            "search" -> "search_keyword"
                            else -> "unknown"
                        }
                    )
            )
            Debug.cancelDebug(destroy = true)
            scope.coroutineContext.cancelChildren()
        }
        return JSONObject().put("keys", projected)
    }

    private fun sourceEditorResultMatrix(
        arguments: JSONObject
    ): JSONObject {
        val results = arguments.getJSONArray("results")
        val projected = JSONArray()
        for (index in 0 until results.length()) {
            val item = results.getJSONObject(index)
            val caller = item.getString("caller")
            val result = item.getString("result")
            val effects = when (caller) {
                "book_detail" -> if (result == "canceled") {
                    emptyList()
                } else {
                    listOf("reload_source", "refresh_book")
                }
                "reader" -> if (result == "ok") {
                    listOf("reload_source", "refresh_menu")
                } else {
                    emptyList()
                }
                else -> error("Unsupported source edit caller: $caller")
            }
            projected.put(
                JSONObject()
                    .put("id", item.getString("id"))
                    .put("caller", caller)
                    .put("result", result)
                    .put("effects", JSONArray(effects))
            )
        }
        return JSONObject().put("results", projected)
    }

    private suspend fun runSourceImportRuntimeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "source_import_format_matrix" ->
                        sourceImportFormatMatrix(arguments)
                    "source_import_comparison_matrix" ->
                        sourceImportComparisonMatrix(arguments)
                    "source_import_merge_matrix" ->
                        sourceImportMergeMatrix(arguments)
                    else -> error(
                        "Unsupported source import operation: $operation"
                    )
                }
            }
        }
    }

    private suspend fun sourceImportFormatMatrix(
        arguments: JSONObject
    ): JSONObject {
        val formats = arguments.getJSONArray("formats")
        val projected = JSONArray()
        for (index in 0 until formats.length()) {
            val item = formats.getJSONObject(index)
            val id = item.getString("id")
            val source = sourceImportFixture(
                "android-runtime://source-import/$id",
                "Imported $id",
                20
            )
            val second = sourceImportFixture(
                "android-runtime://source-import/$id/second",
                "Imported $id second",
                21
            )
            val invalidSecond = sourceImportFixture(
                "",
                "Missing URL",
                21
            )
            val payload = when (item.getString("kind")) {
                "object" -> GSON.toJson(source)
                "array" -> GSON.toJson(listOf(source, second))
                "empty_array" -> "[]"
                "array_invalid_second" ->
                    GSON.toJson(listOf(source, invalidSecond))
                "missing_url" -> GSON.toJson(invalidSecond)
                "invalid" -> "not-a-source-definition"
                else -> error(
                    "Unsupported source import format: ${
                        item.getString("kind")
                    }"
                )
            }
            val viewModel = sourceImportViewModel()
            val outcome = awaitSourceImport(viewModel, payload)
            projected.put(
                JSONObject()
                    .put("id", id)
                    .put("kind", item.getString("kind"))
                    .put("status", outcome.getString("status"))
                    .put(
                        "count",
                        if (outcome.isNull("count")) {
                            JSONObject.NULL
                        } else {
                            outcome.getInt("count")
                        }
                    )
                    .put(
                        "source_urls",
                        JSONArray().apply {
                            viewModel.allSources.forEach {
                                put(it.bookSourceUrl)
                            }
                        }
                    )
            )
            viewModel.allSources.forEach {
                if (it.bookSourceUrl.isNotEmpty()) {
                    appDb.bookSourceDao.delete(it)
                }
            }
        }
        return JSONObject().put("formats", projected)
    }

    private suspend fun sourceImportComparisonMatrix(
        arguments: JSONObject
    ): JSONObject {
        val comparisons = arguments.getJSONArray("comparisons")
        val projected = JSONArray()
        for (index in 0 until comparisons.length()) {
            val item = comparisons.getJSONObject(index)
            val id = item.getString("id")
            val url = "android-runtime://source-import/comparison/$id"
            val incoming = sourceImportFixture(
                url,
                "Incoming $id",
                item.getLong("incoming_update")
            )
            var existing: BookSource? = null
            if (!item.isNull("existing_update")) {
                existing = sourceImportFixture(
                    url,
                    "Existing $id",
                    item.getLong("existing_update")
                )
                appDb.bookSourceDao.insert(existing)
            }
            val viewModel = sourceImportViewModel()
            val outcome = awaitSourceImport(
                viewModel,
                GSON.toJson(incoming)
            )
            projected.put(
                JSONObject()
                    .put("id", id)
                    .put("status", outcome.getString("status"))
                    .put(
                        "selected",
                        viewModel.selectStatus.firstOrNull() ?: false
                    )
                    .put(
                        "new_source",
                        viewModel.newSourceStatus.firstOrNull() ?: false
                    )
                    .put(
                        "update_source",
                        viewModel.updateSourceStatus.firstOrNull() ?: false
                    )
            )
            appDb.bookSourceDao.delete(incoming)
            existing?.let { appDb.bookSourceDao.delete(it) }
        }
        return JSONObject().put("comparisons", projected)
    }

    private suspend fun sourceImportMergeMatrix(
        arguments: JSONObject
    ): JSONObject {
        val target = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
        val application = target.applicationContext as Application
        val previousKeepName = AppConfig.importKeepName
        val previousKeepGroup = AppConfig.importKeepGroup
        val previousKeepEnable = AppConfig.importKeepEnable
        val merges = arguments.getJSONArray("merges")
        val projected = JSONArray()
        try {
            for (index in 0 until merges.length()) {
                val item = merges.getJSONObject(index)
                val id = item.getString("id")
                val url = "android-runtime://source-import/merge/$id"
                val existing = sourceImportFixture(
                    url,
                    "Existing $id",
                    10
                ).apply {
                    bookSourceGroup = "oldA,oldB"
                    enabled = false
                    enabledExplore = false
                    customOrder = 17
                }
                val incoming = sourceImportFixture(
                    url,
                    "Incoming $id",
                    20
                ).apply {
                    bookSourceGroup = "incoming"
                    enabled = true
                    enabledExplore = true
                    customOrder = 99
                }
                appDb.bookSourceDao.insert(existing)
                target.putPrefBoolean(
                    PreferKey.importKeepName,
                    item.getBoolean("keep_name")
                )
                target.putPrefBoolean(
                    PreferKey.importKeepGroup,
                    item.getBoolean("keep_group")
                )
                AppConfig.importKeepEnable =
                    item.getBoolean("keep_enable")

                val viewModel = ImportBookSourceViewModel(application)
                val outcome = awaitSourceImport(
                    viewModel,
                    GSON.toJson(incoming)
                )
                require(outcome.getString("status") == "accepted")
                viewModel.groupName = item.getString("group")
                viewModel.isAddGroup =
                    item.getString("group_mode") == "append"
                if (viewModel.selectStatus.isNotEmpty()) {
                    viewModel.selectStatus[0] = true
                }
                val completed = CompletableDeferred<Unit>()
                viewModel.importSelect {
                    completed.complete(Unit)
                }
                require(
                    withTimeoutOrNull(2000) {
                        completed.await()
                        true
                    } == true
                ) {
                    "Source import merge did not complete"
                }
                val saved = requireNotNull(
                    appDb.bookSourceDao.getBookSource(url)
                )
                projected.put(
                    JSONObject()
                        .put("id", id)
                        .put("name", saved.bookSourceName)
                        .put(
                            "group",
                            saved.bookSourceGroup ?: JSONObject.NULL
                        )
                        .put("enabled", saved.enabled)
                        .put(
                            "enabled_explore",
                            saved.enabledExplore
                        )
                        .put("custom_order", saved.customOrder)
                )
                appDb.bookSourceDao.delete(saved)
            }
        } finally {
            target.putPrefBoolean(
                PreferKey.importKeepName,
                previousKeepName
            )
            target.putPrefBoolean(
                PreferKey.importKeepGroup,
                previousKeepGroup
            )
            AppConfig.importKeepEnable = previousKeepEnable
        }
        return JSONObject().put("merges", projected)
    }

    private fun sourceImportViewModel(): ImportBookSourceViewModel {
        val application = InstrumentationRegistry
            .getInstrumentation()
            .targetContext
            .applicationContext as Application
        return ImportBookSourceViewModel(application)
    }

    private fun sourceImportFixture(
        url: String,
        name: String,
        update: Long
    ): BookSource = BookSource(
        bookSourceUrl = url,
        bookSourceName = name
    ).apply {
        lastUpdateTime = update
    }

    private suspend fun awaitSourceImport(
        viewModel: ImportBookSourceViewModel,
        payload: String
    ): JSONObject {
        val completed = CompletableDeferred<JSONObject>()
        val successObserver = Observer<Int> { count ->
            if (!completed.isCompleted) {
                completed.complete(
                    JSONObject()
                        .put("status", "accepted")
                        .put("count", count)
                )
            }
        }
        val errorObserver = Observer<String> {
            if (!completed.isCompleted) {
                completed.complete(
                    JSONObject()
                        .put("status", "rejected")
                        .put("count", JSONObject.NULL)
                )
            }
        }
        onMainThread {
            viewModel.successLiveData.observeForever(successObserver)
            viewModel.errorLiveData.observeForever(errorObserver)
        }
        return try {
            viewModel.importSource(payload)
            withTimeoutOrNull(2000) {
                completed.await()
            } ?: JSONObject()
                .put("status", "timeout")
                .put("count", JSONObject.NULL)
        } finally {
            onMainThread {
                viewModel.successLiveData.removeObserver(successObserver)
                viewModel.errorLiveData.removeObserver(errorObserver)
            }
        }
    }

    private fun searchScopeProjection(
        arguments: JSONObject
    ): JSONObject {
        val scope = SearchScope(arguments.getString("scope"))
        if (!arguments.isNull("remove")) {
            scope.remove(arguments.getString("remove"))
        }
        return JSONObject()
            .put("serialized_scope", scope.toString())
            .put("display_names", JSONArray(scope.displayNames))
            .put("is_source", scope.isSource())
            .put("is_all", scope.isAll())
    }

    private fun searchScopeMenuProjection(
        activity: SearchActivity,
        arguments: JSONObject
    ): JSONObject = onMainThread {
        val viewModel = ViewModelProvider(activity)[
            SearchViewModel::class.java
        ]
        viewModel.searchScope.update(
            arguments.getString("scope"),
            false
        )
        val groups = arguments.getJSONArray("groups")
        val values = ArrayList<String>(groups.length())
        for (index in 0 until groups.length()) {
            values.add(groups.getString(index))
        }
        SearchActivity::class.java
            .getDeclaredField("groups")
            .apply { isAccessible = true }
            .set(activity, values)

        val menu = MenuBuilder(activity)
        activity.onCompatCreateOptionsMenu(menu)
        activity.onMenuOpened(0, menu)
        val selected = JSONArray()
        val available = JSONArray()
        for (index in 0 until menu.size()) {
            val item = menu.getItem(index)
            when (item.groupId) {
                R.id.menu_group_1 -> if (item.isChecked) {
                    selected.put(item.title.toString())
                }
                R.id.menu_group_2 -> if (
                    item.itemId != R.id.menu_1
                ) {
                    available.put(item.title.toString())
                }
            }
        }
        JSONObject()
            .put(
                "serialized_scope",
                viewModel.searchScope.toString()
            )
            .put("is_all", viewModel.searchScope.isAll())
            .put("selected", selected)
            .put("available", available)
            .put(
                "all_checked",
                menu.findItem(R.id.menu_1).isChecked
            )
    }

    private fun searchLoadingProjection(
        activity: SearchActivity
    ): JSONObject = onMainThread {
        invokeSearchActivityPrivate(activity, "startSearch")
        val started = JSONObject()
            .put(
                "progress",
                visibilityName(
                    activity.findViewById(
                        R.id.refresh_progress_bar
                    )
                )
            )
            .put(
                "stop",
                visibilityName(
                    activity.findViewById(R.id.fb_stop)
                )
            )
        invokeSearchActivityPrivate(activity, "searchFinally")
        JSONObject()
            .put("started", started)
            .put(
                "finished",
                JSONObject()
                    .put(
                        "progress",
                        visibilityName(
                            activity.findViewById(
                                R.id.refresh_progress_bar
                            )
                        )
                    )
                    .put(
                        "stop",
                        visibilityName(
                            activity.findViewById(R.id.fb_stop)
                        )
                    )
            )
    }

    private fun searchDetailRoundtripProjection(
        scenario: ActivityScenario<SearchActivity>,
        activity: SearchActivity,
        arguments: JSONObject
    ): JSONObject {
        val instrumentation =
            InstrumentationRegistry.getInstrumentation()
        val monitor = instrumentation.addMonitor(
            BookInfoActivity::class.java.name,
            null,
            false
        )
        try {
            onMainThread {
                activity.findViewById<SearchView>(
                    R.id.search_view
                ).setQuery(
                    arguments.getString("query"),
                    false
                )
                activity.showBookInfo(
                    arguments.getString("name"),
                    arguments.getString("author"),
                    arguments.getString("book_url")
                )
            }
            val detail = requireNotNull(
                instrumentation.waitForMonitorWithTimeout(
                    monitor,
                    5_000
                )
            ) {
                "BookInfoActivity did not start"
            }
            val intent = detail.intent
            val destination =
                if (detail is BookInfoActivity) {
                    "book_detail"
                } else {
                    detail::class.java.name
                }
            onMainThread { detail.finish() }
            instrumentation.waitForIdleSync()
            scenario.moveToState(Lifecycle.State.RESUMED)
            var query = ""
            scenario.onActivity {
                query = it.findViewById<SearchView>(
                    R.id.search_view
                ).query.toString()
            }
            return JSONObject()
                .put("destination", destination)
                .put("name", intent.getStringExtra("name"))
                .put("author", intent.getStringExtra("author"))
                .put(
                    "book_url",
                    intent.getStringExtra("bookUrl")
                )
                .put("query_after_return", query)
        } finally {
            instrumentation.removeMonitor(monitor)
        }
    }

    private fun invokeSearchActivityPrivate(
        activity: SearchActivity,
        name: String
    ) {
        SearchActivity::class.java
            .getDeclaredMethod(name)
            .apply { isAccessible = true }
            .invoke(activity)
    }

    private fun visibilityName(view: View): String =
        when (view.visibility) {
            View.VISIBLE -> "visible"
            View.INVISIBLE -> "invisible"
            View.GONE -> "gone"
            else -> "unknown"
        }

    private fun bookDetailConditionalActionProjection(
        activity: BookInfoActivity,
        caseId: String,
        arguments: JSONObject
    ): JSONObject = onMainThread {
        val bookKind = arguments.getString("book_kind")
        val local = bookKind.startsWith("local_")
        val book = Book(
            bookUrl = "/android-runtime/book-detail/$caseId",
            tocUrl = "/android-runtime/book-detail/$caseId/toc",
            origin = if (local) {
                BookType.localTag
            } else {
                "android-runtime://book-source"
            },
            originName = when (bookKind) {
                "remote" -> "Oracle Source"
                "local_txt" -> "oracle-book.txt"
                "local_epub" -> "oracle-book.epub"
                else -> error("Unsupported book kind: $bookKind")
            },
            name = "Oracle Book $caseId",
            author = "Oracle",
            type = if (local) BookType.local else BookType.text
        )
        book.canUpdate = arguments.getBoolean("can_update")
        book.setSplitLongChapter(
            arguments.getBoolean("split_long_chapter")
        )
        val source = when (arguments.getString("source_state")) {
            "present" -> BookSource(
                bookSourceUrl = "android-runtime://book-source",
                bookSourceName = "Oracle Source",
                loginUrl = when (
                    arguments.getString("login_url_state")
                ) {
                    "nonblank" -> "/login"
                    "blank" -> ""
                    "whitespace" -> " \t "
                    else -> error("Unsupported login URL state")
                }
            )
            "missing" -> null
            else -> error("Unsupported source state")
        }
        LocalConfig.bookInfoDeleteAlert =
            arguments.getBoolean("delete_alert")

        val menu = MenuBuilder(activity)
        activity.onCompatCreateOptionsMenu(menu)
        val viewModel = ViewModelProvider(activity)[
            BookInfoViewModel::class.java
        ]
        viewModel.inBookshelf =
            arguments.getBoolean("in_bookshelf")
        viewModel.bookSource = source
        viewModel.bookData.value = book
        activity.onMenuOpened(0, menu)

        val shelfText = activity
            .findViewById<TextView>(R.id.tv_shelf)
            .text
            .toString()
        val shelfAction = when (shelfText) {
            activity.getString(R.string.add_to_bookshelf) -> "add"
            activity.getString(R.string.remove_from_bookshelf) -> "remove"
            else -> error("Unknown bookshelf action label")
        }
        JSONObject()
            .put("shelf_action", shelfAction)
            .put(
                "actions",
                JSONObject()
                    .put(
                        "edit",
                        menu.findItem(R.id.menu_edit).isVisible
                    )
                    .put(
                        "login",
                        menu.findItem(R.id.menu_login).isVisible
                    )
                    .put(
                        "set_source_variable",
                        menu.findItem(
                            R.id.menu_set_source_variable
                        ).isVisible
                    )
                    .put(
                        "set_book_variable",
                        menu.findItem(
                            R.id.menu_set_book_variable
                        ).isVisible
                    )
                    .put(
                        "can_update",
                        menu.findItem(
                            R.id.menu_can_update
                        ).isVisible
                    )
                    .put(
                        "split_long_chapter",
                        menu.findItem(
                            R.id.menu_split_long_chapter
                        ).isVisible
                    )
                    .put(
                        "upload",
                        menu.findItem(R.id.menu_upload).isVisible
                    )
            )
            .put(
                "checked",
                JSONObject()
                    .put(
                        "can_update",
                        menu.findItem(
                            R.id.menu_can_update
                        ).isChecked
                    )
                    .put(
                        "split_long_chapter",
                        menu.findItem(
                            R.id.menu_split_long_chapter
                        ).isChecked
                    )
                    .put(
                        "delete_alert",
                        menu.findItem(
                            R.id.menu_delete_alert
                        ).isChecked
                    )
            )
    }

    private suspend fun runReaderProgressSaveRuntimeCases() {
        val values = input.getJSONArray("cases")
        val supported = setOf(
            "save_runtime_execution_state",
            "save_runtime_book_switch",
            "save_runtime_session_clear",
            "save_runtime_multi_queue",
            "save_runtime_missing_chapter",
            "save_runtime_durability_window"
        )
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(operation in supported) {
                "Unsupported reader progress save operation: $operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                readerProgressSaveRuntimeProjection(
                    operation,
                    arguments
                )
            }
        }
    }

    private fun readerProgressSaveRuntimeProjection(
        operation: String,
        arguments: JSONObject
    ): JSONObject {
        clearProgressRuntimeState()
        val previousReadRecordEnabled = AppConfig.enableReadRecord
        AppConfig.enableReadRecord = false
        return try {
            when (operation) {
                "save_runtime_execution_state" ->
                    saveRuntimeExecutionStateProjection(arguments)
                "save_runtime_book_switch" ->
                    saveRuntimeBookSwitchProjection(arguments)
                "save_runtime_session_clear" ->
                    saveRuntimeSessionClearProjection(arguments)
                "save_runtime_multi_queue" ->
                    saveRuntimeMultiQueueProjection(arguments)
                "save_runtime_missing_chapter" ->
                    saveRuntimeMissingChapterProjection(arguments)
                "save_runtime_durability_window" ->
                    saveRuntimeDurabilityWindowProjection(arguments)
                else -> error(
                    "Unsupported reader progress save operation"
                )
            }
        } finally {
            drainReadBookExecutor()
            AppConfig.enableReadRecord = previousReadRecordEnabled
            clearProgressRuntimeState()
        }
    }

    private fun saveRuntimeExecutionStateProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressSaveBook(
            id = "execution-state",
            chapterIndex = arguments.getInt("stored_chapter_index"),
            chapterPos = arguments.getInt("stored_chapter_pos")
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("call_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("call_chapter_pos")
        val release = startReadBookExecutorBarrier()
        val persistedBefore: Book
        try {
            ReadBook.saveRead()
            persistedBefore = requireNotNull(
                appDb.bookDao.getBook(book.bookUrl)
            )
            ReadBook.durChapterIndex =
                arguments.getInt("execution_chapter_index")
            ReadBook.durChapterPos =
                arguments.getInt("execution_chapter_pos")
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put(
                "persisted_unchanged_while_queued",
                persistedBefore.durChapterIndex ==
                    arguments.getInt("stored_chapter_index") &&
                    persistedBefore.durChapterPos ==
                    arguments.getInt("stored_chapter_pos")
            )
            .put(
                "persisted_call_time_progress",
                persisted.durChapterIndex ==
                    arguments.getInt("call_chapter_index") &&
                    persisted.durChapterPos ==
                    arguments.getInt("call_chapter_pos")
            )
            .put(
                "persisted_execution_time_progress",
                persisted.durChapterIndex ==
                    arguments.getInt("execution_chapter_index") &&
                    persisted.durChapterPos ==
                    arguments.getInt("execution_chapter_pos")
            )
            .put("persisted_chapter_title", persisted.durChapterTitle)
            .put("last_check_count", persisted.lastCheckCount)
    }

    private fun saveRuntimeBookSwitchProjection(
        arguments: JSONObject
    ): JSONObject {
        val fromBook = progressSaveBook(
            id = "switch-from",
            name = "RuntimeLab 旧阅读会话"
        )
        val toBook = progressSaveBook(
            id = "switch-to",
            name = "RuntimeLab 新阅读会话"
        )
        seedProgressBook(fromBook)
        seedProgressBook(toBook)
        ReadBook.resetData(fromBook)
        ReadBook.durChapterIndex =
            arguments.getInt("from_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("from_chapter_pos")
        val release = startReadBookExecutorBarrier()
        try {
            ReadBook.saveRead()
            ReadBook.resetData(toBook)
            ReadBook.durChapterIndex =
                arguments.getInt("to_chapter_index")
            ReadBook.durChapterPos =
                arguments.getInt("to_chapter_pos")
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val persistedFrom = requireNotNull(
            appDb.bookDao.getBook(fromBook.bookUrl)
        )
        val persistedTo = requireNotNull(
            appDb.bookDao.getBook(toBook.bookUrl)
        )
        return JSONObject()
            .put(
                "old_book_progress_unchanged",
                persistedFrom.durChapterIndex == 0 &&
                    persistedFrom.durChapterPos == 0
            )
            .put(
                "new_book_received_queued_save",
                persistedTo.durChapterIndex ==
                    arguments.getInt("to_chapter_index") &&
                    persistedTo.durChapterPos ==
                    arguments.getInt("to_chapter_pos")
            )
            .put(
                "queued_save_captured_original_book",
                persistedFrom.durChapterIndex ==
                    arguments.getInt("from_chapter_index") &&
                    persistedFrom.durChapterPos ==
                    arguments.getInt("from_chapter_pos")
            )
            .put("new_book_chapter_title", persistedTo.durChapterTitle)
    }

    private fun saveRuntimeSessionClearProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressSaveBook(id = "session-clear")
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("runtime_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("runtime_chapter_pos")
        val release = startReadBookExecutorBarrier()
        try {
            ReadBook.saveRead()
            ReadBook.book = null
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put(
                "queued_save_was_dropped",
                persisted.durChapterIndex == 0 &&
                    persisted.durChapterPos == 0 &&
                    persisted.durChapterTime == 1L
            )
            .put("runtime_book_is_null", ReadBook.book == null)
            .put("last_check_count_unchanged", persisted.lastCheckCount == 7)
    }

    private fun saveRuntimeMultiQueueProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressSaveBook(id = "multi-queue")
        seedProgressBook(book)
        ReadBook.resetData(book)
        val afterFirst = AtomicReference<Book?>()
        val markerCompleted = CountDownLatch(1)
        val release = startReadBookExecutorBarrier()
        try {
            ReadBook.durChapterIndex =
                arguments.getInt("first_chapter_index")
            ReadBook.durChapterPos =
                arguments.getInt("first_chapter_pos")
            ReadBook.saveRead()
            ReadBook.executor.execute {
                afterFirst.set(appDb.bookDao.getBook(book.bookUrl))
                markerCompleted.countDown()
            }
            ReadBook.durChapterIndex =
                arguments.getInt("second_chapter_index")
            ReadBook.durChapterPos =
                arguments.getInt("second_chapter_pos")
            ReadBook.saveRead()
            ReadBook.durChapterIndex =
                arguments.getInt("final_chapter_index")
            ReadBook.durChapterPos =
                arguments.getInt("final_chapter_pos")
        } finally {
            release.countDown()
        }
        check(markerCompleted.await(5, TimeUnit.SECONDS)) {
            "Progress save marker did not complete"
        }
        drainReadBookExecutor()
        val firstPersisted = requireNotNull(afterFirst.get())
        val finalPersisted = requireNotNull(
            appDb.bookDao.getBook(book.bookUrl)
        )
        val finalIndex = arguments.getInt("final_chapter_index")
        val finalPos = arguments.getInt("final_chapter_pos")
        return JSONObject()
            .put(
                "first_queued_save_observed_final_state",
                firstPersisted.durChapterIndex == finalIndex &&
                    firstPersisted.durChapterPos == finalPos
            )
            .put(
                "second_queued_save_observed_final_state",
                finalPersisted.durChapterIndex == finalIndex &&
                    finalPersisted.durChapterPos == finalPos
            )
            .put(
                "first_call_snapshot_was_preserved",
                firstPersisted.durChapterIndex ==
                    arguments.getInt("first_chapter_index") &&
                    firstPersisted.durChapterPos ==
                    arguments.getInt("first_chapter_pos")
            )
    }

    private fun saveRuntimeMissingChapterProjection(
        arguments: JSONObject
    ): JSONObject {
        val existingTitle = arguments.getString("existing_title")
        val book = progressSaveBook(
            id = "missing-chapter",
            chapterTitle = existingTitle
        )
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("runtime_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("runtime_chapter_pos")
        ReadBook.saveRead()
        drainReadBookExecutor()
        val persisted = requireNotNull(appDb.bookDao.getBook(book.bookUrl))
        return JSONObject()
            .put("persisted_chapter_index", persisted.durChapterIndex)
            .put("persisted_char_position", persisted.durChapterPos)
            .put(
                "missing_chapter_preserved_title",
                persisted.durChapterTitle == existingTitle
            )
            .put("persisted_chapter_title", persisted.durChapterTitle)
    }

    private fun saveRuntimeDurabilityWindowProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = progressSaveBook(id = "durability-window")
        seedProgressBook(book)
        ReadBook.resetData(book)
        ReadBook.durChapterIndex =
            arguments.getInt("runtime_chapter_index")
        ReadBook.durChapterPos =
            arguments.getInt("runtime_chapter_pos")
        val release = startReadBookExecutorBarrier()
        val beforeExecution: Book
        try {
            ReadBook.saveRead()
            beforeExecution = requireNotNull(
                appDb.bookDao.getBook(book.bookUrl)
            )
        } finally {
            release.countDown()
        }
        drainReadBookExecutor()
        val afterExecution = requireNotNull(
            appDb.bookDao.getBook(book.bookUrl)
        )
        return JSONObject()
            .put(
                "database_unchanged_while_save_queued",
                beforeExecution.durChapterIndex == 0 &&
                    beforeExecution.durChapterPos == 0
            )
            .put(
                "database_updated_after_executor",
                afterExecution.durChapterIndex ==
                    arguments.getInt("runtime_chapter_index") &&
                    afterExecution.durChapterPos ==
                    arguments.getInt("runtime_chapter_pos")
            )
            .put(
                "queued_save_has_durability_window",
                beforeExecution.durChapterTime == 1L &&
                    afterExecution.durChapterTime > 1L
            )
    }

    private fun progressSaveBook(
        id: String,
        name: String = "RuntimeLab 进度保存",
        chapterIndex: Int = 0,
        chapterPos: Int = 0,
        chapterTitle: String = "既有标题"
    ): Book = Book(
        bookUrl = "/android-runtime/reader-progress/save-$id.txt",
        originName = "RuntimeLab",
        name = name,
        author = "RuntimeLab",
        totalChapterNum = 3,
        durChapterTitle = chapterTitle,
        durChapterIndex = chapterIndex,
        durChapterPos = chapterPos,
        durChapterTime = 1L,
        lastCheckCount = 7
    )

    private suspend fun runReaderProgressTocRemapCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_progress_toc_remap"
            ) {
                "Unsupported reader progress TOC remap operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_progress_toc_remap")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_progress_toc_remap",
                stimulus
            ) {
                readerProgressTocRemapProjection(arguments)
            }
        }
    }

    private suspend fun runAppStartupCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            val operation = value.getString("operation")
            require(
                operation == "app_startup_welcome" ||
                    operation == "app_startup_main_pipeline"
            ) {
                "Unsupported app startup operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", operation)
                .put("arguments", JSONObject(arguments.toString()))
            runCase(value.getString("id"), operation, stimulus) {
                when (operation) {
                    "app_startup_welcome" ->
                        welcomeStartupProjection(arguments)
                    else ->
                        mainStartupProjection(arguments)
                }
            }
        }
    }

    private suspend fun welcomeStartupProjection(
        arguments: JSONObject
    ): JSONObject {
        prepareStableMainStartup()
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        target.putPrefBoolean(
            PreferKey.defaultToRead,
            arguments.getBoolean("default_to_read")
        )
        val instrumentation =
            InstrumentationRegistry.getInstrumentation()
        val startMonitor = StartupIntentMonitor(target.packageName)
        instrumentation.addMonitor(startMonitor)
        val scenario = ActivityScenario.launch<WelcomeActivity>(
            Intent(target, WelcomeActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        try {
            waitForStartupCondition("main-start-dispatched") {
                startMonitor.wasDispatched(MainActivity::class.java)
            }
            val expectsReader =
                arguments.getBoolean("default_to_read")
            if (expectsReader) {
                waitForStartupCondition("reader-start-dispatched") {
                    startMonitor.wasDispatched(
                        ReadBookActivity::class.java
                    )
                }
                waitForStartupCondition("reader-observed") {
                    isTargetActivityPresent(ReadBookActivity::class.java)
                }
            }
            waitForStartupCondition("welcome-destroyed") {
                scenario.state == Lifecycle.State.DESTROYED
            }
            instrumentation.waitForIdleSync()
            val downstreamSequence = startMonitor.downstreamSequence()
            val mainIndex = downstreamSequence.indexOf(
                MainActivity::class.java.simpleName
            )
            val readerIndex = downstreamSequence.indexOf(
                ReadBookActivity::class.java.simpleName
            )
            require(mainIndex >= 0) {
                "MainActivity start dispatch was not recorded"
            }
            require(
                if (expectsReader) {
                    readerIndex > mainIndex
                } else {
                    readerIndex < 0
                }
            ) {
                "Downstream start order did not match defaultToRead"
            }
            val readerStarted =
                startMonitor.wasDispatched(ReadBookActivity::class.java)
            return JSONObject()
                .put(
                    "downstream_start_sequence",
                    JSONArray(downstreamSequence)
                )
                .put("main_started", true)
                .put("reader_started", readerStarted)
                .put(
                    "reader_activity_observed",
                    isTargetActivityPresent(ReadBookActivity::class.java)
                )
                .put("welcome_destroyed", true)
        } finally {
            if (scenario.state != Lifecycle.State.DESTROYED) {
                scenario.close()
            }
            instrumentation.removeMonitor(startMonitor)
            finishTargetActivities()
            target.putPrefBoolean(PreferKey.defaultToRead, false)
        }
    }

    private suspend fun waitForStartupCondition(
        label: String,
        timeoutMillis: Long = 5_000,
        condition: () -> Boolean
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMillis
        while (!condition()) {
            check(SystemClock.elapsedRealtime() < deadline) {
                "Startup condition timed out: $label"
            }
            delay(20)
        }
    }

    private fun isTargetActivityPresent(
        activityClass: Class<out Activity>
    ): Boolean =
        currentTargetActivities().any { activityClass.isInstance(it) }

    private class StartupIntentMonitor(
        private val packageName: String
    ) : Instrumentation.ActivityMonitor() {
        private val dispatchedClassNames = mutableListOf<String>()

        override fun onStartActivity(
            intent: Intent
        ): Instrumentation.ActivityResult? {
            val component = intent.component
            if (component?.packageName == packageName) {
                synchronized(this) {
                    dispatchedClassNames.add(
                        component.className.substringAfterLast('.')
                    )
                }
            }
            return null
        }

        fun wasDispatched(
            activityClass: Class<out Activity>
        ): Boolean = synchronized(this) {
            dispatchedClassNames.contains(activityClass.simpleName)
        }

        fun downstreamSequence(): List<String> =
            synchronized(this) {
                dispatchedClassNames.filter {
                    it == MainActivity::class.java.simpleName ||
                        it == ReadBookActivity::class.java.simpleName
                }
            }
    }

    private fun currentTargetActivities(): List<Activity> {
        val result = AtomicReference<List<Activity>>(emptyList())
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val monitor = ActivityLifecycleMonitorRegistry.getInstance()
            result.set(
                listOf(
                    Stage.CREATED,
                    Stage.STARTED,
                    Stage.RESUMED,
                    Stage.PAUSED,
                    Stage.STOPPED
                ).flatMap { stage ->
                    monitor.getActivitiesInStage(stage)
                }.distinct()
            )
        }
        return result.get()
    }

    private suspend fun finishTargetActivities() {
        val requested = mutableSetOf<Activity>()
        withTimeout(10_000) {
            while (true) {
                val snapshot = currentTargetActivities()
                if (snapshot.isEmpty()) {
                    break
                }
                val pending = snapshot.filterNot {
                    it in requested || it.isFinishing || it.isDestroyed
                }
                requested.addAll(pending)
                InstrumentationRegistry.getInstrumentation()
                    .runOnMainSync {
                        pending.asReversed()
                            .forEach(Activity::finishAndRemoveTask)
                    }
                delay(50)
            }
        }
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private suspend fun mainStartupProjection(
        arguments: JSONObject
    ): JSONObject {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        resetStartupPreferences(target)
        val local = target.getSharedPreferences(
            "local",
            Context.MODE_PRIVATE
        )
        local.edit()
            .putBoolean(
                "privacyPolicyOk",
                arguments.getString("privacy_state") == "accepted"
            )
            .putLong(
                "appVersionCode",
                when (arguments.getString("stored_version")) {
                    "current" -> appInfo.versionCode
                    "previous" -> maxOf(0L, appInfo.versionCode - 1L)
                    else -> 0L
                }
            )
            .putBoolean("firstOpen", arguments.getBoolean("first_open"))
            .putBoolean("appCrash", arguments.getBoolean("app_crash"))
            .apply {
                when (arguments.getString("password_state")) {
                    "empty" -> putString("password", "")
                    "nonempty" -> putString("password", "oracle-secret")
                    else -> remove("password")
                }
            }
            .commit()

        val dialogs = JSONArray()
        val scenario = ActivityScenario.launch<MainActivity>(
            Intent(target, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        var activity: MainActivity? = null
        scenario.onActivity { activity = it }
        try {
            if (arguments.optString("privacy_action") == "refuse") {
                waitForText(R.string.refuse)
                dialogs.put("privacy")
                onView(withText(R.string.refuse)).perform(click())
            } else if (arguments.optString("privacy_action") == "agree") {
                waitForText(R.string.agree)
                dialogs.put("privacy")
                onView(withText(R.string.agree)).perform(click())
            }

            if (
                arguments.getBoolean("first_open") &&
                arguments.optString("privacy_action") != "refuse"
            ) {
                val main = requireNotNull(activity)
                waitForTextDialog(main)
                dialogs.put("help")
                onView(withId(R.id.menu_close)).perform(click())
            }
            if (
                arguments.getString("password_state") == "unset" &&
                arguments.optString("privacy_action") != "refuse"
            ) {
                waitForText(android.R.string.cancel)
                dialogs.put("local_password")
                onView(withText(android.R.string.cancel)).perform(click())
            }

            delay(350)
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            val main = requireNotNull(activity)
            return JSONObject()
                .put("build_debug", BuildConfig.DEBUG)
                .put("dialog_sequence", dialogs)
                .put("activity_finishing", main.isFinishing)
                .put("privacy_accepted", LocalConfig.privacyPolicyOk)
                .put(
                    "version_matches_current",
                    LocalConfig.versionCode == appInfo.versionCode
                )
                .put(
                    "first_open_after",
                    local.getBoolean("firstOpen", true)
                )
                .put(
                    "password_state_after",
                    when (LocalConfig.password) {
                        null -> "unset"
                        "" -> "empty"
                        else -> "nonempty"
                    }
                )
                .put("app_crash_after", LocalConfig.appCrash)
                .put("last_backup_after", LocalConfig.lastBackup)
                .put(
                    "help_dialog_remaining",
                    hasTextDialog(main)
                )
                .put(
                    "update_log_visible",
                    isTextVisible(R.string.update_log)
                )
        } finally {
            scenario.close()
            resetStartupPreferences(target)
        }
    }

    private fun prepareStableMainStartup() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        resetStartupPreferences(target)
        val local = target.getSharedPreferences(
            "local",
            Context.MODE_PRIVATE
        )
        local.edit()
            .putBoolean("privacyPolicyOk", true)
            .putLong("appVersionCode", appInfo.versionCode)
            .putBoolean("firstOpen", false)
            .putString("password", "")
            .putBoolean("appCrash", false)
            .commit()
    }

    private fun resetStartupPreferences(target: Context) {
        target.getSharedPreferences("local", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
        target.defaultSharedPreferences.edit()
            .remove(PreferKey.defaultToRead)
            .remove(PreferKey.webDavAccount)
            .remove(PreferKey.webDavPassword)
            .remove(PreferKey.autoRefresh)
            .commit()
    }

    private suspend fun waitForText(resourceId: Int) {
        withTimeout(5_000) {
            while (!isTextVisible(resourceId)) {
                delay(20)
            }
        }
    }

    private suspend fun waitForTextDialog(activity: MainActivity) {
        withTimeout(5_000) {
            while (!hasTextDialog(activity)) {
                delay(20)
            }
        }
    }

    private fun hasTextDialog(activity: MainActivity): Boolean {
        val present = AtomicBoolean(false)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val fragmentManager = activity.supportFragmentManager
            if (!activity.isDestroyed && !fragmentManager.isDestroyed) {
                fragmentManager.executePendingTransactions()
                present.set(
                    fragmentManager.fragments.any {
                        it is TextDialog && it.isAdded
                    }
                )
            }
        }
        return present.get()
    }

    private fun isTextVisible(resourceId: Int): Boolean =
        try {
            onView(withText(resourceId)).check { view, error ->
                if (error != null || view == null || !view.isShown) {
                    throw AssertionError("Text is not visible")
                }
            }
            true
        } catch (_: Throwable) {
            false
        }

    private fun readerProgressTocRemapProjection(
        arguments: JSONObject
    ): JSONObject {
        val titles = arguments.getJSONArray("new_titles")
        val chapters = ArrayList<BookChapter>(titles.length())
        for (index in 0 until titles.length()) {
            chapters.add(
                BookChapter(
                    url = "/android-runtime/toc-remap/$index",
                    title = titles.getString(index),
                    bookUrl = "/android-runtime/toc-remap/book",
                    index = index
                )
            )
        }
        val oldTitle =
            if (arguments.isNull("old_title")) null
            else arguments.getString("old_title")
        val selectedIndex = BookHelp.getDurChapter(
            arguments.getInt("old_index"),
            oldTitle,
            chapters,
            arguments.getInt("old_list_size")
        )
        val inBounds = selectedIndex in chapters.indices
        return JSONObject()
            .put("selected_index", selectedIndex)
            .put("selected_index_in_bounds", inBounds)
            .put(
                "selected_title",
                if (inBounds) chapters[selectedIndex].title
                else JSONObject.NULL
            )
            .put("new_chapter_count", chapters.size)
    }

    private suspend fun runReaderPrefetchPolicyCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") == "reader_prefetch_policy"
            ) {
                "Unsupported reader prefetch operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_prefetch_policy")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_prefetch_policy",
                stimulus
            ) {
                readerPrefetchPolicyProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun runReaderSessionResetCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") == "reader_session_reset"
            ) {
                "Unsupported reader session reset operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_session_reset")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_session_reset",
                stimulus
            ) {
                readerSessionResetProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun runReaderContentAcquisitionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_content_acquisition"
            ) {
                "Unsupported reader content acquisition operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_content_acquisition")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_content_acquisition",
                stimulus
            ) {
                readerContentAcquisitionProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private suspend fun runReaderIndexLoadDedupCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_index_load_dedup"
            ) {
                "Unsupported reader index load dedup operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_index_load_dedup")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_index_load_dedup",
                stimulus
            ) {
                readerIndexLoadDedupProjection(arguments)
            }
        }
    }

    private suspend fun runReaderContentNormalizationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_content_normalization"
            ) {
                "Unsupported reader content normalization operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_content_normalization")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_content_normalization",
                stimulus
            ) {
                readerContentNormalizationProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private fun readerContentNormalizationProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        val book = Book(
            bookUrl = "/android-runtime/content-normalization/$caseId",
            origin = arguments.optString(
                "book_origin",
                "android-runtime://normalization/$caseId"
            ),
            originName = "Normalization Oracle",
            name = arguments.optString("book_name", "归一化测试书"),
            author = "RuntimeLab",
            type = BookType.text
        ).apply {
            setUseReplaceRule(arguments.optBoolean("use_replace", true))
            setReSegment(false)
        }
        val chapter = BookChapter(
            url = "/android-runtime/content-normalization/$caseId/0",
            title = arguments.getString("title"),
            bookUrl = book.bookUrl,
            index = 0
        )
        val rules = mutableListOf<ReplaceRule>()
        val ruleValues = arguments.optJSONArray("rules") ?: JSONArray()
        for (index in 0 until ruleValues.length()) {
            val value = ruleValues.getJSONObject(index)
            rules.add(
                ReplaceRule(
                    id = 9_100_000L + caseId.hashCode().toLong() * 10L + index,
                    name = value.getString("name"),
                    pattern = value.getString("pattern"),
                    replacement = value.getString("replacement"),
                    scope =
                        if (value.isNull("scope")) null
                        else value.getString("scope"),
                    scopeTitle = value.optBoolean("scope_title", false),
                    scopeContent = value.optBoolean("scope_content", true),
                    isEnabled = value.optBoolean("enabled", true),
                    isRegex = value.optBoolean("is_regex", false),
                    order = value.optInt("order", index)
                )
            )
        }
        val previousConverter = AppConfig.chineseConverterType
        val previousIndent = ReadBookConfig.paragraphIndent
        return try {
            AppConfig.chineseConverterType = 0
            ReadBookConfig.paragraphIndent =
                arguments.optString("paragraph_indent", "　　")
            if (rules.isNotEmpty()) {
                appDb.replaceRuleDao.insert(*rules.toTypedArray())
            }
            val processor = ContentProcessor.get(book)
            val displayTitle = chapter.getDisplayTitle(
                processor.getTitleReplaceRules(),
                useReplace = book.getUseReplaceRule(),
                chineseConvert = false
            )
            val normalized = processor.getContent(
                book = book,
                chapter = chapter,
                content = arguments.getString("content"),
                includeTitle = arguments.optBoolean("include_title", false),
                chineseConvert = false,
                reSegment = false
            )
            JSONObject()
                .put("display_title", displayTitle)
                .put("same_title_removed", normalized.sameTitleRemoved)
                .put(
                    "paragraphs",
                    JSONArray().apply {
                        normalized.textList.forEach { put(it) }
                    }
                )
                .put("rendered_text", normalized.toString())
                .put(
                    "effective_rules",
                    JSONArray().apply {
                        normalized.effectiveReplaceRules
                            ?.forEach { put(it.name) }
                    }
                )
        } finally {
            if (rules.isNotEmpty()) {
                appDb.replaceRuleDao.delete(*rules.toTypedArray())
            }
            AppConfig.chineseConverterType = previousConverter
            ReadBookConfig.paragraphIndent = previousIndent
        }
    }

    private suspend fun runReaderChapterNavigationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "reader_chapter_navigation"
            ) {
                "Unsupported reader chapter navigation operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_chapter_navigation")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_chapter_navigation",
                stimulus
            ) {
                readerChapterNavigationProjection(
                    value.getString("id"),
                    arguments
                )
            }
        }
    }

    private fun readerChapterNavigationProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        val action = arguments.getString("action")
        val chapterIndex = arguments.getInt("chapter_index")
        val chapterSize = arguments.getInt("chapter_size")
        val chapterPosition = arguments.getInt("chapter_position")
        val book = Book(
            bookUrl = "/android-runtime/chapter-navigation/$caseId.txt",
            origin = BookType.localTag,
            originName = "Local",
            name = "Navigation $caseId",
            author = "RuntimeLab",
            type = BookType.local,
            durChapterIndex = chapterIndex,
            durChapterPos = chapterPosition
        ).apply {
            setUseReplaceRule(false)
            setReSegment(false)
        }
        val callback = LayoutStreamCallback("none")
        val previousReadRecord = AppConfig.enableReadRecord
        clearReaderChapterNavigationState()
        return try {
            AppConfig.enableReadRecord = false
            ReadBook.book = book
            ReadBook.chapterSize = chapterSize
            ReadBook.durChapterIndex = chapterIndex
            ReadBook.durChapterPos = chapterPosition
            ReadBook.callBack = callback
            ReadBook.prevTextChapter = navigationTextChapter(
                arguments.optJSONArray("previous_page_starts"),
                chapterIndex - 1,
                chapterSize
            )
            ReadBook.curTextChapter = navigationTextChapter(
                arguments.optJSONArray("current_page_starts"),
                chapterIndex,
                chapterSize
            )
            ReadBook.nextTextChapter = navigationTextChapter(
                arguments.optJSONArray("next_page_starts"),
                chapterIndex + 1,
                chapterSize
            )

            val moved = when (action) {
                "next_page" -> ReadBook.moveToNextPage()
                "previous_page" -> ReadBook.moveToPrevPage()
                "next_chapter" ->
                    ReadBook.moveToNextChapter(
                        upContent = true,
                        upContentInPlace = true
                    )
                "previous_chapter" ->
                    ReadBook.moveToPrevChapter(
                        upContent = true,
                        toLast = arguments.optBoolean("to_last", true),
                        upContentInPlace = true
                    )
                else -> error("Unsupported navigation action")
            }
            drainReadBookExecutor()
            val events = JSONArray().apply {
                val snapshot = callback.snapshot()
                for (eventIndex in 0 until snapshot.length()) {
                    val event = snapshot.getJSONObject(eventIndex)
                    val type = event.getString("type")
                    if (
                        type == "up_content" ||
                        type == "up_menu" ||
                        type == "page_changed"
                    ) {
                        put(
                            JSONObject()
                                .put("type", type)
                                .apply {
                                    if (type == "up_content") {
                                        put(
                                            "reset_page_offset",
                                            event.getBoolean(
                                                "reset_page_offset"
                                            )
                                        )
                                    }
                                }
                        )
                    }
                }
            }
            JSONObject()
                .put("moved", moved)
                .put("runtime_chapter_index", ReadBook.durChapterIndex)
                .put("runtime_chapter_position", ReadBook.durChapterPos)
                .put("stored_chapter_index", book.durChapterIndex)
                .put("stored_chapter_position", book.durChapterPos)
                .put(
                    "previous_window_position",
                    ReadBook.prevTextChapter?.position ?: JSONObject.NULL
                )
                .put(
                    "current_window_position",
                    ReadBook.curTextChapter?.position ?: JSONObject.NULL
                )
                .put(
                    "next_window_position",
                    ReadBook.nextTextChapter?.position ?: JSONObject.NULL
                )
                .put("events", events)
        } finally {
            AppConfig.enableReadRecord = previousReadRecord
            clearReaderChapterNavigationState()
        }
    }

    private fun navigationTextChapter(
        starts: JSONArray?,
        position: Int,
        chapterSize: Int
    ): TextChapter? {
        if (starts == null) return null
        val chapter = TextChapter(
            chapter = BookChapter(
                url = "/android-runtime/chapter-navigation/$position",
                title = "Navigation Chapter $position",
                bookUrl = "/android-runtime/chapter-navigation/book.txt",
                index = position.coerceAtLeast(0)
            ),
            position = position,
            title = "Navigation Chapter $position",
            chaptersSize = chapterSize,
            sameTitleRemoved = false,
            isVip = false,
            isPay = false,
            effectiveReplaceRules = null
        )
        val field = TextChapter::class.java.getDeclaredField("textPages")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val pages = field.get(chapter) as ArrayList<TextPage>
        for (index in 0 until starts.length()) {
            val start = starts.getInt(index)
            val text = "Page $index"
            val page = TextPage(
                index = index,
                text = text,
                title = chapter.title,
                chapterSize = chapterSize,
                chapterIndex = position
            )
            page.addLine(
                TextLine(
                    text = text,
                    chapterPosition = start
                )
            )
            page.textChapter = chapter
            pages.add(page)
        }
        chapter.isCompleted = true
        return chapter
    }

    private fun clearReaderChapterNavigationState() {
        ReadBook.coroutineContext.cancelChildren()
        ReadBook.downloadScope.coroutineContext.cancelChildren()
        drainReadBookExecutor()
        ReadBook.callBack = null
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.chapterSize = 0
        ReadBook.durChapterIndex = 0
        ReadBook.durChapterPos = 0
        ReadBook.prevTextChapter = null
        ReadBook.curTextChapter = null
        ReadBook.nextTextChapter = null
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
    }

    private suspend fun runReaderSessionCloseCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") == "reader_session_close"
            ) {
                "Unsupported reader session close operation"
            }
            val arguments = value.getJSONObject("arguments")
            val stimulus = JSONObject()
                .put("operation", "reader_session_close")
                .put("arguments", JSONObject(arguments.toString()))
            runCase(
                value.getString("id"),
                "reader_session_close",
                stimulus
            ) {
                readerSessionCloseProjection(arguments)
            }
        }
    }

    private fun readerSessionCloseProjection(
        arguments: JSONObject
    ): JSONObject {
        clearReaderSessionCloseState()
        val registered = LayoutStreamCallback("none")
        val foreign = LayoutStreamCallback("none")
        val invoked =
            if (arguments.getBoolean("callback_matches")) registered
            else foreign
        val preDownload = Job()
        val downloadChild = Job(
            requireNotNull(
                ReadBook.downloadScope.coroutineContext[Job]
            )
        )
        val mainChild = Job(
            requireNotNull(ReadBook.coroutineContext[Job])
        )
        val previous = navigationTextChapter(JSONArray().put(0), 0, 3)!!
        val current = navigationTextChapter(JSONArray().put(0), 1, 3)!!
        val next = navigationTextChapter(JSONArray().put(0), 2, 3)!!
        previous.listener = registered
        current.listener = registered
        next.listener = registered
        val imageKey = "android-runtime://reader-close/image"
        ImageProvider.put(
            imageKey,
            android.graphics.Bitmap.createBitmap(
                1,
                1,
                android.graphics.Bitmap.Config.ARGB_8888
            )
        )
        return try {
            ReadBook.callBack = registered
            ReadBook.msg = "closing"
            ReadBook.preDownloadTask = preDownload
            ReadBook.downloadedChapters.addAll(listOf(1, 2))
            ReadBook.downloadFailChapters[3] = 2
            ReadBook.prevTextChapter = previous
            ReadBook.curTextChapter = current
            ReadBook.nextTextChapter = next
            synchronized(ReadBook) {
                prefetchLoadingList().addAll(listOf(7, 8))
            }

            ReadBook.unregister(invoked)

            JSONObject()
                .put("callback_cleared", ReadBook.callBack == null)
                .put("message_cleared", ReadBook.msg == null)
                .put("pre_download_cancelled", preDownload.isCancelled)
                .put(
                    "download_children_cancelled",
                    downloadChild.isCancelled
                )
                .put("main_children_cancelled", mainChild.isCancelled)
                .put(
                    "downloaded_chapters_cleared",
                    ReadBook.downloadedChapters.isEmpty()
                )
                .put(
                    "download_failures_cleared",
                    ReadBook.downloadFailChapters.isEmpty()
                )
                .put(
                    "image_cache_cleared",
                    ImageProvider.get(imageKey) == null
                )
                .put(
                    "current_layout_listener_cleared",
                    current.listener == null
                )
                .put(
                    "previous_layout_listener_preserved",
                    previous.listener === registered
                )
                .put(
                    "next_layout_listener_preserved",
                    next.listener === registered
                )
                .put(
                    "loading_indices",
                    intProjection(prefetchLoadingIndices())
                )
        } finally {
            preDownload.cancel()
            downloadChild.cancel()
            mainChild.cancel()
            clearReaderSessionCloseState()
        }
    }

    private fun clearReaderSessionCloseState() {
        ReadBook.coroutineContext.cancelChildren()
        ReadBook.downloadScope.coroutineContext.cancelChildren()
        ReadBook.callBack = null
        ReadBook.msg = null
        ReadBook.preDownloadTask = null
        ReadBook.downloadedChapters.clear()
        ReadBook.downloadFailChapters.clear()
        ReadBook.prevTextChapter = null
        ReadBook.curTextChapter = null
        ReadBook.nextTextChapter = null
        ImageProvider.clear()
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
    }

    private fun readerIndexLoadDedupProjection(
        arguments: JSONObject
    ): JSONObject {
        val index = arguments.getInt("index")
        val attempts = JSONArray()
        var staleRemovalErasedReplacement = false
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
        try {
            when (arguments.getString("mode")) {
                "duplicate" -> {
                    attempts.put(invokeAddLoading(index))
                    attempts.put(invokeAddLoading(index))
                }
                "remove_retry" -> {
                    attempts.put(invokeAddLoading(index))
                    ReadBook.removeLoading(index)
                    attempts.put(invokeAddLoading(index))
                }
                "different_indices" -> {
                    attempts.put(invokeAddLoading(index))
                    attempts.put(
                        invokeAddLoading(
                            arguments.getInt("other_index")
                        )
                    )
                }
                "single" -> attempts.put(invokeAddLoading(index))
                "session_replacement", "stale_removal" -> {
                    val firstBook = readerDedupBook("first")
                    val replacementBook = readerDedupBook("replacement")
                    ReadBook.upData(firstBook)
                    attempts.put(invokeAddLoading(index))
                    ReadBook.upData(replacementBook)
                    attempts.put(invokeAddLoading(index))
                    if (arguments.getString("mode") == "stale_removal") {
                        ReadBook.removeLoading(index)
                        val replacementWasRemoved =
                            index !in prefetchLoadingIndices()
                        attempts.put(invokeAddLoading(index))
                        staleRemovalErasedReplacement =
                            replacementWasRemoved &&
                                attempts.getBoolean(2)
                    }
                }
                else -> error("Unsupported reader dedup mode")
            }
            return JSONObject()
                .put("attempt_results", attempts)
                .put(
                    "active_indices",
                    intProjection(prefetchLoadingIndices())
                )
                .put(
                    "stale_removal_erased_replacement",
                    staleRemovalErasedReplacement
                )
        } finally {
            synchronized(ReadBook) {
                prefetchLoadingList().clear()
            }
            ReadBook.book = null
            ReadBook.bookSource = null
        }
    }

    private fun readerDedupBook(label: String): Book =
        Book(
            bookUrl = "/android-runtime/reader-dedup/$label.txt",
            origin = BookType.localTag,
            originName = "Local",
            name = "Reader Dedup $label",
            author = "RuntimeLab",
            type = BookType.local
        )

    private fun invokeAddLoading(index: Int): Boolean {
        val method = ReadBook::class.java.getDeclaredMethod(
            "addLoading",
            Int::class.javaPrimitiveType
        )
        method.isAccessible = true
        return method.invoke(ReadBook, index) as Boolean
    }

    private suspend fun readerContentAcquisitionProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        val local = arguments.getString("book_kind") == "local"
        val origin =
            if (local) BookType.localTag
            else "android-runtime://reader-content/source/$caseId"
        val book = Book(
            bookUrl =
                if (local) {
                    "/android-runtime/missing-local/$caseId.txt"
                } else {
                    "/android-runtime/reader-content/$caseId"
                },
            origin = origin,
            originName = "Oracle Content Source",
            name = "Oracle Content $caseId",
            author = "RuntimeLab",
            type = if (local) BookType.local else BookType.text
        ).apply {
            setUseReplaceRule(false)
            setReSegment(false)
        }
        val source = BookSource(
            bookSourceUrl = origin,
            bookSourceName = "Oracle Content Source",
            ruleContent = ContentRule(content = "@CSS:body@text")
        )
        val chapter = BookChapter(
            url =
                if (
                    arguments.getString("source_mode") ==
                    "present_invalid_url"
                ) {
                    "unsupported://oracle-content/$caseId"
                } else {
                    "/android-runtime/reader-content/$caseId/0"
                },
            title = "Content Chapter",
            bookUrl = book.bookUrl,
            index = 0
        )
        clearReaderContentAcquisitionState(book, origin)
        val callback = LayoutStreamCallback("none")
        return try {
            appDb.bookDao.insert(book)
            if (arguments.getString("chapter_mode") == "present") {
                appDb.bookChapterDao.insert(chapter)
            }
            if (
                arguments.getString("source_mode") ==
                "present_invalid_url"
            ) {
                appDb.bookSourceDao.insert(source)
            }
            when (arguments.getString("cache_mode")) {
                "text", "empty" -> BookHelp.saveText(
                    book,
                    chapter,
                    arguments.getString("cached_content")
                )
                "missing" -> Unit
                else -> error("Unsupported reader cache mode")
            }
            val before = BookHelp.getContent(book, chapter)

            ReadBook.book = book
            ReadBook.bookSource =
                if (
                    arguments.getString("source_mode") ==
                    "present_invalid_url"
                ) {
                    source
                } else {
                    null
                }
            ReadBook.chapterSize = 2
            ReadBook.durChapterIndex = 1
            ReadBook.durChapterPos = 0
            ReadBook.callBack = callback
            ReadBook.loadContent(
                index = 0,
                upContent = false,
                resetPageOffset = false,
                success = callback::markSuccess
            )

            when {
                arguments.getString("chapter_mode") == "missing" ->
                    withTimeout(5_000) {
                        while (0 in prefetchLoadingList()) {
                            delay(10)
                        }
                    }
                arguments.getString("source_mode") ==
                    "present_invalid_url" ->
                    withTimeout(5_000) {
                        while (
                            (ReadBook.downloadFailChapters[0] ?: 0) == 0 ||
                            ReadBook.prevTextChapter == null
                        ) {
                            delay(10)
                        }
                    }
                else -> withTimeout(5_000) {
                    while (
                        ReadBook.prevTextChapter == null ||
                        0 in prefetchLoadingList()
                    ) {
                        delay(10)
                    }
                }
            }

            val after = BookHelp.getContent(book, chapter)
            JSONObject()
                .put("initial_content_state", contentState(before))
                .put("initial_content", nullable(before))
                .put("cached_content_after_load", contentState(after))
                .put("content_after_load", nullable(after))
                .put("source_present", ReadBook.bookSource != null)
                .put(
                    "source_delegated",
                    (ReadBook.downloadFailChapters[0] ?: 0) > 0
                )
                .put(
                    "download_failure_count",
                    ReadBook.downloadFailChapters[0] ?: 0
                )
                .put(
                    "download_marked_success",
                    0 in ReadBook.downloadedChapters
                )
                .put(
                    "chapter_loaded",
                    ReadBook.prevTextChapter != null
                )
                .put(
                    "loading_cleared",
                    0 !in prefetchLoadingList()
                )
        } finally {
            clearReaderContentAcquisitionState(book, origin)
        }
    }

    private fun contentState(value: String?): String =
        when {
            value == null -> "missing"
            value.isEmpty() -> "empty"
            else -> "text"
        }

    private suspend fun clearReaderContentAcquisitionState(
        book: Book,
        origin: String
    ) {
        ReadBook.coroutineContext.cancelChildren()
        CacheBook.close()
        ReadBook.callBack = null
        ReadBook.clearTextChapter()
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.contentProcessor = null
        ReadBook.chapterSize = 0
        ReadBook.durChapterIndex = 0
        ReadBook.durChapterPos = 0
        ReadBook.downloadedChapters.clear()
        ReadBook.downloadFailChapters.clear()
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
        appDb.bookChapterDao.delByBook(book.bookUrl)
        appDb.bookDao.getBook(book.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookSourceDao.getBookSource(origin)?.let {
            appDb.bookSourceDao.delete(it)
        }
        BookHelp.clearCache(book)
        delay(20)
    }

    private fun readerSessionResetProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        val local = arguments.getString("book_kind") == "local"
        val origin =
            if (local) BookType.localTag
            else "android-runtime://reader-session/source/$caseId"
        val book = Book(
            bookUrl = "/android-runtime/reader-session/$caseId.txt",
            origin = origin,
            originName = "Oracle Session Source",
            name = "Oracle Session $caseId",
            author = "RuntimeLab",
            type = if (local) BookType.local else BookType.text,
            durChapterIndex = arguments.getInt("stored_chapter_index"),
            durChapterPos = arguments.getInt("stored_chapter_pos")
        )
        val imageStyle =
            if (arguments.isNull("book_image_style")) null
            else arguments.getString("book_image_style")
        book.setImageStyle(imageStyle)
        val callback = LayoutStreamCallback("none")
        return try {
            seedReaderSessionReset(
                book = book,
                caseId = caseId,
                arguments = arguments
            )
            ReadBook.callBack = callback
            ReadBook.bookSource = BookSource(
                bookSourceUrl = "stale://reader-session",
                bookSourceName = "Stale Source"
            )
            ReadBook.lastBookPress = BookProgress(book)
            ReadBook.webBookProgress = BookProgress(book)
            ReadBook.prevTextChapter =
                sessionResetTextChapter(book, -1)
            ReadBook.curTextChapter =
                sessionResetTextChapter(book, 0)
            ReadBook.nextTextChapter =
                sessionResetTextChapter(book, 1)
            synchronized(ReadBook) {
                prefetchLoadingList().addAll(listOf(7, 8))
            }
            ReadBook.downloadedChapters.add(91)
            ReadBook.downloadFailChapters[92] = 2

            ReadBook.resetData(book)

            val sessionRecord = currentSessionReadRecord()
            val callbackEvents = JSONArray().apply {
                val snapshot = callback.snapshot()
                for (eventIndex in 0 until snapshot.length()) {
                    val event = snapshot.getJSONObject(eventIndex)
                    put(
                        JSONObject()
                            .put("type", event.getString("type"))
                            .apply {
                                if (event.has("up_recorder")) {
                                    put(
                                        "up_recorder",
                                        event.getBoolean("up_recorder")
                                    )
                                }
                            }
                    )
                }
            }
            JSONObject()
                .put("book_identity", ReadBook.book?.bookUrl)
                .put("chapter_size", ReadBook.chapterSize)
                .put("runtime_chapter_index", ReadBook.durChapterIndex)
                .put("runtime_chapter_pos", ReadBook.durChapterPos)
                .put("stored_chapter_index", book.durChapterIndex)
                .put("stored_chapter_pos", book.durChapterPos)
                .put("is_local_book", ReadBook.isLocalBook)
                .put(
                    "book_source_url",
                    ReadBook.bookSource?.bookSourceUrl ?: JSONObject.NULL
                )
                .put(
                    "content_processor_present",
                    ReadBook.contentProcessor != null
                )
                .put(
                    "book_image_style",
                    book.getImageStyle() ?: JSONObject.NULL
                )
                .put("read_record_book_name", sessionRecord.bookName)
                .put("read_record_time", sessionRecord.readTime)
                .put(
                    "text_chapters_cleared",
                    ReadBook.prevTextChapter == null &&
                        ReadBook.curTextChapter == null &&
                        ReadBook.nextTextChapter == null
                )
                .put(
                    "temporary_progress_cleared",
                    ReadBook.lastBookPress == null &&
                        ReadBook.webBookProgress == null
                )
                .put(
                    "loading_chapters_cleared",
                    prefetchLoadingList().isEmpty()
                )
                .put(
                    "download_state_preserved",
                    91 in ReadBook.downloadedChapters &&
                        ReadBook.downloadFailChapters[92] == 2
                )
                .put("callback_events", callbackEvents)
        } finally {
            clearReaderSessionResetState(book, origin)
        }
    }

    private fun seedReaderSessionReset(
        book: Book,
        caseId: String,
        arguments: JSONObject
    ) {
        clearReaderSessionResetState(book, book.origin)
        appDb.bookDao.insert(book)
        val chapterCount = arguments.getInt("chapter_count")
        val chapters = (0 until chapterCount).map { index ->
            BookChapter(
                url = "/android-runtime/reader-session/$caseId/$index",
                title = "Session Chapter $index",
                bookUrl = book.bookUrl,
                index = index
            )
        }
        if (chapters.isNotEmpty()) {
            appDb.bookChapterDao.insert(*chapters.toTypedArray())
        }
        if (
            !book.isLocal &&
            arguments.getString("source_mode") == "present"
        ) {
            appDb.bookSourceDao.insert(
                BookSource(
                    bookSourceUrl = book.origin,
                    bookSourceName = "Oracle Session Source",
                    ruleContent = ContentRule(
                        content = "@CSS:#content@text",
                        imageStyle =
                            arguments.getString("source_image_style")
                    )
                )
            )
        }
        val readTimes = arguments.getJSONArray("read_times")
        for (index in 0 until readTimes.length()) {
            appDb.readRecordDao.insert(
                ReadRecord(
                    deviceId = "session-device-$index",
                    bookName = book.name,
                    readTime = readTimes.getLong(index),
                    lastRead = 100L + index
                )
            )
        }
    }

    private fun sessionResetTextChapter(
        book: Book,
        position: Int
    ): TextChapter = TextChapter(
        chapter = BookChapter(
            url = "${book.bookUrl}/stale/$position",
            title = "Stale Chapter $position",
            bookUrl = book.bookUrl,
            index = position.coerceAtLeast(0)
        ),
        position = position,
        title = "Stale Chapter $position",
        chaptersSize = 3,
        sameTitleRemoved = false,
        isVip = false,
        isPay = false,
        effectiveReplaceRules = null
    )

    private fun clearReaderSessionResetState(
        book: Book,
        origin: String
    ) {
        ReadBook.callBack = null
        ReadBook.clearTextChapter()
        ReadBook.book = null
        ReadBook.bookSource = null
        ReadBook.contentProcessor = null
        ReadBook.lastBookPress = null
        ReadBook.webBookProgress = null
        ReadBook.downloadedChapters.clear()
        ReadBook.downloadFailChapters.clear()
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
        appDb.bookChapterDao.delByBook(book.bookUrl)
        appDb.bookDao.getBook(book.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookSourceDao.getBookSource(origin)?.let {
            appDb.bookSourceDao.delete(it)
        }
        appDb.readRecordDao.clear()
    }

    private suspend fun readerPrefetchPolicyProjection(
        caseId: String,
        arguments: JSONObject
    ): JSONObject {
        clearPrefetchRuntimeState()
        val previousPreDownloadNum = AppConfig.preDownloadNum
        val book = prefetchBook(caseId, arguments)
        return try {
            seedPrefetchBook(book, arguments)
            ReadBook.resetData(book)
            ReadBook.durChapterIndex =
                arguments.getInt("current_chapter")
            ReadBook.downloadedChapters.addAll(
                jsonInts(arguments.getJSONArray("pre_downloaded_indices"))
            )
            val failureCounts = arguments.getJSONArray("failure_counts")
            for (index in 0 until failureCounts.length()) {
                val value = failureCounts.getJSONObject(index)
                ReadBook.downloadFailChapters[value.getInt("index")] =
                    value.getInt("count")
            }
            AppConfig.preDownloadNum =
                arguments.getInt("pre_download_num")
            when (arguments.getString("mode")) {
                "settled" -> settledPrefetchProjection()
                "observe_workers" -> prefetchWorkersProjection()
                "replace_job" -> replacementPrefetchProjection(arguments)
                else -> error("Unsupported reader prefetch mode")
            }
        } finally {
            AppConfig.preDownloadNum = previousPreDownloadNum
            clearPrefetchRuntimeState()
        }
    }

    private suspend fun settledPrefetchProjection(): JSONObject {
        invokePreDownload()
        val task = ReadBook.preDownloadTask
        if (task != null) {
            withTimeout(5_000) {
                while (!task.isCompleted) {
                    delay(10)
                }
            }
        }
        return JSONObject()
            .put("task_created", task != null)
            .put("task_completed", task?.isCompleted == true)
            .put(
                "downloaded_indices",
                intProjection(ReadBook.downloadedChapters)
            )
            .put(
                "failure_counts",
                failureCountProjection()
            )
            .put(
                "loading_indices",
                intProjection(prefetchLoadingIndices())
            )
    }

    private suspend fun prefetchWorkersProjection(): JSONObject {
        invokePreDownload()
        val task = requireNotNull(ReadBook.preDownloadTask)
        val expectedFirstIndices = listOf(
            ReadBook.durChapterIndex - 2,
            ReadBook.durChapterIndex + 2
        ).sorted()
        withTimeout(900) {
            while (
                !prefetchLoadingIndices().containsAll(expectedFirstIndices)
            ) {
                delay(5)
            }
        }
        val loading = prefetchLoadingIndices()
        val childCount = task.children.count()
        task.cancel()
        return JSONObject()
            .put("task_created", true)
            .put("child_job_count", childCount)
            .put(
                "initial_loading_indices",
                intProjection(loading)
            )
            .put(
                "directions_started",
                loading.containsAll(expectedFirstIndices)
            )
    }

    private suspend fun replacementPrefetchProjection(
        arguments: JSONObject
    ): JSONObject {
        invokePreDownload()
        val first = requireNotNull(ReadBook.preDownloadTask)
        val expectedFirstIndices = listOf(
            ReadBook.durChapterIndex - 2,
            ReadBook.durChapterIndex + 2
        )
        withTimeout(900) {
            while (
                !prefetchLoadingIndices().containsAll(expectedFirstIndices)
            ) {
                delay(5)
            }
        }
        ReadBook.durChapterIndex =
            arguments.getInt("replacement_current_chapter")
        invokePreDownload()
        val replacement = requireNotNull(ReadBook.preDownloadTask)
        withTimeout(900) {
            while (!first.isCancelled) {
                delay(5)
            }
        }
        replacement.cancel()
        return JSONObject()
            .put("first_task_cancelled", first.isCancelled)
            .put("replacement_task_created", true)
            .put("task_identity_changed", replacement !== first)
            .put(
                "replacement_current_chapter",
                ReadBook.durChapterIndex
            )
    }

    private fun invokePreDownload() {
        val method = ReadBook::class.java.getDeclaredMethod("preDownload")
        method.isAccessible = true
        method.invoke(ReadBook)
        drainReadBookExecutor()
    }

    private fun prefetchBook(
        caseId: String,
        arguments: JSONObject
    ): Book = Book(
        bookUrl = "/android-runtime/reader-prefetch/$caseId.txt",
        origin = if (arguments.getBoolean("local_book")) {
            "loc_book"
        } else {
            "runtime-prefetch-source"
        },
        originName = "RuntimeLab",
        name = "RuntimeLab 预取 $caseId",
        author = "RuntimeLab",
        type = if (arguments.getBoolean("local_book")) {
            BookType.local
        } else {
            BookType.text
        },
        totalChapterNum = arguments.getInt("chapter_size"),
        durChapterIndex = arguments.getInt("current_chapter")
    )

    private fun seedPrefetchBook(
        book: Book,
        arguments: JSONObject
    ) {
        BookHelp.clearCache(book)
        appDb.bookChapterDao.delByBook(book.bookUrl)
        appDb.bookDao.getBook(book.bookUrl)?.let {
            appDb.bookDao.delete(it)
        }
        appDb.bookDao.insert(book)
        val chapterSize = arguments.getInt("chapter_size")
        val chapters = (0 until chapterSize).map { index ->
            BookChapter(
                url = "/android-runtime/reader-prefetch/chapter/$index",
                title = "第${index + 1}章",
                bookUrl = book.bookUrl,
                index = index
            )
        }
        appDb.bookChapterDao.insert(*chapters.toTypedArray())
        val cached = jsonInts(arguments.getJSONArray("cached_indices")).toSet()
        chapters
            .filter { it.index in cached }
            .forEach {
                BookHelp.saveText(book, it, "cached-${it.index}")
            }
    }

    private suspend fun clearPrefetchRuntimeState() {
        val task = ReadBook.preDownloadTask
        task?.cancel()
        ReadBook.downloadScope.coroutineContext.cancelChildren()
        if (task != null) {
            withTimeout(5_000) {
                while (!task.isCompleted) {
                    delay(10)
                }
            }
        }
        drainReadBookExecutor()
        ReadBook.preDownloadTask = null
        ReadBook.downloadedChapters.clear()
        ReadBook.downloadFailChapters.clear()
        synchronized(ReadBook) {
            prefetchLoadingList().clear()
        }
        ReadBook.book = null
        appDb.bookDao.all
            .filter {
                it.bookUrl.startsWith(
                    "/android-runtime/reader-prefetch/"
                )
            }
            .forEach {
                BookHelp.clearCache(it)
                appDb.bookChapterDao.delByBook(it.bookUrl)
                appDb.bookDao.delete(it)
            }
    }

    private fun prefetchLoadingIndices(): List<Int> =
        synchronized(ReadBook) {
            prefetchLoadingList().toList().sorted()
        }

    @Suppress("UNCHECKED_CAST")
    private fun prefetchLoadingList(): ArrayList<Int> {
        val field = ReadBook::class.java.getDeclaredField(
            "loadingChapters"
        )
        field.isAccessible = true
        return field.get(ReadBook) as ArrayList<Int>
    }

    private fun jsonInts(values: JSONArray): List<Int> =
        (0 until values.length()).map(values::getInt)

    private fun intProjection(values: Collection<Int>): JSONArray =
        JSONArray().apply {
            values.toSortedSet().forEach { put(it) }
        }

    private fun failureCountProjection(): JSONArray =
        JSONArray().apply {
            ReadBook.downloadFailChapters
                .toSortedMap()
                .forEach { (index, count) ->
                    put(
                        JSONObject()
                            .put("index", index)
                            .put("count", count)
                    )
                }
        }

    private suspend fun runPostFormCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "search") {
                "POST form scenario only accepts search stimuli"
            }
            val keyword = value
                .getJSONObject("arguments")
                .getString("keyword")
            runCase(
                value.getString("id"),
                "search",
                postSearchRequest(keyword)
            ) {
                searchProjection(
                    WebBook.searchBookAwait(source, keyword)
                )
            }
        }
    }

    private suspend fun runSearchPipelineCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "search_pipeline") {
                "Search pipeline scenario only accepts search_pipeline stimuli"
            }
            val arguments = value.getJSONObject("arguments")
            val keyword = arguments.getString("keyword")
            val page = arguments.getInt("page")
            val mode = arguments.getString("mode")
            val caseSource = GSON.fromJson(
                sourceJson,
                BookSource::class.java
            ).apply {
                when (mode) {
                    "blank_url" -> searchUrl = " "
                    "login_check_transform" -> loginCheckJs = """
                        new Packages.io.legado.app.help.http.StrResponse(
                            result.url(),
                            String(result.body()).replace(
                                "locked-item",
                                "book-item"
                            )
                        )
                    """.trimIndent()
                    "detail_pattern" -> bookUrlPattern =
                        ".*/pipeline/search/4(?:\\?.*)?"
                }
            }
            val plannedRequest =
                if (!caseSource.searchUrl.isNullOrBlank()) {
                val analyze = AnalyzeUrl(
                    mUrl = requireNotNull(caseSource.searchUrl),
                    key = keyword,
                    page = page,
                    baseUrl = caseSource.bookSourceUrl,
                    source = caseSource,
                    headerMapF = caseSource.getHeaderMap(true)
                )
                request(analyze.url)
            } else {
                request("$deviceOrigin/pipeline/no-request")
            }
            runCase(
                value.getString("id"),
                "search_pipeline",
                plannedRequest
            ) {
                searchPipelineProjection(
                    WebBook.searchBookAwait(caseSource, keyword, page)
                )
            }
        }
    }

    private suspend fun runExplorePipelineCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "explore_pipeline") {
                "Explore pipeline scenario only accepts explore_pipeline stimuli"
            }
            val arguments = value.getJSONObject("arguments")
            val url = arguments
                .getString("url")
                .replace("\${SOURCE_LAB_ORIGIN}", deviceOrigin)
            val page = arguments.getInt("page")
            val analyze = AnalyzeUrl(
                mUrl = url,
                page = page,
                baseUrl = source.bookSourceUrl,
                source = source,
                ruleData = RuleData(),
                headerMapF = source.getHeaderMap(true)
            )
            runCase(
                value.getString("id"),
                "explore_pipeline",
                request(analyze.url)
            ) {
                searchPipelineProjection(
                    WebBook.exploreBookAwait(source, url, page)
                )
            }
        }
    }

    private fun searchPipelineProjection(
        values: List<SearchBook>
    ): JSONObject =
        JSONObject()
            .put("book_count", values.size)
            .put(
                "books",
                JSONArray().apply {
                    values.forEach { value ->
                        put(
                            JSONObject()
                                .put("name", value.name)
                                .put("author", value.author)
                                .put("kind", nullable(value.kind))
                                .put(
                                    "word_count",
                                    nullable(value.wordCount)
                                )
                                .put("intro", nullable(value.intro))
                                .put(
                                    "last_chapter",
                                    nullable(value.latestChapterTitle)
                                )
                                .put(
                                    "book_url",
                                    logical(value.bookUrl)
                                )
                                .put(
                                    "cover_url",
                                    nullableURL(value.coverUrl)
                                )
                                .put(
                                    "origin",
                                    logical(value.origin)
                                )
                                .put(
                                    "origin_name",
                                    value.originName
                                )
                                .put(
                                    "origin_order",
                                    value.originOrder
                                )
                                .put(
                                    "info_html_present",
                                    !value.infoHtml.isNullOrEmpty()
                                )
                        )
                    }
                }
            )

    private suspend fun runXmlResponseCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "raw_response") {
                "XML response scenario only accepts raw_response stimuli"
            }
            val target = value
                .getJSONObject("request")
                .getString("target")
            val analyze = AnalyzeUrl(
                mUrl = "$deviceOrigin$target",
                baseUrl = source.bookSourceUrl,
                source = source,
                headerMapF = source.getHeaderMap(true)
            )
            runCase(
                value.getString("id"),
                "raw_response",
                request(analyze.url)
            ) {
                val response = analyze.getStrResponseAwait(
                    useWebView = false
                )
                JSONObject()
                    .put("body", nullable(response.body))
                    .put("final_url", logical(response.url))
            }
        }
    }

    private suspend fun runResponseDecodingCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "response_decoding") {
                "Response decoding scenario only accepts response_decoding stimuli"
            }
            val target = value
                .getJSONObject("request")
                .getString("target")
            val analyze = AnalyzeUrl(
                mUrl = "$deviceOrigin$target",
                baseUrl = source.bookSourceUrl,
                source = source,
                headerMapF = source.getHeaderMap(true)
            )
            runCase(
                value.getString("id"),
                "response_decoding",
                analyzedRequest(analyze)
            ) {
                val response = analyze.getStrResponseAwait(
                    useWebView = false
                )
                JSONObject()
                    .put("body", nullable(response.body))
                    .put("final_url", logical(response.url))
                    .put("status_code", response.code())
                    .put("is_successful", response.isSuccessful())
            }
        }
    }

    private suspend fun runRetryRedirectCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "retry_redirect") {
                "Retry redirect scenario only accepts retry_redirect stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "retry_redirect")
            try {
                val (request, result) = when (
                    value.getJSONObject("arguments").getString("mode")
                ) {
                    "analyze_url" -> retryAnalyzeProjection(value)
                    "helper_status_sequence" ->
                        helperStatusSequenceProjection(value)
                    "helper_network_exception" ->
                        helperNetworkExceptionProjection(value)
                    "helper_cancellation" ->
                        helperCancellationProjection(value)
                    else -> error("Unsupported retry redirect mode")
                }
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = retryFallbackRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
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
    }

    private suspend fun runCookieSessionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "cookie_session") {
                "Cookie session scenario only accepts cookie_session stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "cookie_session")
            try {
                val (request, result) = cookieSessionProjection(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = cookieHelperRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
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
    }

    private suspend fun runDynamicWebCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "dynamic_web") {
                "Dynamic web scenario only accepts dynamic_web stimuli"
            }
            val id = value.getString("id")
            val record = JSONObject()
                .put("id", id)
                .put("operation", "dynamic_web")
            try {
                val (request, result) = dynamicWebProjection(value)
                requestPlan.put(request)
                record
                    .put("request", request)
                    .put("result", result)
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                val request = dynamicWebFallbackRequest(value)
                requestPlan.put(request)
                record
                    .put("request", request)
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
    }

    private suspend fun runRuleVariableScopeCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rule_variable_scope") {
                "Rule variable scenario only accepts rule_variable_scope stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_variable_scope",
                request
            ) {
                ruleVariableScopeProjection(value)
            }
        }
    }

    private suspend fun runRuleBackendDispatchCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rule_backend_dispatch") {
                "Rule backend scenario only accepts rule_backend_dispatch stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_backend_dispatch",
                request
            ) {
                ruleBackendDispatchProjection(value.getJSONObject("arguments"))
            }
        }
    }

    private suspend fun runRuleCombinationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "rule_combination_coercion"
            ) {
                "Rule combination scenario only accepts " +
                    "rule_combination_coercion stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "rule_combination_coercion",
                request
            ) {
                ruleCombinationProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runDOMSelectorBackendCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "dom_selector_backends"
            ) {
                "DOM selector scenario only accepts " +
                    "dom_selector_backends stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "dom_selector_backends",
                request
            ) {
                domSelectorProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runJSONPathRegexBackendCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "jsonpath_regex_backends"
            ) {
                "JSONPath/Regex scenario only accepts " +
                    "jsonpath_regex_backends stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "jsonpath_regex_backends",
                request
            ) {
                jsonPathRegexProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private suspend fun runContentCacheQueueCompletionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(
                value.getString("operation") ==
                    "content_cache_queue_completion"
            ) {
                "Content cache scenario only accepts " +
                    "content_cache_queue_completion stimuli"
            }
            val requestValue = value.getJSONObject("request")
            val request = request(
                deviceOrigin + requestValue.getString("target")
            )
            runCase(
                value.getString("id"),
                "content_cache_queue_completion",
                request
            ) {
                contentCacheQueueCompletionProjection(
                    value.getJSONObject("arguments")
                )
            }
        }
    }

    private fun contentCacheQueueCompletionProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "content_presence" -> contentPresenceProjection(arguments)
        "text_cache_lifecycle" -> textCacheLifecycleProjection(arguments)
        "image_completion" -> imageCompletionProjection(arguments)
        "queue_range_stop_resume" ->
            queueRangeStopResumeProjection(arguments)
        "retry_budget" -> retryBudgetProjection(arguments)
        "success_cancel" -> successCancelProjection(arguments)
        "registry_cleanup" -> registryCleanupProjection(arguments)
        else -> error("Unsupported content cache mode: $mode")
    }

    private fun contentPresenceProjection(
        arguments: JSONObject
    ): JSONObject {
        val remote = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, remote)
        val local = Book(
            bookUrl = arguments.getString("book_url") + "/local",
            origin = "local",
            originName = arguments.getString("local_txt_name"),
            name = arguments.getString("book_name") + " Local"
        )
        val volumeTitle = arguments.getString("volume_title")
        val pseudoVolume = BookChapter(
            url = "$volumeTitle::marker",
            title = volumeTitle,
            isVolume = true,
            bookUrl = remote.bookUrl,
            index = 1
        )
        val ordinaryVolume = BookChapter(
            url = "/volume/ordinary",
            title = volumeTitle,
            isVolume = true,
            bookUrl = remote.bookUrl,
            index = 2
        )
        BookHelp.clearCache(remote)
        return try {
            JSONObject()
                .put(
                    "local_txt_without_file",
                    BookHelp.hasContent(local, chapter.copy(bookUrl = local.bookUrl))
                )
                .put(
                    "pseudo_volume_without_file",
                    BookHelp.hasContent(remote, pseudoVolume)
                )
                .put(
                    "ordinary_volume_without_file",
                    BookHelp.hasContent(remote, ordinaryVolume)
                )
                .put(
                    "remote_chapter_without_file",
                    BookHelp.hasContent(remote, chapter)
                )
        } finally {
            BookHelp.clearCache(remote)
        }
    }

    private fun textCacheLifecycleProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, book)
        val content = arguments.getString("content")
        BookHelp.clearCache(book)
        return try {
            val before = BookHelp.hasContent(book, chapter)
            BookHelp.saveText(book, chapter, "")
            val afterEmpty = BookHelp.hasContent(book, chapter)
            BookHelp.saveText(book, chapter, content)
            val afterText = BookHelp.hasContent(book, chapter)
            val stored = BookHelp.getContent(book, chapter)
            val files = BookHelp.getChapterFiles(book).toList().sorted()
            BookHelp.delContent(book, chapter)
            JSONObject()
                .put("before_save", before)
                .put("after_empty_save", afterEmpty)
                .put("after_text_save", afterText)
                .put("stored_content", nullable(stored))
                .put("chapter_files", JSONArray(files))
                .put(
                    "expected_file_name",
                    chapter.getFileName()
                )
                .put(
                    "after_delete",
                    BookHelp.hasContent(book, chapter)
                )
        } finally {
            BookHelp.clearCache(book)
        }
    }

    private fun imageCompletionProjection(
        arguments: JSONObject
    ): JSONObject {
        val book = cacheProbeBook(arguments)
        val chapter = cacheProbeChapter(arguments, book)
        val missing = arguments.getString("missing_image_url")
        val valid = arguments.getString("valid_svg_url")
        BookHelp.clearCache(book)
        val invalidImage = BookHelp.getImage(book, missing)
        val validImage = BookHelp.getImage(book, valid)
        invalidImage.delete()
        validImage.delete()
        return try {
            val withoutText = BookHelp.hasImageContent(book, chapter)
            BookHelp.saveText(
                book,
                chapter,
                arguments.getString("plain_content")
            )
            val plainTextComplete = BookHelp.hasImageContent(book, chapter)
            BookHelp.saveText(
                book,
                chapter,
                "<p>text</p><img src=\"$missing\">"
            )
            val missingImageComplete = BookHelp.hasImageContent(book, chapter)
            invalidImage.parentFile?.mkdirs()
            invalidImage.writeText("not-an-image")
            val invalidImageComplete = BookHelp.hasImageContent(book, chapter)
            val invalidDeleted = !invalidImage.exists()
            BookHelp.saveText(
                book,
                chapter,
                "<p>text</p><img src=\"$valid\">"
            )
            validImage.parentFile?.mkdirs()
            validImage.writeText(arguments.getString("valid_svg"))
            val validSVGComplete = BookHelp.hasImageContent(book, chapter)
            JSONObject()
                .put("without_text", withoutText)
                .put("plain_text_complete", plainTextComplete)
                .put("text_file_present", BookHelp.hasContent(book, chapter))
                .put("missing_image_complete", missingImageComplete)
                .put("invalid_image_complete", invalidImageComplete)
                .put("invalid_image_deleted", invalidDeleted)
                .put("valid_svg_complete", validSVGComplete)
                .put("valid_svg_retained", validImage.exists())
        } finally {
            BookHelp.clearCache(book)
        }
    }

    private fun queueRangeStopResumeProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        val book = cacheProbeBook(arguments)
        val model = CacheBook.CacheBookModel(source, book)
        return try {
            model.addDownload(
                arguments.getInt("first_start"),
                arguments.getInt("first_end")
            )
            model.addDownload(
                arguments.getInt("second_start"),
                arguments.getInt("second_end")
            )
            val beforeStop = cacheModelState(model)
            val registeredBeforeStop =
                CacheBook.cacheBookMap[book.bookUrl] === model
            model.stop()
            val afterStop = cacheModelState(model)
            val registeredAfterStop =
                CacheBook.cacheBookMap[book.bookUrl] === model
            model.addDownload(
                arguments.getInt("resume_index"),
                arguments.getInt("resume_index")
            )
            JSONObject()
                .put("before_stop", beforeStop)
                .put("registered_before_stop", registeredBeforeStop)
                .put("after_stop", afterStop)
                .put("registered_after_stop", registeredAfterStop)
                .put("after_resume", cacheModelState(model))
        } finally {
            resetCacheBookState()
        }
    }

    private fun retryBudgetProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        return try {
            val ordinaryBook = cacheProbeBook(arguments)
            val ordinaryChapter = cacheProbeChapter(
                arguments,
                ordinaryBook,
                arguments.getInt("chapter_index")
            )
            val ordinaryModel = CacheBook.CacheBookModel(
                source,
                ordinaryBook
            )
            ordinaryModel.addDownload(
                ordinaryChapter.index,
                ordinaryChapter.index
            )
            val attempts = JSONArray()
            repeat(3) {
                beginCacheAttempt(ordinaryModel, ordinaryChapter.index)
                invokeCacheModel(
                    ordinaryModel,
                    "onPreError",
                    ordinaryChapter,
                    IOException("ordinary-${it + 1}")
                )
                val waitingDuringBackoff = cacheModelBoolean(
                    ordinaryModel,
                    "waitingRetry"
                )
                invokeCacheModel(
                    ordinaryModel,
                    "onPostError",
                    ordinaryChapter,
                    IOException("ordinary-${it + 1}")
                )
                attempts.put(
                    JSONObject()
                        .put("attempt", it + 1)
                        .put(
                            "error_count",
                            CacheBook.errorDownloadMap[
                                ordinaryChapter.primaryStr()
                            ] ?: 0
                        )
                        .put(
                            "waiting_during_backoff",
                            waitingDuringBackoff
                        )
                        .put(
                            "requeued",
                            cacheModelIndices(
                                ordinaryModel,
                                "waitDownloadSet"
                            ).contains(ordinaryChapter.index)
                        )
                )
            }

            val concurrentBook = ordinaryBook.copy(
                bookUrl = ordinaryBook.bookUrl + "/concurrent"
            )
            val concurrentChapter = ordinaryChapter.copy(
                bookUrl = concurrentBook.bookUrl,
                url = ordinaryChapter.url + "/concurrent",
                index = arguments.getInt("concurrent_index")
            )
            val concurrentModel = CacheBook.CacheBookModel(
                source,
                concurrentBook
            )
            concurrentModel.addDownload(
                concurrentChapter.index,
                concurrentChapter.index
            )
            beginCacheAttempt(concurrentModel, concurrentChapter.index)
            val concurrentError = ConcurrentException("busy", 1)
            invokeCacheModel(
                concurrentModel,
                "onPreError",
                concurrentChapter,
                concurrentError
            )
            invokeCacheModel(
                concurrentModel,
                "onPostError",
                concurrentChapter,
                concurrentError
            )

            val stoppedBook = ordinaryBook.copy(
                bookUrl = ordinaryBook.bookUrl + "/stopped"
            )
            val stoppedChapter = ordinaryChapter.copy(
                bookUrl = stoppedBook.bookUrl,
                url = ordinaryChapter.url + "/stopped",
                index = arguments.getInt("stopped_index")
            )
            val stoppedModel = CacheBook.CacheBookModel(source, stoppedBook)
            stoppedModel.addDownload(
                stoppedChapter.index,
                stoppedChapter.index
            )
            beginCacheAttempt(stoppedModel, stoppedChapter.index)
            val stoppedError = IOException("stopped")
            invokeCacheModel(
                stoppedModel,
                "onPreError",
                stoppedChapter,
                stoppedError
            )
            stoppedModel.stop()
            invokeCacheModel(
                stoppedModel,
                "onPostError",
                stoppedChapter,
                stoppedError
            )

            JSONObject()
                .put("ordinary_attempts", attempts)
                .put(
                    "ordinary_is_stop_after_budget",
                    ordinaryModel.isStop()
                )
                .put(
                    "concurrent_error_count",
                    CacheBook.errorDownloadMap[
                        concurrentChapter.primaryStr()
                    ] ?: 0
                )
                .put(
                    "concurrent_requeued",
                    cacheModelIndices(
                        concurrentModel,
                        "waitDownloadSet"
                    ).contains(concurrentChapter.index)
                )
                .put(
                    "stopped_error_count",
                    CacheBook.errorDownloadMap[
                        stoppedChapter.primaryStr()
                    ] ?: 0
                )
                .put(
                    "stopped_requeued",
                    cacheModelIndices(
                        stoppedModel,
                        "waitDownloadSet"
                    ).contains(stoppedChapter.index)
                )
                .put("stopped_is_stop", stoppedModel.isStop())
        } finally {
            resetCacheBookState()
        }
    }

    private fun successCancelProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        return try {
            val book = cacheProbeBook(arguments)
            val baseChapter = cacheProbeChapter(arguments, book)
            val successChapter = baseChapter.copy(
                index = arguments.getInt("success_index")
            )
            val successModel = CacheBook.CacheBookModel(source, book)
            successModel.addDownload(
                successChapter.index,
                successChapter.index
            )
            beginCacheAttempt(successModel, successChapter.index)
            CacheBook.errorDownloadMap[successChapter.primaryStr()] = 2
            invokeCacheModel(successModel, "onSuccess", successChapter)

            val cancelBook = book.copy(bookUrl = book.bookUrl + "/cancel")
            val cancelChapter = baseChapter.copy(
                bookUrl = cancelBook.bookUrl,
                url = baseChapter.url + "/cancel",
                index = arguments.getInt("cancel_index")
            )
            val cancelModel = CacheBook.CacheBookModel(source, cancelBook)
            cancelModel.addDownload(
                cancelChapter.index,
                cancelChapter.index
            )
            beginCacheAttempt(cancelModel, cancelChapter.index)
            invokeCacheModel(cancelModel, "onCancel", cancelChapter.index)

            val stoppedBook = book.copy(bookUrl = book.bookUrl + "/stopped")
            val stoppedChapter = baseChapter.copy(
                bookUrl = stoppedBook.bookUrl,
                url = baseChapter.url + "/stopped",
                index = arguments.getInt("stopped_cancel_index")
            )
            val stoppedModel = CacheBook.CacheBookModel(source, stoppedBook)
            stoppedModel.addDownload(
                stoppedChapter.index,
                stoppedChapter.index
            )
            beginCacheAttempt(stoppedModel, stoppedChapter.index)
            stoppedModel.stop()
            invokeCacheModel(stoppedModel, "onCancel", stoppedChapter.index)

            JSONObject()
                .put(
                    "success_recorded",
                    CacheBook.successDownloadSet.contains(
                        successChapter.primaryStr()
                    )
                )
                .put(
                    "success_removed_prior_error",
                    !CacheBook.errorDownloadMap.containsKey(
                        successChapter.primaryStr()
                    )
                )
                .put(
                    "success_removed_on_download",
                    !cacheModelIndices(
                        successModel,
                        "onDownloadSet"
                    ).contains(successChapter.index)
                )
                .put(
                    "cancel_requeued",
                    cacheModelIndices(
                        cancelModel,
                        "waitDownloadSet"
                    ).contains(cancelChapter.index)
                )
                .put(
                    "stopped_cancel_requeued",
                    cacheModelIndices(
                        stoppedModel,
                        "waitDownloadSet"
                    ).contains(stoppedChapter.index)
                )
        } finally {
            resetCacheBookState()
        }
    }

    private fun registryCleanupProjection(
        arguments: JSONObject
    ): JSONObject {
        resetCacheBookState()
        val book = cacheProbeBook(arguments)
        val model = CacheBook.getOrCreate(source, book)
        val index = arguments.getInt("chapter_index")
        return try {
            model.addDownload(index, index)
            invokeCacheModel(model, "onFinally")
            val retainedWithWait =
                CacheBook.cacheBookMap[book.bookUrl] === model
            cacheModelIndices(model, "waitDownloadSet").clear()
            cacheModelIndices(model, "onDownloadSet").clear()
            setCacheModelBoolean(model, "waitingRetry", true)
            val isStopWithOnlyWaitingRetry = model.isStop()
            invokeCacheModel(model, "onFinally")
            JSONObject()
                .put("registered_initially", true)
                .put("registry_retained_with_wait", retainedWithWait)
                .put(
                    "is_stop_with_only_waiting_retry",
                    isStopWithOnlyWaitingRetry
                )
                .put(
                    "registry_removed_with_only_waiting_retry",
                    !CacheBook.cacheBookMap.containsKey(book.bookUrl)
                )
        } finally {
            resetCacheBookState()
        }
    }

    private fun cacheProbeBook(arguments: JSONObject): Book = Book(
        bookUrl = arguments.getString("book_url"),
        origin = source.bookSourceUrl,
        originName = source.bookSourceName,
        name = arguments.getString("book_name")
    )

    private fun cacheProbeChapter(
        arguments: JSONObject,
        book: Book,
        index: Int = arguments.optInt("chapter_index", 0)
    ): BookChapter = BookChapter(
        url = arguments.optString(
            "chapter_url",
            "/chapter/$index"
        ),
        title = arguments.optString(
            "chapter_title",
            "Chapter $index"
        ),
        bookUrl = book.bookUrl,
        index = index
    )

    private fun cacheModelState(
        model: CacheBook.CacheBookModel
    ): JSONObject = JSONObject()
        .put(
            "wait_indices",
            JSONArray(
                cacheModelIndices(model, "waitDownloadSet").toList()
            )
        )
        .put(
            "on_download_indices",
            JSONArray(
                cacheModelIndices(model, "onDownloadSet").toList()
            )
        )
        .put("wait_count", model.waitCount)
        .put("on_download_count", model.onDownloadCount)
        .put("is_run", model.isRun())
        .put("is_stop", model.isStop())

    @Suppress("UNCHECKED_CAST")
    private fun cacheModelIndices(
        model: CacheBook.CacheBookModel,
        name: String
    ): MutableSet<Int> = CacheBook.CacheBookModel::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .get(model) as MutableSet<Int>

    private fun cacheModelBoolean(
        model: CacheBook.CacheBookModel,
        name: String
    ): Boolean = CacheBook.CacheBookModel::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .getBoolean(model)

    private fun setCacheModelBoolean(
        model: CacheBook.CacheBookModel,
        name: String,
        value: Boolean
    ) {
        CacheBook.CacheBookModel::class.java
            .getDeclaredField(name)
            .apply { isAccessible = true }
            .setBoolean(model, value)
    }

    private fun beginCacheAttempt(
        model: CacheBook.CacheBookModel,
        index: Int
    ) {
        cacheModelIndices(model, "waitDownloadSet").remove(index)
        cacheModelIndices(model, "onDownloadSet").add(index)
    }

    private fun invokeCacheModel(
        model: CacheBook.CacheBookModel,
        name: String,
        vararg arguments: Any?
    ): Any? {
        val method = CacheBook.CacheBookModel::class.java.declaredMethods
            .single {
                it.name == name &&
                    it.parameterTypes.size == arguments.size
            }
            .apply { isAccessible = true }
        return try {
            method.invoke(model, *arguments)
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun resetCacheBookState() {
        CacheBook.cacheBookMap.clear()
        CacheBook.clear()
    }

    private fun ruleBackendDispatchProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "html_prefix_dispatch" -> htmlPrefixDispatchProjection(arguments)
        "json_content_dispatch" -> jsonContentDispatchProjection(arguments)
        "javascript_dispatch" -> javascriptDispatchProjection(arguments)
        "regex_stickiness" -> regexStickinessProjection(arguments)
        "parser_cache_lifecycle" -> parserCacheProjection(arguments)
        "native_object_access" -> nativeObjectProjection(arguments)
        "null_content" -> nullContentProjection()
        "foreign_content_isolation" ->
            foreignContentIsolationProjection(arguments)
        else -> error("Unsupported rule backend mode: $mode")
    }

    private fun ruleCombinationProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "string_and_list" -> stringAndListProjection(arguments)
        "scalar_matrix" -> scalarCoercionProjection(arguments)
        "element_matrix" -> elementConsumerProjection(arguments)
        "sequential_chain" -> sequentialRuleProjection(arguments)
        "url_list" -> urlListProjection(arguments)
        "empty_matrix" -> emptyRuleProjection(arguments)
        "exception_boundary" -> ruleExceptionProjection(arguments)
        else -> error("Unsupported rule combination mode: $mode")
    }

    private fun domSelectorProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "css_strings" -> cssStringProjection(arguments)
        "css_indexing" -> cssIndexProjection(arguments)
        "css_combinations" -> cssCombinationProjection(arguments)
        "css_url" -> cssURLProjection(arguments)
        "url_context" -> urlContextProjection(arguments)
        "css_failure" -> cssFailureProjection(arguments)
        "xpath_strings" -> xpathStringProjection(arguments)
        "xpath_nodes" -> xpathNodeProjection(arguments)
        "xpath_fragments" -> xpathFragmentProjection(arguments)
        "xpath_namespace_functions" ->
            xpathNamespaceFunctionProjection(arguments)
        "xpath_failure" -> xpathFailureProjection(arguments)
        else -> error("Unsupported DOM selector mode: $mode")
    }

    private fun jsonPathRegexProjection(
        arguments: JSONObject
    ): JSONObject = when (val mode = arguments.getString("mode")) {
        "jsonpath_matrix" -> jsonPathMatrixProjection(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )
        "jsonpath_object_input" -> jsonPathMatrixProjection(
            GSON.fromJson(
                arguments.getJSONObject("content_object").toString(),
                Any::class.java
            ),
            arguments.getJSONObject("rules")
        )
        "jsonpath_failure" -> jsonPathFailureProjection(arguments)
        "regex_capture" -> regexCaptureProjection(arguments)
        "regex_replacement" -> regexReplacementProjection(arguments)
        "regex_failure" -> regexFailureProjection(arguments)
        else -> error("Unsupported JSONPath/Regex mode: $mode")
    }

    private fun jsonPathMatrixProjection(
        content: Any,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        }
                    )
                    .put(
                        "element",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElement(rule)
                        }
                    )
                    .put(
                        "elements",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(rule)
                        }
                    )
            )
        }
    }

    private fun jsonPathFailureProjection(
        arguments: JSONObject
    ): JSONObject {
        val rules = JSONObject()
            .put("missing", arguments.getString("missing_rule"))
            .put("null", arguments.getString("null_rule"))
            .put("malformed", arguments.getString("malformed_rule"))
        return jsonPathMatrixProjection(
            arguments.getString("content"),
            rules
        )
    }

    private fun regexCaptureProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "element",
                            anyOutcome {
                                AnalyzeRule().setContent(content)
                                    .getElement(rule)
                            }
                        )
                        .put(
                            "elements",
                            anyOutcome {
                                AnalyzeRule().setContent(content)
                                    .getElements(rule)
                            }
                        )
                )
            }
        }
    }

    private fun regexReplacementProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "string",
                            stringOutcome {
                                AnalyzeRule().setContent(content)
                                    .getString(rule)
                            }
                        )
                        .put(
                            "list",
                            stringListOutcome {
                                AnalyzeRule().setContent(content)
                                    .getStringList(rule)
                            }
                        )
                )
            }
        }
    }

    private fun regexFailureProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val malformed = arguments.getString("malformed_capture_rule")
        val optional = arguments.getString("optional_single_rule")
        return JSONObject()
            .put(
                "malformed_capture",
                JSONObject()
                    .put(
                        "element",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElement(malformed)
                        }
                    )
                    .put(
                        "elements",
                        anyOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
            .put(
                "optional_single",
                anyOutcome {
                    AnalyzeRule().setContent(content)
                        .getElement(optional)
                }
            )
            .put(
                "invalid_replace_all",
                stringOutcome {
                    AnalyzeRule().setContent(content).getString(
                        arguments.getString("invalid_replace_all_rule")
                    )
                }
            )
            .put(
                "invalid_replace_first",
                stringOutcome {
                    AnalyzeRule().setContent(content).getString(
                        arguments.getString("invalid_replace_first_rule")
                    )
                }
            )
    }

    private fun anyOutcome(block: () -> Any?): JSONObject =
        runCatching(block).fold(
            onSuccess = { value ->
                JSONObject()
                    .put("completed", true)
                    .put("value", stableAny(value))
                    .put("exception_type", JSONObject.NULL)
            },
            onFailure = { error ->
                JSONObject()
                    .put("completed", false)
                    .put("value", JSONObject.NULL)
                    .put("exception_type", error.javaClass.name)
            }
        )

    private fun stableAny(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            value.keys
                .map { it.toString() }
                .sorted()
                .forEach { key ->
                    put(key, stableAny(value[key]))
                }
        }
        is Iterable<*> -> JSONArray().apply {
            value.forEach { item -> put(stableAny(item)) }
        }
        is Array<*> -> JSONArray().apply {
            value.forEach { item -> put(stableAny(item)) }
        }
        is String, is Number, is Boolean -> value
        else -> JSONObject()
            .put("type", value.javaClass.name)
            .put("rendered", value.toString())
            .put("json", GSON.toJson(value))
    }

    private fun cssStringProjection(arguments: JSONObject): JSONObject =
        stringRuleMatrix(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )

    private fun cssIndexProjection(arguments: JSONObject): JSONObject =
        stringRuleMatrix(
            arguments.getString("content"),
            arguments.getJSONObject("rules")
        )

    private fun cssCombinationProjection(
        arguments: JSONObject
    ): JSONObject = stringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun stringRuleMatrix(
        content: String,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content).getString(rule)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        )
                    )
            )
        }
    }

    private fun cssURLProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val redirectURL = arguments.getString("redirect_url")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                val rule = rules.getString(key)
                put(
                    key,
                    JSONObject()
                        .put(
                            "raw_string",
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        )
                        .put(
                            "absolute_string",
                            urlAnalyzer(content, redirectURL)
                                .getString(rule, isUrl = true)
                        )
                        .put(
                            "raw_list",
                            nullableStringList(
                                AnalyzeRule().setContent(content)
                                    .getStringList(rule)
                            )
                        )
                        .put(
                            "absolute_list",
                            nullableStringList(
                                urlAnalyzer(content, redirectURL)
                                    .getStringList(rule, isUrl = true)
                            )
                        )
                )
            }
        }
    }

    private fun urlContextProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule()
        val steps = arguments.getJSONArray("steps")
        return JSONObject().put(
            "steps",
            JSONArray().apply {
                for (index in 0 until steps.length()) {
                    val step = steps.getJSONObject(index)
                    if (step.has("content")) {
                        val baseURL = if (
                            step.has("base_url") &&
                            !step.isNull("base_url")
                        ) {
                            step.getString("base_url")
                        } else {
                            null
                        }
                        analyze.setContent(
                            step.getString("content"),
                            baseURL
                        )
                    }
                    if (step.has("set_base_url")) {
                        analyze.setBaseUrl(
                            if (step.isNull("set_base_url")) {
                                null
                            } else {
                                step.getString("set_base_url")
                            }
                        )
                    }
                    if (
                        step.has("redirect_url") &&
                        !step.isNull("redirect_url")
                    ) {
                        analyze.setRedirectUrl(
                            step.getString("redirect_url")
                        )
                    }
                    val rules = step.getJSONObject("rules")
                    put(
                        JSONObject()
                            .put("id", step.getString("id"))
                            .put(
                                "base_url",
                                nullable(analyze.baseUrl)
                            )
                            .put(
                                "redirect_url",
                                nullable(
                                    analyze.redirectUrl?.toString()
                                )
                            )
                            .put(
                                "values",
                                JSONObject().apply {
                                    rules.keys()
                                        .asSequence()
                                        .toList()
                                        .sorted()
                                        .forEach { key ->
                                            val rule = rules.getString(key)
                                            put(
                                                key,
                                                JSONObject()
                                                    .put(
                                                        "raw_string",
                                                        analyze.getString(rule)
                                                    )
                                                    .put(
                                                        "absolute_string",
                                                        analyze.getString(
                                                            rule,
                                                            isUrl = true
                                                        )
                                                    )
                                                    .put(
                                                        "raw_list",
                                                        nullableStringList(
                                                            analyze
                                                                .getStringList(
                                                                    rule
                                                                )
                                                        )
                                                    )
                                                    .put(
                                                        "absolute_list",
                                                        nullableStringList(
                                                            analyze
                                                                .getStringList(
                                                                    rule,
                                                                    isUrl = true
                                                                )
                                                        )
                                                    )
                                            )
                                        }
                                }
                            )
                    )
                }
            }
        )
    }

    private fun urlAnalyzer(
        content: String,
        redirectURL: String
    ): AnalyzeRule = AnalyzeRule()
        .setContent(content, redirectURL)
        .apply { setRedirectUrl(redirectURL) }

    private fun cssFailureProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        val missingElements = arguments.getString(
            "missing_elements_rule"
        )
        val malformed = arguments.getString("malformed_rule")
        return JSONObject()
            .put(
                "missing",
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content)
                            .getString(missing)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(missing)
                        )
                    )
                    .put(
                        "elements_count",
                        AnalyzeRule().setContent(content)
                            .getElements(missingElements).size
                    )
            )
            .put(
                "malformed",
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(malformed)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(malformed)
                        }
                    )
                    .put(
                        "elements",
                        elementOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
    }

    private fun xpathStringProjection(
        arguments: JSONObject
    ): JSONObject = outcomeStringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun xpathNodeProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().apply {
            val keys = rules.keys().asSequence().toList().sorted()
            keys.forEach { key ->
                put(
                    key,
                    elementProjection(
                        AnalyzeRule().setContent(content)
                            .getElements(rules.getString(key))
                    )
                )
            }
        }
    }

    private fun xpathFragmentProjection(
        arguments: JSONObject
    ): JSONObject {
        val rules = arguments.getJSONObject("rules")
        return JSONObject()
            .put(
                "td",
                stringRuleMatrix(
                    arguments.getString("td_fragment"),
                    JSONObject().put("value", rules.getString("td"))
                ).getJSONObject("value")
            )
            .put(
                "tr",
                stringRuleMatrix(
                    arguments.getString("tr_fragment"),
                    JSONObject().put("value", rules.getString("tr"))
                ).getJSONObject("value")
            )
            .put(
                "malformed",
                stringRuleMatrix(
                    arguments.getString("malformed_html"),
                    JSONObject()
                        .put("value", rules.getString("malformed"))
                ).getJSONObject("value")
            )
    }

    private fun xpathNamespaceFunctionProjection(
        arguments: JSONObject
    ): JSONObject = outcomeStringRuleMatrix(
        arguments.getString("content"),
        arguments.getJSONObject("rules")
    )

    private fun outcomeStringRuleMatrix(
        content: String,
        rules: JSONObject
    ): JSONObject = JSONObject().apply {
        val keys = rules.keys().asSequence().toList().sorted()
        keys.forEach { key ->
            val rule = rules.getString(key)
            put(
                key,
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(rule)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(rule)
                        }
                    )
            )
        }
    }

    private fun xpathFailureProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        val malformed = arguments.getString("malformed_rule")
        return JSONObject()
            .put(
                "missing",
                JSONObject()
                    .put(
                        "string",
                        AnalyzeRule().setContent(content)
                            .getString(missing)
                    )
                    .put(
                        "list",
                        nullableStringList(
                            AnalyzeRule().setContent(content)
                                .getStringList(missing)
                        )
                    )
                    .put(
                        "elements",
                        elementProjection(
                            AnalyzeRule().setContent(content)
                                .getElements(missing)
                        )
                    )
            )
            .put(
                "malformed",
                JSONObject()
                    .put(
                        "string",
                        stringOutcome {
                            AnalyzeRule().setContent(content)
                                .getString(malformed)
                        }
                    )
                    .put(
                        "list",
                        stringListOutcome {
                            AnalyzeRule().setContent(content)
                                .getStringList(malformed)
                        }
                    )
                    .put(
                        "elements",
                        elementOutcome {
                            AnalyzeRule().setContent(content)
                                .getElements(malformed)
                        }
                    )
            )
    }

    private fun stringOutcome(block: () -> String): JSONObject =
        runCatching(block).fold(
            onSuccess = { value ->
                JSONObject()
                    .put("completed", true)
                    .put("value", value)
                    .put("exception_type", JSONObject.NULL)
            },
            onFailure = { error ->
                JSONObject()
                    .put("completed", false)
                    .put("value", JSONObject.NULL)
                    .put("exception_type", error.javaClass.name)
            }
        )

    private fun stringListOutcome(
        block: () -> List<String>?
    ): JSONObject = runCatching(block).fold(
        onSuccess = { value ->
            JSONObject()
                .put("completed", true)
                .put("value", nullableStringList(value))
                .put("exception_type", JSONObject.NULL)
        },
        onFailure = { error ->
            JSONObject()
                .put("completed", false)
                .put("value", JSONObject.NULL)
                .put("exception_type", error.javaClass.name)
        }
    )

    private fun elementOutcome(
        block: () -> List<Any>
    ): JSONObject = runCatching(block).fold(
        onSuccess = { value ->
            JSONObject()
                .put("completed", true)
                .put("value", elementProjection(value))
                .put("exception_type", JSONObject.NULL)
        },
        onFailure = { error ->
            JSONObject()
                .put("completed", false)
                .put("value", JSONObject.NULL)
                .put("exception_type", error.javaClass.name)
        }
    )

    private fun elementProjection(values: List<Any>): JSONArray =
        JSONArray().apply {
            values.forEach { value ->
                put(
                    when (value) {
                        is Element -> JSONObject()
                            .put("kind", "jsoup_element")
                            .put("tag", value.tagName())
                            .put("text", value.text())
                            .put("rendered", value.outerHtml())
                        is JXNode -> JSONObject()
                            .put(
                                "kind",
                                if (value.isElement) {
                                    "xpath_element"
                                } else {
                                    "xpath_value"
                                }
                            )
                            .put(
                                "tag",
                                if (value.isElement) {
                                    value.asElement().tagName()
                                } else {
                                    JSONObject.NULL
                                }
                            )
                            .put("as_string", value.asString())
                            .put("rendered", value.toString())
                        else -> JSONObject()
                            .put("kind", value.javaClass.name)
                            .put("rendered", value.toString())
                    }
                )
            }
        }

    private fun stringAndListProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rule = arguments.getString("rule")
        return JSONObject()
            .put(
                "string",
                AnalyzeRule().setContent(content).getString(rule)
            )
            .put(
                "list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(rule)
                )
            )
    }

    private fun scalarCoercionProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val rules = arguments.getJSONObject("rules")
        return JSONObject().put(
            "values",
            JSONArray().apply {
                listOf("number", "boolean", "null", "string")
                    .forEach { label ->
                        val rule = rules.getString(label)
                        put(
                            JSONObject()
                                .put("label", label)
                                .put(
                                    "string",
                                    AnalyzeRule()
                                        .setContent(content)
                                        .getString(rule)
                                )
                                .put(
                                    "list",
                                    nullableStringList(
                                        AnalyzeRule()
                                            .setContent(content)
                                            .getStringList(rule)
                                    )
                                )
                        )
                    }
            }
        )
    }

    private fun elementConsumerProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        val objectValue = AnalyzeRule().setContent(content)
            .getElement(arguments.getString("object_rule"))
        val elementsValue = AnalyzeRule().setContent(content)
            .getElements(arguments.getString("elements_rule"))
        val scalarValue = AnalyzeRule().setContent(content)
            .getElement(arguments.getString("scalar_rule"))
        return JSONObject()
            .put("object_type", nullable(objectValue?.javaClass?.name))
            .put("object_json", GSON.toJson(objectValue))
            .put("elements_count", elementsValue.size)
            .put("elements_json", GSON.toJson(elementsValue))
            .put("scalar_type", nullable(scalarValue?.javaClass?.name))
            .put("scalar_json", GSON.toJson(scalarValue))
    }

    private fun sequentialRuleProjection(
        arguments: JSONObject
    ): JSONObject {
        val content = arguments.getString("content")
        return JSONObject()
            .put(
                "string",
                AnalyzeRule().setContent(content).getString(
                    arguments.getString("string_rule")
                )
            )
            .put(
                "list",
                nullableStringList(
                    AnalyzeRule().setContent(content).getStringList(
                        arguments.getString("list_rule")
                    )
                )
            )
    }

    private fun urlListProjection(arguments: JSONObject): JSONObject {
        val analyze = AnalyzeRule().setContent(
            arguments.getString("content")
        )
        analyze.setRedirectUrl(arguments.getString("redirect_url"))
        return JSONObject().put(
            "urls",
            nullableStringList(
                analyze.getStringList(
                    arguments.getString("rule"),
                    isUrl = true
                )
            )
        )
    }

    private fun emptyRuleProjection(arguments: JSONObject): JSONObject {
        val content = arguments.getString("content")
        val missing = arguments.getString("missing_rule")
        return JSONObject()
            .put(
                "empty_string",
                AnalyzeRule().setContent(content).getString(null)
            )
            .put(
                "empty_list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(null)
                )
            )
            .put(
                "empty_element",
                nullable(
                    AnalyzeRule().setContent(content)
                        .getElement("")?.toString()
                )
            )
            .put(
                "empty_elements_count",
                AnalyzeRule().setContent(content)
                    .getElements("").size
            )
            .put(
                "missing_string",
                AnalyzeRule().setContent(content).getString(missing)
            )
            .put(
                "missing_list",
                nullableStringList(
                    AnalyzeRule().setContent(content)
                        .getStringList(missing)
                )
            )
    }

    private fun ruleExceptionProjection(
        arguments: JSONObject
    ): JSONObject {
        var completed = false
        var value: String? = null
        var exceptionType: String? = null
        try {
            value = AnalyzeRule()
                .setContent(arguments.getString("content"))
                .getString(arguments.getString("rule"))
            completed = true
        } catch (error: Throwable) {
            exceptionType = error.javaClass.name
        }
        return JSONObject()
            .put("completed", completed)
            .put("value", nullable(value))
            .put("exception_type", nullable(exceptionType))
    }

    private fun nullableStringList(value: List<String>?): Any =
        value?.let(::JSONArray) ?: JSONObject.NULL

    private fun htmlPrefixDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val ruleKeys = listOf(
            "default_rule",
            "css_rule",
            "escaped_default_rule",
            "xpath_rule",
            "leading_xpath_rule"
        )
        return JSONObject()
            .put(
                "modes",
                JSONObject().apply {
                    ruleKeys.forEach { key ->
                        put(
                            key.removeSuffix("_rule"),
                            sourceRuleProjection(
                                analyze,
                                arguments.getString(key)
                            )
                        )
                    }
                }
            )
            .put(
                "default_value",
                analyze.getString(arguments.getString("default_rule"))
            )
            .put(
                "css_value",
                analyze.getString(arguments.getString("css_rule"))
            )
            .put(
                "escaped_default_value",
                analyze.getString(
                    arguments.getString("escaped_default_rule")
                )
            )
            .put(
                "xpath_value",
                analyze.getString(arguments.getString("xpath_rule"))
            )
            .put(
                "leading_xpath_value",
                analyze.getString(
                    arguments.getString("leading_xpath_rule")
                )
            )
    }

    private fun jsonContentDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val ruleKeys = listOf(
            "auto_rule",
            "signature_rule",
            "explicit_rule",
            "list_rule"
        )
        return JSONObject()
            .put(
                "modes",
                JSONObject().apply {
                    ruleKeys.forEach { key ->
                        put(
                            key.removeSuffix("_rule"),
                            sourceRuleProjection(
                                analyze,
                                arguments.getString(key)
                            )
                        )
                    }
                }
            )
            .put(
                "auto_value",
                analyze.getString(arguments.getString("auto_rule"))
            )
            .put(
                "signature_value",
                analyze.getString(arguments.getString("signature_rule"))
            )
            .put(
                "explicit_value",
                analyze.getString(arguments.getString("explicit_rule"))
            )
            .put(
                "list_values",
                JSONArray(
                    analyze.getStringList(
                        arguments.getString("list_rule")
                    ) ?: emptyList<String>()
                )
            )
    }

    private fun javascriptDispatchProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val embeddedRule = arguments.getString("embedded_rule")
        val tailRule = arguments.getString("tail_rule")
        return JSONObject()
            .put("embedded_mode", sourceRuleProjection(analyze, embeddedRule))
            .put("tail_mode", sourceRuleProjection(analyze, tailRule))
            .put("embedded_value", analyze.getString(embeddedRule))
            .put("tail_value", analyze.getString(tailRule))
    }

    private fun regexStickinessProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(arguments.getString("content"))
        val activationRule = arguments.getString("activation_rule")
        val followupRule = arguments.getString("followup_rule")
        val activationMode = sourceRuleProjection(
            analyze,
            activationRule,
            allInOne = true
        )
        val activationValues = analyze.getElements(activationRule)
        val followupMode = sourceRuleProjection(
            analyze,
            followupRule,
            allInOne = true
        )
        val followupValues = analyze.getElements(followupRule)
        return JSONObject()
            .put("activation_mode", activationMode)
            .put("followup_mode", followupMode)
            .put(
                "activation_values",
                JSONArray(GSON.toJson(activationValues))
            )
            .put(
                "followup_values",
                JSONArray(GSON.toJson(followupValues))
            )
    }

    private fun parserCacheProjection(arguments: JSONObject): JSONObject =
        JSONObject()
            .put(
                "jsoup",
                parserCacheLifecycle(
                    arguments.getString("html_first"),
                    arguments.getString("html_second"),
                    arguments.getString("css_rule"),
                    "analyzeByJSoup"
                )
            )
            .put(
                "xpath",
                parserCacheLifecycle(
                    arguments.getString("html_first"),
                    arguments.getString("html_second"),
                    arguments.getString("xpath_rule"),
                    "analyzeByXPath"
                )
            )
            .put(
                "jsonpath",
                parserCacheLifecycle(
                    arguments.getString("json_first"),
                    arguments.getString("json_second"),
                    arguments.getString("json_rule"),
                    "analyzeByJSonPath"
                )
            )

    private fun parserCacheLifecycle(
        firstContent: String,
        secondContent: String,
        rule: String,
        fieldName: String
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(firstContent)
        val firstValue = analyze.getString(rule)
        val firstParser = analyzeRuleField(analyze, fieldName)
        val repeatedValue = analyze.getString(rule)
        val repeatedParser = analyzeRuleField(analyze, fieldName)
        analyze.setContent(secondContent)
        val secondValue = analyze.getString(rule)
        val secondParser = analyzeRuleField(analyze, fieldName)
        return JSONObject()
            .put("first_value", firstValue)
            .put("repeated_value", repeatedValue)
            .put("second_value", secondValue)
            .put("same_instance_for_same_content", firstParser === repeatedParser)
            .put("replaced_after_set_content", firstParser !== secondParser)
    }

    private fun nativeObjectProjection(arguments: JSONObject): JSONObject {
        val nativeObject = requireNotNull(
            AnalyzeRule().evalJS(arguments.getString("script"))
        )
        val analyze = AnalyzeRule().setContent(nativeObject)
        val key = arguments.getString("key")
        return JSONObject()
            .put("runtime_type", nativeObject.javaClass.name)
            .put("rule_mode", sourceRuleProjection(analyze, key))
            .put("direct_value", analyze.getString(key))
    }

    private fun nullContentProjection(): JSONObject {
        var accepted = true
        var exceptionType: String? = null
        try {
            AnalyzeRule().setContent(null)
        } catch (error: Throwable) {
            accepted = false
            exceptionType = error.javaClass.name
        }
        return JSONObject()
            .put("accepted", accepted)
            .put("exception_type", nullable(exceptionType))
    }

    private fun foreignContentIsolationProjection(
        arguments: JSONObject
    ): JSONObject {
        val analyze = AnalyzeRule().setContent(
            arguments.getString("current_content")
        )
        val rule = arguments.getString("rule")
        val currentBefore = analyze.getString(rule)
        val parserBefore = analyzeRuleField(analyze, "analyzeByJSoup")
        val foreignValue = analyze.getString(
            rule,
            arguments.getString("foreign_content")
        )
        val parserAfterForeign = analyzeRuleField(analyze, "analyzeByJSoup")
        val currentAfter = analyze.getString(rule)
        val parserAfterCurrent = analyzeRuleField(analyze, "analyzeByJSoup")
        return JSONObject()
            .put("current_before", currentBefore)
            .put("foreign_value", foreignValue)
            .put("current_after", currentAfter)
            .put(
                "cache_preserved_after_foreign",
                parserBefore === parserAfterForeign
            )
            .put(
                "cache_reused_after_foreign",
                parserBefore === parserAfterCurrent
            )
    }

    private fun sourceRuleProjection(
        analyze: AnalyzeRule,
        rule: String,
        allInOne: Boolean = false
    ): JSONArray = JSONArray().apply {
        analyze.splitSourceRule(rule, allInOne).forEach { sourceRule ->
            put(
                JSONObject()
                    .put("mode", sourceRule.mode.name.lowercase())
                    .put("rule", sourceRule.rule)
            )
        }
    }

    private fun analyzeRuleField(
        analyze: AnalyzeRule,
        name: String
    ): Any? = AnalyzeRule::class.java
        .getDeclaredField(name)
        .apply { isAccessible = true }
        .get(analyze)

    private suspend fun ruleVariableScopeProjection(
        value: JSONObject
    ): JSONObject {
        val arguments = value.getJSONObject("arguments")
        return when (val mode = arguments.getString("mode")) {
            "storage_boundary" -> ruleDataStorageBoundary(arguments)
            "analyze_rule_priority" ->
                analyzeRulePriorityProjection(value, arguments)
            "analyze_url_priority" ->
                analyzeURLPriorityProjection(value, arguments)
            "rule_script_propagation" ->
                ruleScriptPropagationProjection(arguments)
            "url_script_propagation" ->
                urlScriptPropagationProjection(arguments)
            "failure_mutation" ->
                failureMutationProjection(arguments)
            "independent_contexts" ->
                independentContextProjection(arguments)
            else -> error("Unsupported rule variable mode: $mode")
        }
    }

    private fun ruleDataStorageBoundary(
        arguments: JSONObject
    ): JSONObject {
        val data = RuleData()
        val key = arguments.getString("key")
        val smallLength = arguments.getInt("small_length")
        val largeLength = arguments.getInt("large_length")
        val smallAccepted = data.putVariable(
            key,
            "s".repeat(smallLength)
        )
        val observedSmallLength = data.getVariable(key).length
        val largeAccepted = data.putVariable(
            key,
            "l".repeat(largeLength)
        )
        val observedLargeLength = data.getVariable(key).length
        val removalAccepted = data.putVariable(key, null)
        return JSONObject()
            .put("small_write_returned", smallAccepted)
            .put("small_value_length", observedSmallLength)
            .put("large_write_returned", largeAccepted)
            .put("large_value_length", observedLargeLength)
            .put("removal_returned", removalAccepted)
            .put("value_after_removal", data.getVariable(key))
            .put(
                "serialized_after_removal",
                nullable(data.getVariable())
            )
    }

    private fun analyzeRulePriorityProjection(
        value: JSONObject,
        arguments: JSONObject
    ): JSONObject {
        val id = value.getString("id")
        val key = arguments.getString("key")
        val caseSource = variableCaseSource(id)
        val book = variableBook(arguments, id)
        val chapter = variableChapter(arguments, book)
        caseSource.put(key, arguments.getString("source_value"))
        caseSource.put("source-only", "source-only-value")
        book.putVariable(key, arguments.getString("book_value"))
        book.putVariable("empty-fallback", "book-fallback")
        book.putVariable("bookName", "variable-book-name")
        chapter.putVariable(key, arguments.getString("chapter_value"))
        chapter.putVariable("empty-fallback", "")
        chapter.putVariable("title", "variable-chapter-title")
        val analyze = AnalyzeRule(book, caseSource)
        analyze.chapter = chapter
        val writeReturn = analyze.put("written", "via-analyze-rule")
        return JSONObject()
            .put("priority_value", analyze.get(key))
            .put("empty_chapter_falls_back", analyze.get("empty-fallback"))
            .put("source_fallback", analyze.get("source-only"))
            .put("book_name", analyze.get("bookName"))
            .put("chapter_title", analyze.get("title"))
            .put("write_return", writeReturn)
            .put("chapter_write", chapter.getVariable("written"))
            .put("book_write", book.getVariable("written"))
            .put("source_write", caseSource.get("written"))
    }

    private fun analyzeURLPriorityProjection(
        value: JSONObject,
        arguments: JSONObject
    ): JSONObject {
        val id = value.getString("id")
        val key = arguments.getString("key")
        val caseSource = variableCaseSource(id)
        val book = variableBook(arguments, id)
        val chapter = variableChapter(arguments, book)
        caseSource.put(key, arguments.getString("source_value"))
        caseSource.put("source-only", "source-only-value")
        book.putVariable(key, arguments.getString("book_value"))
        book.putVariable("empty-fallback", "book-fallback")
        book.putVariable("bookName", "variable-book-name")
        chapter.putVariable(key, arguments.getString("chapter_value"))
        chapter.putVariable("empty-fallback", "")
        chapter.putVariable("title", "variable-chapter-title")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin/variables/priority",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            ruleData = book,
            chapter = chapter
        )
        val writeReturn = analyze.put("written", "via-analyze-url")
        return JSONObject()
            .put("priority_value", analyze.get(key))
            .put("empty_chapter_falls_back", analyze.get("empty-fallback"))
            .put("source_fallback", analyze.get("source-only"))
            .put("book_name", analyze.get("bookName"))
            .put("chapter_title", analyze.get("title"))
            .put("write_return", writeReturn)
            .put("chapter_write", chapter.getVariable("written"))
            .put("book_write", book.getVariable("written"))
            .put("source_write", caseSource.get("written"))
    }

    private fun ruleScriptPropagationProjection(
        arguments: JSONObject
    ): JSONObject {
        val key = arguments.getString("key")
        val value = arguments.getString("value")
        val shared = RuleData()
        val scriptValue = AnalyzeRule(shared).evalJS(
            "java.put(${JSONObject.quote(key)},${JSONObject.quote(value)});" +
                "java.get(${JSONObject.quote(key)})"
        )
        val later = AnalyzeRule(shared)
        val isolated = AnalyzeRule(RuleData())
        return JSONObject()
            .put("script_value", nullable(scriptValue?.toString()))
            .put("later_field_value", later.get(key))
            .put("isolated_field_value", isolated.get(key))
            .put("serialized_variables", nullable(shared.getVariable()))
    }

    private fun urlScriptPropagationProjection(
        arguments: JSONObject
    ): JSONObject {
        val key = arguments.getString("key")
        val value = arguments.getString("value")
        val quotedKey = JSONObject.quote(key)
        val shared = RuleData()
        val first = AnalyzeUrl(
            mUrl =
                "<js>java.put($quotedKey,${JSONObject.quote(value)});" +
                    "${JSONObject.quote("$deviceOrigin/variables/url-written")}" +
                    "</js>",
            baseUrl = source.bookSourceUrl,
            ruleData = shared
        )
        val second = AnalyzeUrl(
            mUrl =
                "$deviceOrigin/variables/url-read/" +
                    "{{java.get($quotedKey)}}",
            baseUrl = source.bookSourceUrl,
            ruleData = shared
        )
        return JSONObject()
            .put("first_url", logical(first.url))
            .put("second_url", logical(second.url))
            .put("stored_value", shared.getVariable(key))
    }

    private fun failureMutationProjection(
        arguments: JSONObject
    ): JSONObject {
        val shared = RuleData()
        val ruleKey = arguments.getString("rule_key")
        val urlKey = arguments.getString("url_key")
        val value = arguments.getString("value")
        var ruleThrew = false
        try {
            AnalyzeRule(shared).evalJS(
                "java.put(${JSONObject.quote(ruleKey)}," +
                    "${JSONObject.quote(value)});throw 'rule-failure'"
            )
        } catch (_: Throwable) {
            ruleThrew = true
        }
        var urlThrew = false
        try {
            AnalyzeUrl(
                mUrl =
                    "<js>java.put(${JSONObject.quote(urlKey)}," +
                        "${JSONObject.quote(value)});throw 'url-failure'</js>",
                baseUrl = source.bookSourceUrl,
                ruleData = shared
            )
        } catch (_: Throwable) {
            urlThrew = true
        }
        return JSONObject()
            .put("rule_threw", ruleThrew)
            .put("rule_value_after_failure", shared.getVariable(ruleKey))
            .put("url_threw", urlThrew)
            .put("url_value_after_failure", shared.getVariable(urlKey))
    }

    private suspend fun independentContextProjection(
        arguments: JSONObject
    ): JSONObject = coroutineScope {
        val key = arguments.getString("key")
        val leftData = RuleData()
        val rightData = RuleData()
        val left = async {
            val analyze = AnalyzeRule(leftData)
            analyze.put(key, arguments.getString("left_value"))
            analyze.get(key)
        }
        val right = async {
            val analyze = AnalyzeRule(rightData)
            analyze.put(key, arguments.getString("right_value"))
            analyze.get(key)
        }
        JSONObject()
            .put("left_value", left.await())
            .put("right_value", right.await())
            .put("left_storage", leftData.getVariable(key))
            .put("right_storage", rightData.getVariable(key))
            .put(
                "storage_identity_distinct",
                leftData.variableMap !== rightData.variableMap
            )
    }

    private fun variableCaseSource(id: String): BookSource =
        GSON.fromJson(sourceJson, BookSource::class.java).apply {
            bookSourceUrl = "$deviceOrigin/variable-source/$id"
            bookSourceName = "Variable $id"
        }

    private fun variableBook(
        arguments: JSONObject,
        id: String
    ): Book = Book(
        bookUrl = "$deviceOrigin/variables/book/$id",
        origin = source.bookSourceUrl,
        originName = source.bookSourceName,
        name = arguments.getString("book_name")
    )

    private fun variableChapter(
        arguments: JSONObject,
        book: Book
    ): BookChapter = BookChapter(
        url = "$deviceOrigin/variables/chapter",
        title = arguments.getString("chapter_title"),
        bookUrl = book.bookUrl
    )

    private suspend fun dynamicWebProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        clearDynamicCookieState()
        val arguments = value.getJSONObject("arguments")
        val requestValue = value.getJSONObject("request")
        val method = requestValue.getString("method")
        val target = requestValue.getString("target")
        val optionUseWebView =
            arguments.getBoolean("option_use_webview")
        val invocationUseWebView =
            arguments.getBoolean("invocation_use_webview")
        val option = JSONObject().put("webView", optionUseWebView)
        if (!arguments.isNull("web_js")) {
            option.put("webJs", arguments.getString("web_js"))
        }
        if (method == "POST") {
            option
                .put("method", "POST")
                .put("body", arguments.getString("body"))
        } else {
            require(method == "GET")
        }
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target,$option",
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        val sourceCookieBefore = CookieStore.getCookie(deviceOrigin)
        val webCookieBefore = currentWebCookie(deviceOrigin)
        val sourceRegex =
            if (arguments.isNull("source_regex")) {
                null
            } else {
                arguments.getString("source_regex")
            }
        val response = withTimeout(15_000) {
            analyze.getStrResponseAwait(
                sourceRegex = sourceRegex,
                useWebView = invocationUseWebView
            )
        }
        return Pair(
            analyzedRequest(analyze),
            JSONObject()
                .put("configured_use_webview", optionUseWebView)
                .put("invocation_use_webview", invocationUseWebView)
                .put(
                    "configured_web_js",
                    nullable(
                        if (arguments.isNull("web_js")) {
                            null
                        } else {
                            arguments.getString("web_js")
                        }
                    )
                )
                .put("source_regex", nullable(sourceRegex))
                .put(
                    "body",
                    nullable(
                        response.body?.replace(
                            deviceOrigin,
                            logicalOrigin
                        )
                    )
                )
                .put("final_url", logical(response.url))
                .put("source_cookie_before", sourceCookieBefore)
                .put(
                    "source_cookie_after",
                    CookieStore.getCookie(deviceOrigin)
                )
                .put("web_cookie_before", nullable(webCookieBefore))
                .put(
                    "web_cookie_after",
                    nullable(currentWebCookie(deviceOrigin))
                )
        )
    }

    private fun clearDynamicCookieState() {
        resetCookieState(deviceOrigin)
        val latch = CountDownLatch(1)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            android.webkit.CookieManager
                .getInstance()
                .removeAllCookies {
                    latch.countDown()
                }
        }
        require(latch.await(5, TimeUnit.SECONDS)) {
            "Timed out clearing WebView cookies"
        }
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            android.webkit.CookieManager.getInstance().flush()
        }
    }

    private fun currentWebCookie(url: String): String? {
        var value: String? = null
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            value = android.webkit.CookieManager
                .getInstance()
                .getCookie(url)
        }
        return value
    }

    private fun dynamicWebFallbackRequest(value: JSONObject): JSONObject {
        val requestValue = value.getJSONObject("request")
        val method = requestValue.getString("method")
        return JSONObject()
            .put("method", method)
            .put(
                "url",
                logical(deviceOrigin + requestValue.getString("target"))
            )
            .put(
                "headers",
                controlledHeaders(
                    listOf("X-Source" to "dynamic-web")
                )
            )
            .put(
                "body",
                if (method == "POST") {
                    value.getJSONObject("arguments").getString("body")
                } else {
                    JSONObject.NULL
                }
            )
            .put("timeout_ms", JSONObject.NULL)
    }

    private suspend fun cookieSessionProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        return when (val mode = arguments.getString("mode")) {
            "parser" -> Pair(
                cookieHelperRequest(value),
                JSONObject()
                    .put(
                        "entries",
                        cookieEntries(
                            CookieStore.cookieToMap(
                                arguments.getString("cookie")
                            )
                        )
                    )
                    .put(
                        "serialized",
                        nullable(
                            CookieStore.mapToCookie(
                                CookieStore.cookieToMap(
                                    arguments.getString("cookie")
                                )
                            )
                        )
                    )
            )

            "store_merge" -> {
                resetCookieState(deviceOrigin)
                seedCookieState(arguments)
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                )
            }

            "analyze_request" -> cookieAnalyzeProjection(value)

            "response_classification" -> {
                resetCookieState(deviceOrigin)
                saveSetCookies(
                    deviceOrigin,
                    jsonStrings(arguments.getJSONArray("set_cookies"))
                )
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                )
            }

            "metadata_flattening" -> {
                resetCookieState(deviceOrigin)
                saveSetCookies(
                    deviceOrigin,
                    jsonStrings(arguments.getJSONArray("set_cookies"))
                )
                val loadURL =
                    deviceOrigin + arguments.getString("load_target")
                val loaded = CookieManager.loadRequest(
                    Request.Builder().url(loadURL).build()
                )
                Pair(
                    cookieHelperRequest(value),
                    cookieState(deviceOrigin)
                        .put("load_url", logical(loadURL))
                        .put(
                            "loaded_cookie",
                            nullable(loaded.header("Cookie"))
                        )
                )
            }

            "redirect" -> cookieRedirectProjection(value)

            "removal" -> {
                resetCookieState(deviceOrigin)
                seedCookieState(arguments)
                val before = cookieState(deviceOrigin)
                CookieManager.removeCookie(
                    deviceOrigin,
                    arguments.getString("remove_key")
                )
                val afterKey = cookieState(deviceOrigin)
                CookieStore.removeCookie(deviceOrigin)
                val afterDomain = cookieState(deviceOrigin)
                Pair(
                    cookieHelperRequest(value),
                    JSONObject()
                        .put("before", before)
                        .put("after_key_removal", afterKey)
                        .put("after_domain_removal", afterDomain)
                )
            }

            "domain_normalization" -> {
                val writeURL = arguments.getString("write_url")
                val sameSiteURL = arguments.getString("same_site_url")
                val otherSiteURL = arguments.getString("other_site_url")
                resetCookieState(writeURL)
                resetCookieState(otherSiteURL)
                CookieStore.setCookie(
                    writeURL,
                    arguments.getString("cookie")
                )
                val result = JSONObject()
                    .put(
                        "write_domain",
                        NetworkUtils.getSubDomain(writeURL)
                    )
                    .put(
                        "same_site_domain",
                        NetworkUtils.getSubDomain(sameSiteURL)
                    )
                    .put(
                        "other_site_domain",
                        NetworkUtils.getSubDomain(otherSiteURL)
                    )
                    .put(
                        "same_site_cookie",
                        CookieStore.getCookie(sameSiteURL)
                    )
                    .put(
                        "other_site_cookie",
                        CookieStore.getCookie(otherSiteURL)
                    )
                resetCookieState(writeURL)
                resetCookieState(otherSiteURL)
                Pair(cookieHelperRequest(value), result)
            }

            else -> error("Unsupported cookie session mode: $mode")
        }
    }

    private suspend fun cookieAnalyzeProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        resetCookieState(deviceOrigin)
        seedCookieState(arguments)
        val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
        caseSource.enabledCookieJar =
            arguments.getBoolean("enabled_cookie_jar")
        val headers = HashMap(
            caseSource.getHeaderMap(true) ?: emptyMap()
        )
        headers["Cookie"] = arguments.getString("explicit_cookie")
        val target = value.getJSONObject("request").getString("target")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            headerMapF = headers
        )
        val initialCookie = analyze.headerMap["Cookie"]
        val response = analyze.getStrResponseAwait(useWebView = false)
        val networkRequest =
            response.raw.networkResponse?.request ?: response.raw.request
        return Pair(
            analyzedRequest(analyze),
            cookieState(deviceOrigin)
                .put(
                    "enabled_cookie_jar",
                    caseSource.enabledCookieJar == true
                )
                .put("initial_cookie", nullable(initialCookie))
                .put(
                    "resolved_cookie",
                    nullable(analyze.headerMap["Cookie"])
                )
                .put(
                    "marker_present",
                    analyze.headerMap.containsKey(
                        CookieManager.cookieJarHeader
                    )
                )
                .put(
                    "network_cookie",
                    nullable(networkRequest.header("Cookie"))
                )
                .put(
                    "network_marker_present",
                    networkRequest.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put("status_code", response.code())
                .put("final_url", logical(response.url))
        )
    }

    private suspend fun cookieRedirectProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        resetCookieState(deviceOrigin)
        val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
        caseSource.enabledCookieJar = true
        val target = value.getJSONObject("request").getString("target")
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target",
            baseUrl = caseSource.bookSourceUrl,
            source = caseSource,
            headerMapF = caseSource.getHeaderMap(true)
        )
        val response = analyze.getStrResponseAwait(useWebView = false)
        val prior = response.raw.priorResponse
        val finalNetwork =
            response.raw.networkResponse?.request ?: response.raw.request
        var redirectCount = 0
        var cursor = prior
        while (cursor != null) {
            redirectCount += 1
            cursor = cursor.priorResponse
        }
        return Pair(
            analyzedRequest(analyze),
            cookieState(deviceOrigin)
                .put("redirect_count", redirectCount)
                .put(
                    "prior_request_cookie",
                    nullable(prior?.request?.header("Cookie"))
                )
                .put(
                    "prior_marker_present",
                    prior?.request?.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put(
                    "final_request_cookie",
                    nullable(finalNetwork.header("Cookie"))
                )
                .put(
                    "final_marker_present",
                    finalNetwork.header(
                        CookieManager.cookieJarHeader
                    ) != null
                )
                .put("final_url", logical(response.url))
                .put("status_code", response.code())
        )
    }

    private fun seedCookieState(arguments: JSONObject) {
        CookieStore.setCookie(
            deviceOrigin,
            arguments.optString("persistent_cookie", "")
        )
        if (arguments.has("session_set_cookies")) {
            saveSetCookies(
                deviceOrigin,
                jsonStrings(
                    arguments.getJSONArray("session_set_cookies")
                )
            )
        }
    }

    private fun saveSetCookies(
        url: String,
        values: List<String>
    ) {
        val request = Request.Builder().url(url).build()
        val headers = Headers.Builder().apply {
            values.forEach { add("Set-Cookie", it) }
        }.build()
        val response = Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("cookie-seed")
            .headers(headers)
            .body(
                ByteArray(0).toResponseBody(
                    "text/plain; charset=utf-8".toMediaType()
                )
            )
            .build()
        CookieManager.saveResponse(response)
        response.close()
    }

    private fun resetCookieState(url: String) {
        val domain = NetworkUtils.getSubDomain(url)
        CookieStore.setCookie(url, "")
        CacheManager.deleteMemory("${domain}_session_cookie")
        CacheManager.deleteMemory("${domain}_cookieJar")
    }

    private fun cookieState(url: String): JSONObject {
        val domain = NetworkUtils.getSubDomain(url)
        return JSONObject()
            .put("domain", domain)
            .put(
                "persistent_cookie",
                CookieManager.getCookieNoSession(url)
            )
            .put(
                "session_cookie",
                nullable(CookieManager.getSessionCookie(domain))
            )
            .put("combined_cookie", CookieStore.getCookie(url))
    }

    private fun cookieEntries(
        values: Map<String, String>
    ): JSONArray = JSONArray().apply {
        values.forEach { (name, value) ->
            put(
                JSONObject()
                    .put("name", name)
                    .put("value", value)
            )
        }
    }

    private fun jsonStrings(values: JSONArray): List<String> =
        buildList {
            for (index in 0 until values.length()) {
                add(values.getString(index))
            }
        }

    private fun cookieHelperRequest(value: JSONObject): JSONObject {
        val target = value.getJSONObject("request").getString("target")
        return request(deviceOrigin + target).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "cookie-session")
            )
        )
    }

    private suspend fun retryAnalyzeProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val target = value.getJSONObject("request").getString("target")
        val option = JSONObject().put("retry", retry)
        val analyze = AnalyzeUrl(
            mUrl = "$deviceOrigin$target,$option",
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        val response = analyze.getStrResponseAwait(useWebView = false)
        val redirectObserved =
            response.raw.priorResponse?.isRedirect == true
        var redirectCheckCompleted = false
        if (arguments.optBoolean("invoke_redirect_check", false)) {
            reflectedCheckRedirect(response)
            redirectCheckCompleted = true
        }
        return Pair(
            analyzedRequest(analyze),
            JSONObject()
                .put("configured_retry", reflectedInt(analyze, "retry"))
                .put("status_code", response.code())
                .put("is_successful", response.isSuccessful())
                .put("body", nullable(response.body))
                .put("final_url", logical(response.url))
                .put("redirect_observed", redirectObserved)
                .put("redirect_check_completed", redirectCheckCompleted)
        )
    }

    private suspend fun helperStatusSequenceProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val rawStatuses = arguments.getJSONArray("status_sequence")
        val statuses = buildList {
            for (index in 0 until rawStatuses.length()) {
                add(rawStatuses.getInt(index))
            }
        }
        val attempts = mutableListOf<Int>()
        val fingerprints = mutableListOf<String>()
        val identities = mutableSetOf<Int>()
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                val request = chain.request()
                val status = statuses[minOf(attempts.size, statuses.lastIndex)]
                attempts.add(status)
                fingerprints.add(requestFingerprint(request))
                identities.add(System.identityHashCode(request))
                Response.Builder()
                    .request(request)
                    .protocol(Protocol.HTTP_1_1)
                    .code(status)
                    .message("status-$status")
                    .body(
                        "status-$status".toResponseBody(
                            "text/plain; charset=utf-8".toMediaType()
                        )
                    )
                    .build()
            }
            .build()
        val target = helperURL(value)
        val outcome = runCatching {
            client.newCallResponse(retry) {
                url(target)
                addHeader("X-Source", "retry-redirect")
            }
        }
        val response = outcome.getOrNull()
        val result = JSONObject()
            .put("configured_retry", retry)
            .put("attempt_count", attempts.size)
            .put("observed_statuses", JSONArray(attempts))
            .put("final_status", response?.code ?: JSONObject.NULL)
            .put("is_successful", response?.isSuccessful ?: false)
            .put(
                "request_fingerprints_identical",
                fingerprints.distinct().size <= 1
            )
            .put("request_instance_count", identities.size)
            .put(
                "exception_type",
                nullable(outcome.exceptionOrNull()?.javaClass?.name)
            )
        response?.close()
        return Pair(helperRequest(value), result)
    }

    private suspend fun helperNetworkExceptionProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val attempts = AtomicInteger()
        val client = OkHttpClient.Builder()
            .addInterceptor {
                attempts.incrementAndGet()
                throw IOException("source-lab-network-failure")
            }
            .build()
        val outcome = runCatching {
            client.newCallResponse(retry) {
                url(helperURL(value))
                addHeader("X-Source", "retry-redirect")
            }
        }
        return Pair(
            helperRequest(value),
            JSONObject()
                .put("configured_retry", retry)
                .put("attempt_count", attempts.get())
                .put(
                    "exception_type",
                    nullable(outcome.exceptionOrNull()?.javaClass?.name)
                )
                .put("response_received", outcome.getOrNull() != null)
        )
    }

    private suspend fun helperCancellationProjection(
        value: JSONObject
    ): Pair<JSONObject, JSONObject> = coroutineScope {
        val arguments = value.getJSONObject("arguments")
        val retry = arguments.getInt("retry")
        val attempts = AtomicInteger()
        val callCancelled = AtomicBoolean(false)
        val started = CompletableDeferred<Unit>()
        val client = OkHttpClient.Builder()
            .addInterceptor { chain ->
                attempts.incrementAndGet()
                started.complete(Unit)
                while (!chain.call().isCanceled()) {
                    Thread.sleep(1)
                }
                callCancelled.set(chain.call().isCanceled())
                throw IOException("cancelled")
            }
            .build()
        val call = async {
            client.newCallResponse(retry) {
                url(helperURL(value))
                addHeader("X-Source", "retry-redirect")
            }
        }
        withTimeout(2_000) { started.await() }
        call.cancel()
        val error = try {
            call.await()
            null
        } catch (value: Throwable) {
            value
        }
        withTimeout(2_000) {
            while (!callCancelled.get()) {
                delay(1)
            }
        }
        Pair(
            helperRequest(value),
            JSONObject()
                .put("configured_retry", retry)
                .put("attempt_count", attempts.get())
                .put("call_cancelled", callCancelled.get())
                .put("cancellation_propagated", error is CancellationException)
                .put("response_received", error == null)
        )
    }

    private fun helperRequest(value: JSONObject): JSONObject =
        request(helperURL(value)).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "retry-redirect")
            )
        )

    private fun helperURL(value: JSONObject): String =
        deviceOrigin + value.getJSONObject("request").getString("target")

    private fun requestFingerprint(request: Request): String =
        request.method + "\u0000" + request.url + "\u0000" + request.headers

    private fun retryFallbackRequest(value: JSONObject): JSONObject {
        val target = value.getJSONObject("request").getString("target")
        return request(deviceOrigin + target).put(
            "headers",
            controlledHeaders(
                listOf("X-Source" to "retry-redirect")
            )
        )
    }

    private fun reflectedCheckRedirect(response: StrResponse) {
        val method = WebBook::class.java.getDeclaredMethod(
            "checkRedirect",
            BookSource::class.java,
            StrResponse::class.java
        )
        method.isAccessible = true
        try {
            method.invoke(WebBook, source, response)
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private suspend fun runRequestOptionCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "request_options") {
                "Request option scenario only accepts request_options stimuli"
            }
            val arguments = value.getJSONObject("arguments")
            val persistentCookie = arguments.getString("persistent_cookie")
            val option = arguments.getJSONObject("option")
            val target = value
                .getJSONObject("request")
                .getString("target")
            CookieStore.removeCookie(deviceOrigin)
            if (persistentCookie.isNotEmpty()) {
                CookieStore.setCookie(deviceOrigin, persistentCookie)
            }
            try {
                val inheritedHeaders = controlledHeaders(
                    source.getHeaderMap(true).orEmpty().entries.map {
                        it.key to it.value
                    }
                )
                val analyze = AnalyzeUrl(
                    mUrl = "$deviceOrigin$target,${option}",
                    baseUrl = source.bookSourceUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val constructedHeaders = controlledHeaders(
                    analyze.headerMap.entries.map { it.key to it.value }
                )
                val request = request(analyze.url)
                    .put("headers", constructedHeaders)
                val retryField =
                    AnalyzeUrl::class.java.getDeclaredField("retry")
                retryField.isAccessible = true
                val retry = retryField.getInt(analyze)
                runCase(
                    value.getString("id"),
                    "request_options",
                    request
                ) {
                    val response = analyze.getStrResponseAwait(
                        useWebView = false
                    )
                    val networkRequest =
                        response.raw.networkResponse?.request
                            ?: response.raw.request
                    val networkHeaderPairs = buildList {
                        for (headerIndex in 0 until networkRequest.headers.size) {
                            add(
                                networkRequest.headers.name(headerIndex) to
                                    networkRequest.headers.value(headerIndex)
                            )
                        }
                    }
                    JSONObject()
                        .put("inherited_headers", inheritedHeaders)
                        .put("constructed_headers", constructedHeaders)
                        .put(
                            "resolved_headers",
                            controlledHeaders(
                                analyze.headerMap.entries.map {
                                    it.key to it.value
                                }
                            )
                        )
                        .put(
                            "network_headers",
                            controlledHeaders(networkHeaderPairs)
                        )
                        .put("retry", retry)
                        .put("status_code", response.code())
                        .put("body", nullable(response.body))
                        .put("final_url", logical(response.url))
                }
            } finally {
                CookieStore.removeCookie(deviceOrigin)
            }
        }
    }

    private fun runFieldEncodingCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "field_encoding") {
                "Field encoding scenario only accepts field_encoding stimuli"
            }
            val id = value.getString("id")
            val arguments = value.getJSONObject("arguments")
            val method = arguments.getString("method")
            val fieldsText = arguments.getString("fields")
            val target = value.getJSONObject("request").getString("target")
            val option = JSONObject()
            if (method == "POST") {
                option.put("method", "POST").put("body", fieldsText)
            }
            if (arguments.has("charset")) {
                option.put("charset", arguments.getString("charset"))
            }
            val rawURL =
                if (method == "GET") {
                    "$deviceOrigin$target?$fieldsText"
                } else {
                    "$deviceOrigin$target,$option"
                }
            val fallbackRequest = request("$deviceOrigin$target")
                .put("method", method)
            val record = JSONObject()
                .put("id", id)
                .put("operation", "field_encoding")
            try {
                val analyze = AnalyzeUrl(
                    mUrl = rawURL,
                    baseUrl = source.bookSourceUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val fieldMap = reflectedFieldMap(analyze)
                val encoded = fieldMap.entries.joinToString("&") {
                    "${it.key}=${it.value}"
                }
                val analyzedRequest =
                    if (method == "GET") {
                        request("${reflectedString(analyze, "urlNoQuery")}?$encoded")
                    } else {
                        request(analyze.url)
                            .put("method", "POST")
                            .put("body", encoded)
                    }
                requestPlan.put(analyzedRequest)
                record
                    .put("request", analyzedRequest)
                    .put(
                        "result",
                        JSONObject()
                            .put("method", method)
                            .put(
                                "query_string",
                                nullable(reflectedNullableString(analyze, "queryStr"))
                            )
                            .put(
                                "field_map",
                                JSONArray().apply {
                                    fieldMap.forEach { (key, fieldValue) ->
                                        put(
                                            JSONObject()
                                                .put("key", key)
                                                .put("value", fieldValue)
                                        )
                                    }
                                }
                            )
                    )
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                requestPlan.put(fallbackRequest)
                record
                    .put("request", fallbackRequest)
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
    }

    private fun runURLTemplateCompilationCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "url_template_compilation") {
                "URL template scenario only accepts url_template_compilation stimuli"
            }
            val id = value.getString("id")
            val arguments = value.getJSONObject("arguments")
            val template = arguments.getString("template")
            val key =
                if (arguments.has("key")) arguments.getString("key") else null
            val page =
                if (arguments.has("page")) arguments.getInt("page") else null
            val baseUrl =
                if (arguments.has("base_path")) {
                    deviceOrigin + arguments.getString("base_path")
                } else {
                    deviceOrigin
                }
            val fallback = value.getJSONObject("request")
            val fallbackRequest = request(
                deviceOrigin + fallback.getString("target")
            ).put("method", fallback.getString("method"))
            val record = JSONObject()
                .put("id", id)
                .put("operation", "url_template_compilation")
            try {
                val analyze = AnalyzeUrl(
                    mUrl = template,
                    key = key,
                    page = page,
                    baseUrl = baseUrl,
                    source = source,
                    headerMapF = source.getHeaderMap(true)
                )
                val fields = reflectedFieldMap(analyze)
                val encodedFields = fields.entries.joinToString("&") {
                    "${it.key}=${it.value}"
                }
                val method = if (analyze.isPost()) "POST" else "GET"
                val body =
                    if (analyze.isPost() && fields.isNotEmpty()) {
                        encodedFields
                    } else {
                        analyze.body
                    }
                val requestURL =
                    if (!analyze.isPost() && fields.isNotEmpty()) {
                        "${reflectedString(analyze, "urlNoQuery")}?$encodedFields"
                    } else {
                        analyze.url
                    }
                val analyzedRequest = request(requestURL)
                    .put("method", method)
                    .put("body", nullable(body))
                requestPlan.put(analyzedRequest)
                record
                    .put("request", analyzedRequest)
                    .put(
                        "result",
                        JSONObject()
                            .put("rule_url", analyze.ruleUrl)
                            .put("url", logical(analyze.url))
                            .put(
                                "url_no_query",
                                logical(reflectedString(analyze, "urlNoQuery"))
                            )
                            .put("method", method)
                            .put("body", nullable(body))
                            .put(
                                "query_string",
                                nullable(
                                    reflectedNullableString(
                                        analyze,
                                        "queryStr"
                                    )
                                )
                            )
                            .put(
                                "field_map",
                                JSONArray().apply {
                                    fields.forEach { (fieldKey, fieldValue) ->
                                        put(
                                            JSONObject()
                                                .put("key", fieldKey)
                                                .put("value", fieldValue)
                                        )
                                    }
                                }
                            )
                            .put("retry", reflectedInt(analyze, "retry"))
                    )
                    .put("issue", JSONObject.NULL)
            } catch (error: Throwable) {
                requestPlan.put(fallbackRequest)
                record
                    .put("request", fallbackRequest)
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
    }

    private suspend fun runRateLimitStateCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "rate_limit_state") {
                "Rate limit scenario only accepts rate_limit_state stimuli"
            }
            val target = value.getJSONObject("request").getString("target")
            runCase(
                value.getString("id"),
                "rate_limit_state",
                request("$deviceOrigin$target")
            ) {
                rateLimitProjection(value)
            }
        }
    }

    private suspend fun runTransportDispatchCases() {
        val values = input.getJSONArray("cases")
        for (index in 0 until values.length()) {
            val value = values.getJSONObject(index)
            require(value.getString("operation") == "transport_dispatch") {
                "Transport dispatch scenario only accepts transport_dispatch stimuli"
            }
            when (value.getJSONObject("arguments").getString("mode")) {
                "response" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    analyze.getResponseAwait().use { response ->
                        val networkRequest =
                            response.networkResponse?.request ?: response.request
                        Pair(
                            observedRequest(networkRequest),
                            responseProjection(response)
                        )
                    }
                }

                "typed_string" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val response = analyze.getStrResponseAwait(useWebView = false)
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("body_hex", nullable(response.body))
                            .put("final_url", logical(response.url))
                    )
                }

                "byte_array" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val bytes = analyze.getByteArrayAwait()
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("bytes_base64", base64(bytes))
                            .put("byte_count", bytes.size)
                    )
                }

                "input_stream" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val bytes = analyze.getInputStreamAwait().use {
                        it.readBytes()
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("bytes_base64", base64(bytes))
                            .put("byte_count", bytes.size)
                    )
                }

                "data_uri" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val byteArray = analyze.getByteArrayAwait()
                    val streamBytes = analyze.getInputStreamAwait().use {
                        it.readBytes()
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("byte_array_base64", base64(byteArray))
                            .put("input_stream_base64", base64(streamBytes))
                            .put("same_bytes", byteArray.contentEquals(streamBytes))
                    )
                }

                "media_models" -> runTransportCase(value) {
                    val analyze = transportAnalyze(value)
                    val glide = analyze.getGlideUrl()
                    val mediaUri = requireNotNull(
                        analyze.getMediaItem().localConfiguration
                    ).uri.toString()
                    val mediaParts = mediaUri.split("🚧", limit = 2)
                    require(mediaParts.size == 2) {
                        "MediaItem did not preserve the URL/header boundary"
                    }
                    val mediaHeaders = JSONObject(mediaParts[1])
                    val mediaHeaderPairs = buildList {
                        mediaHeaders.keys().forEach { name ->
                            add(name to mediaHeaders.getString(name))
                        }
                    }
                    Pair(
                        analyzedRequest(analyze),
                        JSONObject()
                            .put("glide_url", logical(glide.toStringUrl()))
                            .put(
                                "glide_headers",
                                controlledHeaders(
                                    glide.headers.entries.map {
                                        it.key to it.value
                                    }
                                )
                            )
                            .put("media_url", logical(mediaParts[0]))
                            .put(
                                "media_headers",
                                controlledHeaders(mediaHeaderPairs)
                            )
                    )
                }

                "client_policy" -> runTransportCase(value) {
                    val arguments = value.getJSONObject("arguments")
                    val readTimeout = arguments.getLong("read_timeout_ms")
                    val analyze = transportAnalyze(value)
                    val client = reflectedClient(analyze)
                    Pair(
                        analyzedRequest(analyze, readTimeout.toInt()),
                        JSONObject()
                            .put(
                                "proxy_header_removed",
                                analyze.headerMap.keys.none {
                                    it.equals("proxy", ignoreCase = true)
                                }
                            )
                            .put("proxy_configured", client.proxy != null)
                            .put(
                                "proxy_type",
                                nullable(client.proxy?.type()?.name)
                            )
                            .put(
                                "read_timeout_ms",
                                client.readTimeoutMillis
                            )
                            .put(
                                "call_timeout_ms",
                                client.callTimeoutMillis
                            )
                            .put(
                                "request_headers",
                                controlledHeaders(
                                    analyze.headerMap.entries.map {
                                        it.key to it.value
                                    }
                                )
                            )
                    )
                }

                else -> error(
                    "Unsupported transport dispatch mode: " +
                        value.getJSONObject("arguments").getString("mode")
                )
            }
        }
    }

    private suspend fun runTransportCase(
        value: JSONObject,
        execute: suspend () -> Pair<JSONObject, JSONObject>
    ) {
        val id = value.getString("id")
        val record = JSONObject()
            .put("id", id)
            .put("operation", "transport_dispatch")
        try {
            val (request, result) = execute()
            requestPlan.put(request)
            record
                .put("request", request)
                .put("result", result)
                .put("issue", JSONObject.NULL)
        } catch (error: Throwable) {
            val request = fallbackTransportRequest(value)
            requestPlan.put(request)
            record
                .put("request", request)
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

    private fun transportAnalyze(value: JSONObject): AnalyzeUrl {
        val request = value.getJSONObject("request")
        val arguments = value.getJSONObject("arguments")
        val target = request.getString("target")
        val rawURL =
            if (target.startsWith("data:")) target else deviceOrigin + target
        if (arguments.getString("mode") == "client_policy") {
            return AnalyzeUrl(
                mUrl = rawURL,
                baseUrl = source.bookSourceUrl,
                source = source,
                readTimeout = arguments.getLong("read_timeout_ms"),
                headerMapF = mapOf(
                    "proxy" to arguments.getString("proxy"),
                    "X-Policy" to "source"
                )
            )
        }
        val option = JSONObject()
        if (request.getString("method") == "POST") {
            option
                .put("method", "POST")
                .put("body", arguments.getString("body"))
        }
        if (arguments.has("content_type")) {
            option.put(
                "headers",
                JSONObject().put(
                    "Content-Type",
                    arguments.getString("content_type")
                )
            )
        }
        if (arguments.has("type")) {
            option.put("type", arguments.getString("type"))
        }
        if (arguments.has("header_name")) {
            option.put(
                "headers",
                JSONObject().put(
                    arguments.getString("header_name"),
                    arguments.getString("header_value")
                )
            )
        }
        val ruleURL =
            if (option.length() == 0) rawURL else "$rawURL,$option"
        return AnalyzeUrl(
            mUrl = ruleURL,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
    }

    private fun fallbackTransportRequest(value: JSONObject): JSONObject {
        val request = value.getJSONObject("request")
        val arguments = value.getJSONObject("arguments")
        val target = request.getString("target")
        val url =
            if (target.startsWith("data:")) target else deviceOrigin + target
        val result = request(url).put("method", request.getString("method"))
        if (arguments.has("body")) {
            result.put("body", arguments.getString("body"))
        }
        if (arguments.has("content_type")) {
            result.put(
                "headers",
                controlledHeaders(
                    listOf(
                        "Content-Type" to arguments.getString("content_type")
                    )
                )
            )
        }
        if (arguments.has("read_timeout_ms")) {
            result.put("timeout_ms", arguments.getInt("read_timeout_ms"))
        }
        return result
    }

    private fun observedRequest(
        value: Request,
        timeoutMillis: Int? = null
    ): JSONObject {
        val requestBody = value.body
        val body =
            if (requestBody == null) {
                null
            } else {
                Buffer().use { buffer ->
                    requestBody.writeTo(buffer)
                    buffer.readString(Charsets.UTF_8)
                }
            }
        val headers = buildList {
            for (index in 0 until value.headers.size) {
                add(
                    value.headers.name(index) to
                        value.headers.value(index)
                )
            }
        }
        return JSONObject()
            .put("method", value.method)
            .put("url", logical(value.url.toString()))
            .put("headers", controlledHeaders(headers))
            .put("body", nullable(body))
            .put("timeout_ms", timeoutMillis ?: JSONObject.NULL)
    }

    private fun analyzedRequest(
        analyze: AnalyzeUrl,
        timeoutMillis: Int? = null
    ): JSONObject =
        JSONObject()
            .put("method", if (analyze.isPost()) "POST" else "GET")
            .put("url", logical(analyze.url))
            .put(
                "headers",
                controlledHeaders(
                    analyze.headerMap.entries.map {
                        it.key to it.value
                    }
                )
            )
            .put(
                "body",
                if (analyze.isPost()) nullable(analyze.body) else JSONObject.NULL
            )
            .put("timeout_ms", timeoutMillis ?: JSONObject.NULL)

    private fun responseProjection(response: Response): JSONObject {
        val bytes = response.body?.bytes() ?: byteArrayOf()
        return JSONObject()
            .put("status_code", response.code)
            .put("final_url", logical(response.request.url.toString()))
            .put("body_base64", base64(bytes))
            .put("byte_count", bytes.size)
    }

    private fun reflectedClient(analyze: AnalyzeUrl): OkHttpClient {
        val method = AnalyzeUrl::class.java.getDeclaredMethod("getClient")
        method.isAccessible = true
        return try {
            method.invoke(analyze) as OkHttpClient
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun base64(value: ByteArray): String =
        Base64.encodeToString(value, Base64.NO_WRAP)

    private fun rateLimitProjection(value: JSONObject): JSONObject {
        val id = value.getString("id")
        val arguments = value.getJSONObject("arguments")
        val mode = arguments.getString("mode")
        val rate = arguments.getString("concurrent_rate")
        fun analyze(key: String = id): AnalyzeUrl {
            val caseSource = GSON.fromJson(sourceJson, BookSource::class.java)
            caseSource.bookSourceUrl = "$deviceOrigin/rate-source/$key"
            caseSource.bookSourceName = "Rate $key"
            caseSource.concurrentRate = rate
            return AnalyzeUrl(
                mUrl = "$deviceOrigin/rate-limit/$id",
                baseUrl = caseSource.bookSourceUrl,
                source = caseSource,
                headerMapF = caseSource.getHeaderMap(true)
            )
        }

        return when (mode) {
            "disabled" -> {
                val record = reflectedFetchStart(analyze())
                JSONObject()
                    .put("active", record != null)
                    .put("rate", rate)
            }

            "interval_shared" -> {
                val first = requireNotNull(reflectedFetchStart(analyze()))
                val second = deniedWait(analyze())
                val frequencyOnDenial = first.frequency
                reflectedFetchEnd(analyze(), first)
                val afterEnd = deniedWait(analyze())
                JSONObject()
                    .put("first_allowed", true)
                    .put("second_same_key_denied", second > 0)
                    .put("after_end_still_denied", afterEnd > 0)
                    .put("record_mode", "minimum_interval")
                    .put("frequency_on_denial", frequencyOnDenial)
            }

            "window_boundary" -> {
                val limiter = analyze()
                var allowed = 0
                var record: AnalyzeUrl.ConcurrentRecord? = null
                var denied = 0
                repeat(4) {
                    try {
                        record = reflectedFetchStart(limiter)
                        allowed += 1
                    } catch (error: ConcurrentException) {
                        denied = error.waitTime
                    }
                }
                JSONObject()
                    .put("allowed_before_denial", allowed)
                    .put("denied_wait_positive", denied > 0)
                    .put("record_mode", "count_per_window")
                    .put("frequency_on_denial", requireNotNull(record).frequency)
            }

            "distinct_keys" -> {
                val first = requireNotNull(reflectedFetchStart(analyze("$id-a")))
                val second = requireNotNull(reflectedFetchStart(analyze("$id-b")))
                JSONObject()
                    .put("both_allowed", true)
                    .put("records_are_distinct", first !== second)
            }

            "invalid_degrades" -> {
                val limiter = analyze()
                val first = requireNotNull(reflectedFetchStart(limiter))
                val second = requireNotNull(reflectedFetchStart(limiter))
                JSONObject()
                    .put("both_allowed", true)
                    .put("same_record", first === second)
                    .put("is_count_window", first.isConcurrent)
                    .put("frequency_after_second", second.frequency)
            }

            else -> error("Unsupported rate limit mode: $mode")
        }
    }

    private fun reflectedFetchStart(
        analyze: AnalyzeUrl
    ): AnalyzeUrl.ConcurrentRecord? {
        val method = AnalyzeUrl::class.java.getDeclaredMethod("fetchStart")
        method.isAccessible = true
        return try {
            method.invoke(analyze) as? AnalyzeUrl.ConcurrentRecord
        } catch (error: InvocationTargetException) {
            throw error.targetException
        }
    }

    private fun reflectedFetchEnd(
        analyze: AnalyzeUrl,
        record: AnalyzeUrl.ConcurrentRecord
    ) {
        val method = AnalyzeUrl::class.java.getDeclaredMethod(
            "fetchEnd",
            AnalyzeUrl.ConcurrentRecord::class.java
        )
        method.isAccessible = true
        method.invoke(analyze, record)
    }

    private fun deniedWait(analyze: AnalyzeUrl): Int =
        try {
            reflectedFetchStart(analyze)
            0
        } catch (error: ConcurrentException) {
            error.waitTime
        }

    @Suppress("UNCHECKED_CAST")
    private fun reflectedFieldMap(
        analyze: AnalyzeUrl
    ): LinkedHashMap<String, String> {
        val field = AnalyzeUrl::class.java.getDeclaredField("fieldMap")
        field.isAccessible = true
        return field.get(analyze) as LinkedHashMap<String, String>
    }

    private fun reflectedString(analyze: AnalyzeUrl, name: String): String =
        requireNotNull(reflectedNullableString(analyze, name))

    private fun reflectedNullableString(
        analyze: AnalyzeUrl,
        name: String
    ): String? {
        val field = AnalyzeUrl::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.get(analyze) as? String
    }

    private fun reflectedInt(analyze: AnalyzeUrl, name: String): Int {
        val field = AnalyzeUrl::class.java.getDeclaredField(name)
        field.isAccessible = true
        return field.getInt(analyze)
    }

    private fun controlledHeaders(
        values: List<Pair<String, String>>
    ): JSONArray =
        JSONArray().apply {
            values
                .filter {
                    val name = it.first.lowercase()
                    name == "cookie" ||
                        name == "cookiejar" ||
                        name == "content-type" ||
                        name.startsWith("x-")
                }
                .sortedWith(
                    compareBy<Pair<String, String>>(
                        { it.first.lowercase() },
                        { it.first },
                        { it.second }
                    )
                )
                .forEach { (name, value) ->
                    put(
                        JSONObject()
                            .put("name", name)
                            .put("value", value)
                    )
                }
        }

    private fun postSearchRequest(keyword: String): JSONObject {
        val analyze = AnalyzeUrl(
            mUrl = requireNotNull(source.searchUrl),
            key = keyword,
            page = 1,
            baseUrl = source.bookSourceUrl,
            source = source,
            headerMapF = source.getHeaderMap(true)
        )
        require(analyze.isPost()) {
            "POST form scenario did not produce POST"
        }
        val field = AnalyzeUrl::class.java.getDeclaredField("fieldMap")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        val fields = field.get(analyze) as LinkedHashMap<String, String>
        val body = fields.entries.joinToString("&") {
            "${it.key}=${it.value}"
        }
        return JSONObject()
            .put("method", "POST")
            .put("url", logical(analyze.url))
            .put(
                "headers",
                JSONArray().apply {
                    analyze.headerMap.entries
                        .sortedBy { it.key.lowercase() }
                        .forEach {
                            put(
                                JSONObject()
                                    .put("name", it.key)
                                    .put("value", it.value)
                            )
                        }
                }
            )
            .put("body", body)
            .put(
                "body_base64",
                Base64.encodeToString(
                    body.toByteArray(Charsets.UTF_8),
                    Base64.NO_WRAP
                )
            )
            .put(
                "form_fields",
                JSONArray().apply {
                    fields.forEach { (key, value) ->
                        put(
                            JSONObject()
                                .put("key", key)
                                .put("value", value)
                        )
                    }
                }
            )
            .put("timeout_ms", JSONObject.NULL)
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
            Log.e(
                "LegadoOracle",
                "case=$id operation=$operation failed",
                error
            )
            val issue = JSONObject()
                .put("code", "android_exception")
                .put("exception_type", error.javaClass.name)
            if (
                scenarioId == "rl-integration-backup-archive-001" ||
                    scenarioId == "rl-integration-backup-ios-to-android-001" ||
                    scenarioId ==
                    "rl-integration-backup-ios-replacerule-to-android-001" ||
                    scenarioId ==
                    "rl-integration-backup-ios-library-to-android-001"
            ) {
                issue.put(
                    "exception_message",
                    error.message?.take(1_024) ?: ""
                )
            }
            record
                .put("result", JSONObject.NULL)
                .put("issue", issue)
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
