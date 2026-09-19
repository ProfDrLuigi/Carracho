import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Startet den im Carracho-Server-Bundle eingebetteten Python-WebAdmin-Helper.
///
/// Erwarteter Bundle-Pfad:
/// Contents/Helpers/CarrachoWebAdmin/carracho-web-admin-helper
///
/// Ab v8 ist dies ein einzelnes PyInstaller-ONEFILE-Binary. Keine _internal-Siblings.
///
/// Der API-Token wird ausschließlich über die Kindprozess-Umgebung übergeben
/// und taucht damit nicht in der Kommandozeile des Prozesses auf.
final class CarrachoWebAdminService {
    static let shared = CarrachoWebAdminService()

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private(set) var bindAddress = "127.0.0.1"
    private(set) var port = 6781

    var webURL: URL {
        URL(string: "http://\(bindAddress):\(port)/")!
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    private init() {}

    func start(
        token: String,
        upstreamURL: String = "http://127.0.0.1:6780/api/v1",
        bind: String = "127.0.0.1",
        port: Int = 6781
    ) throws {
        guard !isRunning else { return }
        guard token.utf8.count >= 24 else {
            throw NSError(
                domain: "CarrachoWebAdmin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "HTTP-Admin-Token ist kürzer als 24 Bytes"]
            )
        }

        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/CarrachoWebAdmin/carracho-web-admin-helper")

        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NSError(
                domain: "CarrachoWebAdmin",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "WebAdmin-Helper fehlt im App-Bundle: \(helper.path)"]
            )
        }

        self.bindAddress = bind
        self.port = port

        let child = Process()
        child.executableURL = helper
        child.currentDirectoryURL = helper.deletingLastPathComponent()

        var env = ProcessInfo.processInfo.environment
        env["CARRACHO_HTTP_ADMIN_TOKEN"] = token
        env["CARRACHO_HTTP_ADMIN_URL"] = upstreamURL
        env["CARRACHO_WEB_ADMIN_BIND"] = bind
        env["CARRACHO_WEB_ADMIN_PORT"] = String(port)
        child.environment = env

        let out = Pipe()
        let err = Pipe()
        child.standardOutput = out
        child.standardError = err
        stdoutPipe = out
        stderrPipe = err

        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            NSLog("[WebAdmin] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            NSLog("[WebAdmin] %@", line.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        child.terminationHandler = { [weak self] finished in
            NSLog("[WebAdmin] Helper beendet, status=%d", finished.terminationStatus)
            self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self?.process = nil
        }

        try child.run()
        process = child
    }

    /// Bequeme Variante, wenn der Carracho-Server denselben Token bereits aus
    /// CARRACHO_HTTP_ADMIN_TOKEN liest.
    func startFromEnvironment(
        upstreamURL: String = "http://127.0.0.1:6780/api/v1",
        bind: String = "127.0.0.1",
        port: Int = 6781
    ) throws {
        guard let token = ProcessInfo.processInfo.environment["CARRACHO_HTTP_ADMIN_TOKEN"] else {
            throw NSError(
                domain: "CarrachoWebAdmin",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CARRACHO_HTTP_ADMIN_TOKEN fehlt"]
            )
        }
        try start(token: token, upstreamURL: upstreamURL, bind: bind, port: port)
    }

    func stop() {
        guard let child = process else { return }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if child.isRunning {
            child.terminate()
        }
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    #if canImport(AppKit)
    func openInBrowser() {
        NSWorkspace.shared.open(webURL)
    }
    #endif
}
