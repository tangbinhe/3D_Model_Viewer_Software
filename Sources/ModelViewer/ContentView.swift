import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var server: LocalHTTPServer
    @EnvironmentObject private var actionRunner: ActionRunner

    var body: some View {
        Group {
            if let url = server.baseURL {
                WebView(url: url, actionRunner: actionRunner)
            } else {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在启动本地模型播放器…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.04, green: 0.05, blue: 0.08))
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .ignoresSafeArea()
    }
}
