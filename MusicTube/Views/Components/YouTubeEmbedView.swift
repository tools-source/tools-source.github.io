import SwiftUI
import WebKit

struct YouTubeEmbedView: UIViewRepresentable {
    let videoID: String

    func makeUIView(context: Context) -> PlayerWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = PlayerWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ uiView: PlayerWebView, context: Context) {
        guard uiView.loadedVideoID != videoID else { return }

        uiView.loadedVideoID = videoID
        uiView.loadHTMLString(playerHTML, baseURL: appIdentityURL)
    }

    private var appIdentityURL: URL {
        let bundleID = (Bundle.main.bundleIdentifier ?? "com.codex.musictube").lowercased()
        return URL(string: "https://\(bundleID)")!
    }

    private var playerHTML: String {
        let origin = appIdentityURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")!
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "origin", value: origin),
            URLQueryItem(name: "widget_referrer", value: origin)
        ]

        let embedURL = components.url?.absoluteString ?? "https://www.youtube.com/embed/\(videoID)"

        return """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <style>
            html, body {
              margin: 0;
              padding: 0;
              background: transparent;
              overflow: hidden;
            }
            iframe {
              position: absolute;
              inset: 0;
              width: 100%;
              height: 100%;
              border: 0;
            }
          </style>
        </head>
        <body>
          <iframe
            src="\(embedURL)"
            allow="autoplay; encrypted-media; picture-in-picture"
            allowfullscreen
            referrerpolicy="strict-origin-when-cross-origin">
          </iframe>
        </body>
        </html>
        """
    }
}

final class PlayerWebView: WKWebView {
    var loadedVideoID: String?
}
