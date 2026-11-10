import SwiftUI
import WebKit

@MainActor
final class ActionRunner: ObservableObject {
    struct Status {
        let state: String
        let message: String
        let log: String
    }

    var onStatusChange: ((Status) -> Void)?
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var log = ""
    private var status = Status(state: "idle", message: "尚未启动", log: "") {
        didSet { onStatusChange?(status) }
    }

    func publishStatus() {
        onStatusChange?(status)
    }

    func start(liveId: String) {
        guard process == nil else {
            publishStatus()
            return
        }
        if !liveId.isEmpty {
            guard liveId.range(of: "^[0-9]{1,32}$", options: .regularExpression) != nil else {
                status = Status(state: "error", message: "live_id 留空或输入 1–32 位数字", log: log)
                return
            }
        }
        guard let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("scripts/show.sh"),
              FileManager.default.fileExists(atPath: scriptURL.path) else {
            status = Status(state: "error", message: "应用内缺少 Action 启动脚本", log: log)
            return
        }

        log = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = liveId.isEmpty ? [scriptURL.path] : [scriptURL.path, liveId]
        process.currentDirectoryURL = URL(fileURLWithPath: "/Users/hetangbin/AI-Avatar", isDirectory: true)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        readOutput(outputPipe)
        readOutput(errorPipe)
        process.terminationHandler = { [weak self] finishedProcess in
            DispatchQueue.main.async {
                guard let self, self.process === finishedProcess else { return }
                for pipe in [self.outputPipe, self.errorPipe].compactMap({ $0 }) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        self.appendLog(String(decoding: remaining, as: UTF8.self))
                    }
                }
                try? self.inputPipe?.fileHandleForWriting.close()
                self.process = nil
                self.inputPipe = nil
                self.outputPipe = nil
                self.errorPipe = nil
                let code = finishedProcess.terminationStatus
                if self.status.state == "stopping" || code == 0 || code == 130 {
                    self.status = Status(state: "idle", message: "已停止", log: self.log)
                } else {
                    self.status = Status(state: "error", message: "Action 已退出，代码 \(code)", log: self.log)
                }
            }
        }
        status = Status(state: "starting", message: "正在启动 Action…", log: "")
        do {
            try process.run()
            let mode = liveId.isEmpty ? "排练模式" : "live_id \(liveId)"
            status = Status(state: "running", message: "Action 已启动 · \(mode)", log: "")
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            try? inputPipe.fileHandleForWriting.close()
            self.process = nil
            self.inputPipe = nil
            self.outputPipe = nil
            self.errorPipe = nil
            status = Status(state: "error", message: "启动失败：\(error.localizedDescription)", log: "")
        }
    }

    func sendDanmaku(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            status = Status(state: "error", message: "老板弹幕不能为空", log: log)
            return
        }
        guard let process, process.isRunning, let inputPipe else {
            status = Status(state: "error", message: "Action 未运行", log: log)
            return
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data("\(message)\n".utf8))
            status = Status(state: "running", message: "老板弹幕已发送", log: log)
        } catch {
            appendLog("老板弹幕发送失败：\(error.localizedDescription)\n")
            status = Status(state: "running", message: "弹幕发送失败，请查看日志", log: log)
        }
    }

    func stop() {
        guard let process else {
            status = Status(state: "idle", message: "尚未启动", log: log)
            return
        }
        guard process.isRunning else { return }
        status = Status(state: "stopping", message: "正在停止 Action…", log: log)
        process.terminate()
    }

    private func readOutput(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.appendLog(text)
            }
        }
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 12_000 { log = String(log.suffix(12_000)) }
        status = Status(state: status.state, message: status.message, log: log)
    }
}

struct WebView: NSViewRepresentable {
    let url: URL
    let actionRunner: ActionRunner

    func makeCoordinator() -> Coordinator {
        Coordinator(actionRunner: actionRunner)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(coordinator, name: "fullscreen")
        configuration.userContentController.add(coordinator, name: "action")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        coordinator.webView = webView
        actionRunner.onStatusChange = { [weak coordinator] status in
            coordinator?.sendActionStatus(status)
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let actionRunner: ActionRunner

        init(actionRunner: ActionRunner) {
            self.actionRunner = actionRunner
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            let completion = { (response: NSApplication.ModalResponse) in
                completionHandler(response == .OK ? panel.urls : nil)
            }
            if let window = webView.window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "fullscreen" {
                webView?.window?.toggleFullScreen(nil)
                return
            }
            guard message.name == "action",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            switch action {
            case "start":
                actionRunner.start(liveId: body["liveId"] as? String ?? "")
            case "stop":
                actionRunner.stop()
            case "danmaku":
                actionRunner.sendDanmaku(body["text"] as? String ?? "")
            case "status":
                actionRunner.publishStatus()
            default:
                break
            }
        }

        func sendActionStatus(_ status: ActionRunner.Status) {
            let object: [String: Any] = ["state": status.state, "message": status.message, "log": status.log]
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.updateActionStatus(\(json));")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            if url.scheme == "http", url.host == "127.0.0.1", url.port == 8765 {
                return .allow
            }
            if ["http", "https"].contains(url.scheme) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
    }
}
