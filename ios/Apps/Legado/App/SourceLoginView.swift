import AppUseCases
import SourceRuntime
import SwiftUI
import WebKit

struct SourceLoginView: View {
    let source: BookSourceDraft

    @Environment(\.dismiss) private var dismiss
    @State private var reloadRequest = 0
    @State private var completionRequest = 0
    @State private var loading = true
    @State private var currentURL = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            SourceLoginWebView(
                session: SearchEnvironment.makeWebLoginSession(
                    source: source
                ),
                reloadRequest: reloadRequest,
                completionRequest: completionRequest,
                onLoadingChanged: { loading = $0 },
                onURLChanged: { currentURL = $0 },
                onError: { errorMessage = $0 },
                onCompleted: { dismiss() }
            )
            .accessibilityIdentifier("webview.source.login")

            if loading {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .accessibilityIdentifier("progress.source.login")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("label.source.login.error")
            } else if !currentURL.isEmpty {
                Text(currentURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial)
                    .accessibilityIdentifier("label.source.login.url")
            }
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    errorMessage = nil
                    reloadRequest += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("重新加载")
                .accessibilityIdentifier("action.source.login.reload")

                Button("完成") {
                    errorMessage = nil
                    completionRequest += 1
                }
                .accessibilityIdentifier("action.source.login.complete")
            }
        }
        .accessibilityIdentifier("screen.source.login")
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let session: SourceWebLoginSession
    let reloadRequest: Int
    let completionRequest: Int
    let onLoadingChanged: (Bool) -> Void
    let onURLChanged: (String) -> Void
    let onError: (String?) -> Void
    let onCompleted: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            reloadRequest: reloadRequest,
            completionRequest: completionRequest,
            onLoadingChanged: onLoadingChanged,
            onURLChanged: onURLChanged,
            onError: onError,
            onCompleted: onCompleted
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "webview.source.login"
        context.coordinator.start(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateCallbacks(
            onLoadingChanged: onLoadingChanged,
            onURLChanged: onURLChanged,
            onError: onError,
            onCompleted: onCompleted
        )
        context.coordinator.handle(
            reloadRequest: reloadRequest,
            completionRequest: completionRequest,
            in: webView
        )
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let session: SourceWebLoginSession
        private var preparation: SourceWebLoginPreparation?
        private var lastReloadRequest: Int
        private var lastCompletionRequest: Int
        private var finishAfterNavigation = false
        private var onLoadingChanged: (Bool) -> Void
        private var onURLChanged: (String) -> Void
        private var onError: (String?) -> Void
        private var onCompleted: () -> Void

        init(
            session: SourceWebLoginSession,
            reloadRequest: Int,
            completionRequest: Int,
            onLoadingChanged: @escaping (Bool) -> Void,
            onURLChanged: @escaping (String) -> Void,
            onError: @escaping (String?) -> Void,
            onCompleted: @escaping () -> Void
        ) {
            self.session = session
            self.lastReloadRequest = reloadRequest
            self.lastCompletionRequest = completionRequest
            self.onLoadingChanged = onLoadingChanged
            self.onURLChanged = onURLChanged
            self.onError = onError
            self.onCompleted = onCompleted
        }

        func updateCallbacks(
            onLoadingChanged: @escaping (Bool) -> Void,
            onURLChanged: @escaping (String) -> Void,
            onError: @escaping (String?) -> Void,
            onCompleted: @escaping () -> Void
        ) {
            self.onLoadingChanged = onLoadingChanged
            self.onURLChanged = onURLChanged
            self.onError = onError
            self.onCompleted = onCompleted
        }

        func start(in webView: WKWebView) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let preparation = try await session.prepare()
                    self.preparation = preparation
                    await seedCookies(preparation.cookie, in: webView)
                    load(preparation, in: webView)
                } catch {
                    report(error)
                }
            }
        }

        func handle(
            reloadRequest: Int,
            completionRequest: Int,
            in webView: WKWebView
        ) {
            if reloadRequest != lastReloadRequest {
                lastReloadRequest = reloadRequest
                if let preparation {
                    load(preparation, in: webView)
                }
            }
            if completionRequest != lastCompletionRequest {
                lastCompletionRequest = completionRequest
                finishAfterNavigation = true
                if let preparation {
                    load(preparation, in: webView)
                }
            }
        }

        private func load(
            _ preparation: SourceWebLoginPreparation,
            in webView: WKWebView
        ) {
            guard let url = URL(
                string: preparation.loginURL.absoluteString
            ) else {
                report(SourceWebLoginSessionError.invalidLoginURL)
                return
            }
            var request = URLRequest(url: url)
            for field in preparation.headers.fields {
                if field.name == "user-agent" {
                    webView.customUserAgent = field.value
                } else {
                    request.addValue(
                        field.value,
                        forHTTPHeaderField: field.name
                    )
                }
            }
            if !preparation.cookie.isEmpty {
                request.setValue(
                    preparation.cookie,
                    forHTTPHeaderField: "Cookie"
                )
            }
            webView.load(request)
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            onLoadingChanged(true)
            onError(nil)
            onURLChanged(webView.url?.absoluteString ?? "")
            synchronizeCookies(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            onLoadingChanged(false)
            onURLChanged(webView.url?.absoluteString ?? "")
            synchronizeCookies(
                from: webView,
                completeAfterSync: finishAfterNavigation
            )
            finishAfterNavigation = false
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            onLoadingChanged(false)
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            onLoadingChanged(false)
            report(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler:
                @escaping @MainActor @Sendable
                (WKNavigationActionPolicy) -> Void
        ) {
            guard
                let scheme = navigationAction.request.url?.scheme?
                    .lowercased(),
                scheme == "http" || scheme == "https"
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func seedCookies(
            _ rawCookie: String,
            in webView: WKWebView
        ) async {
            guard
                let preparation,
                let url = URL(string: preparation.loginURL.absoluteString),
                let host = url.host
            else { return }
            for pair in SourceCookieParser.parse(rawCookie) {
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: pair.name,
                    .value: pair.value,
                    .domain: host,
                    .path: "/",
                    .secure: url.scheme == "https" ? "TRUE" : "FALSE",
                ]
                guard let cookie = HTTPCookie(properties: properties) else {
                    continue
                }
                await webView.configuration.websiteDataStore.httpCookieStore
                    .setCookieForLogin(cookie)
            }
        }

        private func synchronizeCookies(
            from webView: WKWebView,
            completeAfterSync: Bool = false
        ) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let cookies = await webView.configuration.websiteDataStore
                    .httpCookieStore.cookiesForLogin()
                let value = cookies
                    .sorted { lhs, rhs in lhs.name < rhs.name }
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                do {
                    try await session.synchronize(browserCookie: value)
                    if completeAfterSync {
                        onCompleted()
                    }
                } catch {
                    report(error)
                }
            }
        }

        private func report(_ error: any Error) {
            onError(String(describing: error))
        }
    }
}

private extension WKHTTPCookieStore {
    func cookiesForLogin() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies {
                continuation.resume(returning: $0)
            }
        }
    }

    func setCookieForLogin(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) {
                continuation.resume()
            }
        }
    }
}
