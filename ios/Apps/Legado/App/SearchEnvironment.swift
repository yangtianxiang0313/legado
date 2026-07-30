import AppUseCases
import Foundation
import LibraryDomain
import ScriptJavaScriptCore
import SourceRuntime
import WebKit

@MainActor
enum SearchEnvironment {
    private static let cookieStore = SourceCookieStore(
        persistence: UserDefaultsSourceCookiePersistence()
    )
    private static let dynamicWebPagePort = WKSourceDynamicWebPagePort()
    private static let scriptRuntime =
        JavaScriptCoreSourceScriptRuntime()

    static func makeSession(
        persistedSources: [BookSourceDraft] = []
    ) -> SearchSession {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let transport = makeTransport(externalBaseURL: externalBaseURL)
        let sources = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources
        )
        return SearchSession(
            groups: Array(Set(sources.map(\.group))).sorted(),
            executor: SourceSearchBooksExecutor(
                sources: sources,
                transport: transport,
                cookieStore: cookieStore,
                dynamicWebPagePort: dynamicWebPagePort,
                scriptRuntime: scriptRuntime
            )
        )
    }

    static func exploreSources(
        persistedSources: [BookSourceDraft] = []
    ) -> [ExploreSourceSummary] {
        makeSources(
            baseURL: ProcessInfo.processInfo.environment[
                "LEGADO_SEARCH_BASE_URL"
            ] ?? "http://legado.local",
            persistedSources: persistedSources,
            includeDisabled: true
        ).compactMap { descriptor in
            guard descriptor.exploreDefinition?.enabled == true else {
                return nil
            }
            return ExploreSourceSummary(
                id: descriptor.id,
                name: descriptor.name,
                group: descriptor.group
            )
        }
    }

    static func sourceSwitchTargets(
        persistedSources: [BookSourceDraft] = []
    ) -> [BookSourceDraft] {
        let baseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ] ?? "http://legado.local"
        let builtIn = [
            BookSourceDraft(
                sourceURL: "\(baseURL)/source/science-fiction",
                name: "本地科幻书源",
                group: "科幻"
            ),
            BookSourceDraft(
                sourceURL: "\(baseURL)/source/fantasy",
                name: "本地奇幻书源",
                group: "奇幻"
            ),
        ]
        let builtInIDs = Set(builtIn.map(\.sourceURL))
        return builtIn + persistedSources.filter {
            !builtInIDs.contains($0.sourceURL)
        }
    }

    static func makeExploreSession(
        sourceID: String,
        persistedSources: [BookSourceDraft] = []
    ) -> ExploreSession {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let descriptors = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        ).compactMap { source -> ExploreSourceDescriptor? in
            guard
                let definition = source.exploreDefinition,
                definition.enabled
            else {
                return nil
            }
            return ExploreSourceDescriptor(
                summary: ExploreSourceSummary(
                    id: source.id,
                    name: source.name,
                    group: source.group
                ),
                definition: definition
            )
        }
        let executor = SourceExploreBooksExecutor(
            descriptors: descriptors,
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort,
            scriptRuntime: scriptRuntime
        )
        let summary = executor.sources.first(where: {
            $0.id == sourceID
        }) ?? ExploreSourceSummary(
            id: sourceID,
            name: sourceID,
            group: ""
        )
        return ExploreSession(source: summary, executor: executor)
    }

    static func makeChapterLoader(
        persistedSources: [BookSourceDraft] = []
    ) -> any BookChapterLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceBookChapterLoader(
            sources: makeSources(
                baseURL: baseURL,
                persistedSources: persistedSources,
                includeDisabled: true
            ),
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort,
            scriptRuntime: scriptRuntime
        )
    }

    static func makeReaderContentLoader(
        persistedSources: [BookSourceDraft] = []
    ) -> any ReaderContentLoading {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        return SourceReaderContentLoader(
            sources: makeSources(
                baseURL: baseURL,
                persistedSources: persistedSources,
                includeDisabled: true
            ),
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort,
            scriptRuntime: scriptRuntime
        )
    }

    static func importBookURL(
        _ rawValue: String,
        library: ShelfLibrary,
        persistedSources: [BookSourceDraft] = []
    ) async throws -> ShelfBookItem {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            let bookEndpoint = try? SourceEndpoint(
                resolving: value,
                relativeTo: URL(string: "http://legado.invalid")!
            ),
            let baseURL = originBaseURL(bookEndpoint.logicalURL)
        else {
            throw BookURLImportEnvironmentError.invalidURL
        }
        let logicalBookURL = bookEndpoint.logicalURL.absoluteString
        if let existing = await library.item(forURL: logicalBookURL) {
            return existing
        }

        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let environmentBaseURL = externalBaseURL ?? "http://legado.local"
        let sources = makeSources(
            baseURL: environmentBaseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        )
        let matches = sources.map { source in
            RemoteBookSourceCandidate(
                sourceID: source.id,
                sourceName: source.name,
                match: source.definition.sourceURL == baseURL
                    ? .exactBase
                    : patternMatch(
                        source.definition.bookURLPattern,
                        value: logicalBookURL
                    )
            )
        }
        guard
            let selectedIndex = matches.firstIndex(where: {
                $0.match == .exactBase
            }) ?? matches.firstIndex(where: {
                $0.match == .pattern
            })
        else {
            throw BookURLImportEnvironmentError.sourceNotFound
        }
        let selected = sources[selectedIndex]
        let execution = try await SourceBookInfoPipeline(
            definition: selected.definition,
            transport: makeTransport(externalBaseURL: externalBaseURL),
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort
        ).load(
            book: SourceBook(
                name: "",
                author: nil,
                intro: nil,
                kind: nil,
                lastChapter: nil,
                bookEndpoint: bookEndpoint,
                coverURL: nil,
                tocEndpoint: nil
            )
        )
        let resolved = RemoteBookImporter.resolve(
            existingBook: nil,
            orderedSources: matches,
            fetchedBook: ImportedBook(
                id: LibraryDomain.BookID(rawValue: logicalBookURL),
                name: execution.book.name,
                author: normalizedAuthor(execution.book.author ?? ""),
                originName: selected.name,
                originKind: matches[selectedIndex].match == .exactBase
                    ? .exactBase
                    : .pattern,
                isLocal: false,
                isArchive: false,
                chapterCount: 0
            )
        )
        guard resolved.outcome == .added else {
            throw BookURLImportEnvironmentError.fetchFailed
        }
        let candidate = ShelfBookCandidate(
            name: execution.book.name,
            author: normalizedAuthor(execution.book.author ?? ""),
            kind: execution.book.kind ?? "",
            lastChapter: execution.book.lastChapter ?? "",
            intro: execution.book.intro ?? "",
            bookURL: execution.book.bookURL.absoluteString,
            bookRequestExpression:
                execution.book.bookEndpoint.requestExpression,
            coverURL: execution.book.coverURL?.absoluteString,
            originName: selected.name,
            sourceID: selected.id,
            variables: execution.book.variables
        )
        await library.add(candidate)
        guard
            let item = await library.item(forURL: logicalBookURL)
        else {
            throw BookURLImportEnvironmentError.persistenceFailed
        }
        let toc = library.chapterSession(
            loader: SourceBookChapterLoader(
                sources: [selected],
                transport: makeTransport(
                    externalBaseURL: externalBaseURL
                ),
                cookieStore: cookieStore,
                dynamicWebPagePort: dynamicWebPagePort,
                scriptRuntime: scriptRuntime
            )
        )
        await toc.load(book: item, force: true)
        guard
            let reloaded = await library.item(forURL: logicalBookURL)
        else {
            throw BookURLImportEnvironmentError.persistenceFailed
        }
        return reloaded
    }

    static func resolveSourceSwitch(
        current: ShelfBookItem,
        target: BookSourceDraft,
        persistedSources: [BookSourceDraft]
    ) async throws -> (
        candidate: ShelfBookCandidate,
        chapters: [LibraryDomain.BookChapter]
    ) {
        let externalBaseURL = ProcessInfo.processInfo.environment[
            "LEGADO_SEARCH_BASE_URL"
        ]
        let baseURL = externalBaseURL ?? "http://legado.local"
        let sources = makeSources(
            baseURL: baseURL,
            persistedSources: persistedSources,
            includeDisabled: true
        )
        guard let descriptor = sources.first(where: {
            $0.id == target.sourceURL
        }) else {
            throw SourceSwitchEnvironmentError.unsupportedSource
        }
        let transport = makeTransport(externalBaseURL: externalBaseURL)
        let results = try await SourceSearchBooksExecutor(
            sources: [descriptor],
            transport: transport,
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort,
            scriptRuntime: scriptRuntime
        ).search(
            query: current.candidate.name,
            scope: .source(
                name: descriptor.name,
                identifier: descriptor.id
            )
        )
        guard let result = results.first(where: {
            $0.name == current.candidate.name
                && normalizedAuthor($0.author)
                    == normalizedAuthor(current.candidate.author)
        }) ?? results.first else {
            throw SourceSwitchEnvironmentError.bookNotFound
        }
        let candidate = ShelfBookCandidate(
            name: result.name,
            author: result.author,
            kind: result.kind,
            lastChapter: result.lastChapter,
            intro: result.intro,
            bookURL: result.bookURL,
            bookRequestExpression: result.bookRequestExpression,
            coverURL: result.coverURL,
            originName: result.originName,
            sourceID: descriptor.id,
            variables: result.variables
        )
        let transient = ShelfBookItem(
            id: current.id,
            candidate: candidate,
            membership: current.membership,
            order: current.order,
            chapterCount: current.chapterCount,
            progress: current.progress
        )
        let chapters = try await SourceBookChapterLoader(
            sources: [descriptor],
            transport: transport,
            cookieStore: cookieStore,
            dynamicWebPagePort: dynamicWebPagePort,
            scriptRuntime: scriptRuntime
        ).load(book: transient).chapters
        return (candidate, chapters)
    }

    private static func makeTransport(
        externalBaseURL: String?
    ) -> any HTTPTransport {
        if ProcessInfo.processInfo.arguments.contains(
            "--offline-source-transport"
        ) {
            return OfflineBookSourceTransport()
        }
        if externalBaseURL == nil {
            return LocalBookSourceTransport()
        }
        return URLSessionBookSourceTransport()
    }

    private static func makeSources(
        baseURL: String,
        persistedSources: [BookSourceDraft] = [],
        includeDisabled: Bool = false
    ) -> [SearchSourceDescriptor] {
        var values = [
            source(
                baseURL: baseURL,
                id: "\(baseURL)/source/science-fiction",
                name: "本地科幻书源",
                group: "科幻",
                order: 0
            ),
            source(
                baseURL: baseURL,
                id: "\(baseURL)/source/fantasy",
                name: "本地奇幻书源",
                group: "奇幻",
                order: 1
            ),
        ]
        for draft in persistedSources {
            guard
                includeDisabled
                    || (draft.importMetadata?.enabled ?? true),
                let descriptor = persistedSource(draft)
            else { continue }
            if let index = values.firstIndex(where: {
                $0.id == descriptor.id
            }) {
                values[index] = descriptor
            } else {
                values.append(descriptor)
            }
        }
        return values
    }

    private static func persistedSource(
        _ draft: BookSourceDraft
    ) -> SearchSourceDescriptor? {
        guard
            let data = draft.rawDefinition,
            let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let search = root["ruleSearch"] as? [String: Any],
            let info = root["ruleBookInfo"] as? [String: Any],
            let toc = root["ruleToc"] as? [String: Any],
            let content = root["ruleContent"] as? [String: Any],
            let searchURL = string(root, "searchUrl"),
            !searchURL.isEmpty,
            let list = string(search, "bookList"),
            let searchName = string(search, "name"),
            let searchAuthor = string(search, "author"),
            let searchBookURL = string(search, "bookUrl"),
            let infoName = string(info, "name"),
            let infoAuthor = string(info, "author"),
            let tocURL = string(info, "tocUrl"),
            let chapterList = string(toc, "chapterList"),
            let chapterName = string(toc, "chapterName"),
            let chapterURL = string(toc, "chapterUrl"),
            let contentRule = string(content, "content")
        else {
            return nil
        }
        let sourceURL = draft.sourceURL
        let runtime = HTMLCSSSourceDefinition(
                    searchURLTemplate: searchURL,
                    search: SearchRules(
                        list: list,
                        name: HTMLCSSRule(searchName),
                        author: HTMLCSSRule(searchAuthor),
                        intro: .optional(
                            string(search, "intro")
                        ),
                        kind: .optional(
                            string(search, "kind")
                        ),
                        wordCount: .optional(
                            string(search, "wordCount")
                        ),
                        lastChapter: .optional(
                            string(search, "lastChapter")
                        ),
                        bookURL: HTMLCSSRule(
                            searchBookURL,
                            value: .href
                        ),
                        coverURL: .optional(
                            string(search, "coverUrl"),
                            value: .src
                        )
                    ),
                    explore: (root["ruleExplore"] as? [String: Any])
                        .flatMap(exploreRules),
                    bookInfo: BookInfoRules(
                        name: HTMLCSSRule(infoName),
                        author: HTMLCSSRule(infoAuthor),
                        intro: .optional(
                            string(info, "intro")
                        ),
                        kind: .optional(
                            string(info, "kind")
                        ),
                        lastChapter: .optional(
                            string(info, "lastChapter")
                        ),
                        coverURL: .optional(
                            string(info, "coverUrl"),
                            value: .src
                        ),
                        tocURL: HTMLCSSRule(tocURL, value: .href)
                    ),
                    toc: TOCRules(
                        list: chapterList,
                        name: HTMLCSSRule(chapterName),
                        url: HTMLCSSRule(chapterURL, value: .href),
                        nextTocURL: paginationRule(
                            toc,
                            key: "nextTocUrl"
                        )
                    ),
                    content: ContentRules(
                        content: HTMLCSSRule(
                            contentRule,
                            value: .html
                        ),
                        nextContentURL: paginationRule(
                            content,
                            key: "nextContentUrl"
                        ),
                        webJS: string(content, "webJs"),
                        sourceRegex: string(content, "sourceRegex")
                    )
                )
        let searchDefinition = SourceSearchDefinition(
            sourceURL: sourceURL,
            sourceName: draft.name,
            originOrder: Int(
                draft.importMetadata?.customOrder ?? 0
            ),
            bookURLPattern: string(root, "bookUrlPattern"),
            sourceHeaders: sourceHeaders(root),
            enabledCookieJar: root["enabledCookieJar"] as? Bool ?? false,
            runtime: runtime
        )
        let catalog = (
            string(root, "exploreUrl") ?? draft.exploreURL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let exploreDefinition = catalog.isEmpty
            ? nil
            : SourceExploreDefinition(
                source: searchDefinition,
                enabled: draft.importMetadata?.enabledExplore ?? true,
                catalog: catalog
            )
        return SearchSourceDescriptor(
            id: sourceURL,
            name: draft.name,
            group: draft.group,
            definition: searchDefinition,
            exploreDefinition: exploreDefinition
        )
    }

    private static func exploreRules(
        _ object: [String: Any]
    ) -> SearchRules? {
        guard
            let list = string(object, "bookList"),
            !list.isEmpty,
            let name = string(object, "name"),
            !name.isEmpty,
            let bookURL = string(object, "bookUrl"),
            !bookURL.isEmpty
        else {
            return nil
        }
        return SearchRules(
            list: list,
            name: HTMLCSSRule(name),
            author: .optional(string(object, "author")),
            intro: .optional(string(object, "intro")),
            kind: .optional(string(object, "kind")),
            wordCount: .optional(string(object, "wordCount")),
            lastChapter: .optional(string(object, "lastChapter")),
            bookURL: HTMLCSSRule(bookURL, value: .href),
            coverURL: .optional(
                string(object, "coverUrl"),
                value: .src
            )
        )
    }

    private static func string(
        _ object: [String: Any],
        _ key: String
    ) -> String? {
        guard let value = object[key] as? String else { return nil }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func paginationRule(
        _ object: [String: Any],
        key: String
    ) -> HTMLCSSRule? {
        guard
            let value = string(object, key),
            !value.isEmpty
        else {
            return nil
        }
        return HTMLCSSRule(value, value: .href)
    }

    private static func sourceHeaders(
        _ object: [String: Any]
    ) -> [SourceHeaderField] {
        let values: [String: Any]
        if let direct = object["header"] as? [String: Any] {
            values = direct
        } else if
            let raw = object["header"] as? String,
            let data = raw.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        {
            values = decoded
        } else {
            return []
        }
        return values.compactMap { name, value in
            guard let string = value as? String else { return nil }
            return try? SourceHeaderField(name: name, value: string)
        }.sorted {
            let left = $0.name.lowercased()
            let right = $1.name.lowercased()
            return left == right ? $0.name < $1.name : left < right
        }
    }

    private static func normalizedAuthor(_ value: String) -> String {
        value.replacingOccurrences(of: "作者：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func source(
        baseURL: String,
        id: String,
        name: String,
        group: String,
        order: Int
    ) -> SearchSourceDescriptor {
        let definition = SourceSearchDefinition(
            sourceURL: id,
            sourceName: name,
            originOrder: order,
            bookURLPattern:
                #"^"# + NSRegularExpression.escapedPattern(
                    for: baseURL
                ) + #"/books/"#,
            runtime: HTMLCSSSourceDefinition(
                searchURLTemplate:
                    "\(baseURL)/search?source=\(group)&q={{key}}",
                search: SearchRules(
                    list: ".book-item",
                    name: HTMLCSSRule(".book-name"),
                    author: HTMLCSSRule(".book-author"),
                    intro: HTMLCSSRule(".book-intro"),
                    kind: HTMLCSSRule(".book-kind"),
                    wordCount: HTMLCSSRule(".book-word-count"),
                    lastChapter: HTMLCSSRule(".book-last-chapter"),
                    bookURL: HTMLCSSRule(
                        "a.book-link",
                        value: .href
                    ),
                    coverURL: HTMLCSSRule(
                        "img.book-cover",
                        value: .src
                    )
                ),
                bookInfo: BookInfoRules(
                    name: HTMLCSSRule("h1.book-name"),
                    author: HTMLCSSRule(".book-author"),
                    intro: HTMLCSSRule(".book-intro"),
                    kind: HTMLCSSRule(".book-kind"),
                    lastChapter: HTMLCSSRule(".book-last-chapter"),
                    coverURL: HTMLCSSRule(
                        "img.book-cover",
                        value: .src
                    ),
                    tocURL: HTMLCSSRule(
                        "a.toc-link",
                        value: .href
                    )
                ),
                toc: TOCRules(
                    list: ".chapter",
                    name: HTMLCSSRule("a"),
                    url: HTMLCSSRule("a", value: .href)
                ),
                content: ContentRules(
                    content: HTMLCSSRule(
                        "#content",
                        value: .html
                    )
                )
            )
        )
        return SearchSourceDescriptor(
            id: id,
            name: name,
            group: group,
            definition: definition,
            exploreDefinition: SourceExploreDefinition(
                source: definition,
                enabled: true,
                catalog:
                    "\(group)精选::\(baseURL)/explore/"
                    + "{{page}}?source=\(group)"
            )
        )
    }

    private static func originBaseURL(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else {
            return nil
        }
        var value = "\(scheme)://\(host)"
        if let port = url.port {
            value += ":\(port)"
        }
        return value
    }

    private static func patternMatch(
        _ pattern: String?,
        value: String
    ) -> RemoteBookSourceMatch {
        guard let pattern, !pattern.isEmpty else { return .none }
        do {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(value.startIndex..., in: value)
            return expression.firstMatch(
                in: value,
                range: range
            ) == nil ? .none : .pattern
        } catch {
            return .invalidPattern
        }
    }
}

private enum SourceSwitchEnvironmentError: Error {
    case unsupportedSource
    case bookNotFound
}

private enum BookURLImportEnvironmentError: Error {
    case invalidURL
    case sourceNotFound
    case fetchFailed
    case persistenceFailed
}

private actor OfflineBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPTransportFailure.connectionFailed
    }
}

private actor LocalBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        let components = URLComponents(
            string: request.url.absoluteString
        )
        let path = components?.path ?? ""
        let body: String
        if path.hasPrefix("/explore/") {
            body = exploreHTML(
                path: path,
                components: components
            )
        } else if let book = Self.books.first(where: { $0.path == path }) {
            body = book.detailHTML
        } else if let book = Self.books.first(
            where: { "\($0.path)/toc" == path }
        ) {
            body = book.tocHTML
        } else if let match = Self.books.compactMap({
            $0.chapterHTML(path: path)
        }).first {
            body = match
        } else {
            body = searchHTML(components: components)
        }
        return try HTTPResponse(
            statusCode: 200,
            effectiveURL: request.url,
            body: HTTPBody(Data(body.utf8))
        )
    }

    private func searchHTML(
        components: URLComponents?
    ) -> String {
        let query = components?.queryItems?.first {
            $0.name == "q"
        }?.value ?? ""
        let group = components?.queryItems?.first {
            $0.name == "source"
        }?.value ?? ""
        let books = Self.books.filter {
            ($0.name.contains(query) || $0.author.contains(query))
                && (group.isEmpty || $0.group == group)
        }
        let html = books.map(\.html).joined(separator: "\n")
        return "<html><body>\(html)</body></html>"
    }

    private func exploreHTML(
        path: String,
        components: URLComponents?
    ) -> String {
        let page = Int(path.split(separator: "/").last ?? "") ?? 1
        let group = components?.queryItems?.first {
            $0.name == "source"
        }?.value ?? ""
        let books = page == 1
            ? Self.books.filter { group.isEmpty || $0.group == group }
            : []
        return "<html><body>"
            + books.map(\.html).joined(separator: "\n")
            + "</body></html>"
    }

    private static let books = [
        LocalBook(
            name: "星河纪事",
            author: "林舟",
            group: "科幻",
            kind: "科幻,冒险",
            lastChapter: "第二章 回声",
            intro: "远航者在群星之间追索失落信标。",
            path: "/books/star-river"
        ),
        LocalBook(
            name: "星河之外",
            author: "顾岚",
            group: "科幻",
            kind: "科幻",
            lastChapter: "第十章 归航",
            intro: "一次跨越边境星云的归航。",
            path: "/books/beyond-stars"
        ),
        LocalBook(
            name: "奇幻星河",
            author: "苏遥",
            group: "奇幻",
            kind: "奇幻",
            lastChapter: "第五章 星门",
            intro: "魔法星门连接了两片大陆。",
            path: "/books/fantasy-river"
        ),
    ]
}

private struct LocalBook: Sendable {
    let name: String
    let author: String
    let group: String
    let kind: String
    let lastChapter: String
    let intro: String
    let path: String

    var html: String {
        """
        <article class="book-item">
          <a class="book-link" href="\(path)"></a>
          <span class="book-name">\(name)</span>
          <span class="book-author">作者：\(author)</span>
          <span class="book-kind">\(kind)</span>
          <span class="book-last-chapter">\(lastChapter)</span>
          <p class="book-intro">\(intro)</p>
        </article>
        """
    }

    var detailHTML: String {
        """
        <html><body>
          <h1 class="book-name">\(name)</h1>
          <span class="book-author">作者：\(author)</span>
          <span class="book-kind">\(kind)</span>
          <span class="book-last-chapter">\(lastChapter)</span>
          <p class="book-intro">\(intro)</p>
          <a class="toc-link" href="\(path)/toc">目录</a>
        </body></html>
        """
    }

    var tocHTML: String {
        """
        <html><body>
          <div class="chapter"><a href="\(path)/chapter-1">第一章 启航</a></div>
          <div class="chapter"><a href="\(path)/chapter-2">第二章 回声</a></div>
          <div class="chapter"><a href="\(path)/chapter-3">第三章 归途</a></div>
        </body></html>
        """
    }

    func chapterHTML(path requestedPath: String) -> String? {
        let chapters = [
            (
                "\(path)/chapter-1",
                "第一章 启航",
                ["星港的晨光越过舷窗。", "远航者点亮了失落信标。"]
            ),
            (
                "\(path)/chapter-2",
                "第二章 回声",
                ["信号从群星深处返回。", "每一次回声都更接近真相。"]
            ),
            (
                "\(path)/chapter-3",
                "第三章 归途",
                ["舰队沿着星图驶向故乡。", "新的旅程已经在地平线等待。"]
            ),
        ]
        guard let chapter = chapters.first(
            where: { $0.0 == requestedPath }
        ) else { return nil }
        let paragraphs = chapter.2.map { "<p>\($0)</p>" }.joined()
        return """
        <html><body>
          <h1>\(chapter.1)</h1>
          <div id="content">\(paragraphs)</div>
        </body></html>
        """
    }
}

private struct URLSessionBookSourceTransport: HTTPTransport {
    func execute(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let url = URL(string: request.url.absoluteString) else {
            throw HTTPTransportFailure.invalidRequest
        }
        var value = URLRequest(url: url)
        value.httpMethod = request.method.rawValue
        for header in request.headers.fields {
            value.addValue(header.value, forHTTPHeaderField: header.name)
        }
        value.httpBody = request.body?.bytes
        do {
            let (data, response) = try await URLSession.shared.data(
                for: value
            )
            guard let http = response as? HTTPURLResponse else {
                throw HTTPTransportFailure.invalidResponse
            }
            return try HTTPResponse(
                statusCode: http.statusCode,
                effectiveURL: HTTPURL(
                    http.url?.absoluteString
                        ?? request.url.absoluteString
                ),
                body: HTTPBody(data)
            )
        } catch let failure as HTTPTransportFailure {
            throw failure
        } catch {
            throw HTTPTransportFailure.connectionFailed
        }
    }
}

private enum WKSourceDynamicWebError: Error {
    case invalidURL
    case navigationFailed
    case javaScriptTimedOut
}

private final class WKSourceDynamicWebPagePort:
    @unchecked Sendable, SourceDynamicWebPagePort
{
    func execute(
        _ request: SourceDynamicWebPageRequest
    ) async throws -> SourceDynamicWebPageResult {
        try await Task { @MainActor in
            let runner = WKSourceDynamicWebPageRunner(request: request)
            return try await runner.run()
        }.value
    }
}

@MainActor
private final class WKSourceDynamicWebPageRunner:
    NSObject, WKNavigationDelegate
{
    private let request: SourceDynamicWebPageRequest
    private let webView: WKWebView
    private var continuation:
        CheckedContinuation<SourceDynamicWebPageResult, any Error>?
    private var completionTask: Task<Void, Never>?

    init(request: SourceDynamicWebPageRequest) {
        self.request = request
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = request.userAgent
    }

    func run() async throws -> SourceDynamicWebPageResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor in
                    await seedRequestCookies()
                    startNavigation()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(throwing: CancellationError())
            }
        }
    }

    private func startNavigation() {
        guard let url = URL(string: request.url.absoluteString) else {
            finish(throwing: WKSourceDynamicWebError.invalidURL)
            return
        }
        switch request.mode {
        case .loadURL:
            var urlRequest = URLRequest(url: url)
            for header in request.headers.fields {
                urlRequest.addValue(
                    header.value,
                    forHTTPHeaderField: header.name
                )
            }
            webView.load(urlRequest)
        case .injectHTML:
            webView.loadHTMLString(request.html ?? "", baseURL: url)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        guard completionTask == nil else { return }
        completionTask = Task { @MainActor [weak self] in
            await self?.resolvePage()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(throwing: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(throwing: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(throwing: WKSourceDynamicWebError.navigationFailed)
    }

    private func resolvePage() async {
        try? await Task.sleep(for: .seconds(1))
        for attempt in 0...30 {
            if Task.isCancelled { return }
            if
                let sourceRegex = request.sourceRegex,
                let resource = await matchingResource(sourceRegex)
            {
                await finish(value: resource, kind: .resource)
                return
            }
            do {
                let result = try await webView.evaluateJavaScript(
                    request.javaScript
                )
                if let value = javaScriptString(result), !value.isEmpty {
                    await finish(value: value, kind: .javaScript)
                    return
                }
            } catch {
                if attempt == 30 {
                    finish(throwing: error)
                    return
                }
            }
            if attempt < 30 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        finish(throwing: WKSourceDynamicWebError.javaScriptTimedOut)
    }

    private func matchingResource(_ pattern: String) async -> String? {
        guard
            let values = try? await webView.evaluateJavaScript(
                """
                performance.getEntriesByType('resource').map(
                  function(entry) { return entry.name; }
                )
                """
            ) as? [String]
        else {
            return nil
        }
        return values.first { fullMatch($0, pattern: pattern) }
    }

    private func fullMatch(_ value: String, pattern: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern)
        else {
            return false
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private func javaScriptString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let value = value as? String { return value }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return String(describing: value)
    }

    private func finish(
        value: String,
        kind: SourceDynamicWebCompletionKind
    ) async {
        let finalValue = webView.url?.absoluteString
            ?? request.url.absoluteString
        guard let finalURL = try? HTTPURL(finalValue) else {
            finish(throwing: WKSourceDynamicWebError.invalidURL)
            return
        }
        let cookie = await serializedCookies()
        finish(
            returning: SourceDynamicWebPageResult(
                finalURL: finalURL,
                value: value,
                completionKind: kind,
                webCookie: cookie
            )
        )
    }

    private func finish(returning result: SourceDynamicWebPageResult) {
        guard let continuation else { return }
        self.continuation = nil
        completionTask?.cancel()
        completionTask = nil
        webView.stopLoading()
        continuation.resume(returning: result)
    }

    private func finish(throwing error: any Error) {
        guard let continuation else { return }
        self.continuation = nil
        completionTask?.cancel()
        completionTask = nil
        webView.stopLoading()
        continuation.resume(throwing: error)
    }

    private func seedRequestCookies() async {
        guard
            let url = URL(string: request.url.absoluteString),
            let host = url.host
        else {
            return
        }
        let header = request.headers.values(for: "cookie")
            .joined(separator: "; ")
        for segment in header.split(separator: ";") {
            let pair = segment.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: String(pair[1]),
                .domain: host,
                .path: "/",
                .secure: url.scheme == "https" ? "TRUE" : "FALSE",
            ]
            if let cookie = HTTPCookie(properties: properties) {
                await webView.configuration.websiteDataStore.httpCookieStore
                    .setCookieAsync(cookie)
            }
        }
    }

    private func serializedCookies() async -> String? {
        let cookies = await webView.configuration.websiteDataStore
            .httpCookieStore.allCookiesAsync()
        let value = cookies
            .sorted { lhs, rhs in lhs.name < rhs.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        return value.isEmpty ? nil : value
    }
}

private extension WKHTTPCookieStore {
    func allCookiesAsync() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }

    func setCookieAsync(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) {
                continuation.resume()
            }
        }
    }
}
