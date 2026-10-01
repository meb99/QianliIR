import AppKit
import Foundation
import ThermalCore

/// Checks GitHub for a newer build, downloads it and replaces the running app.
@MainActor
final class Updater: ObservableObject {
    static let releaseBase = URL(string: "https://github.com/meb99/QianliIR/releases/download/mac-latest/")!
    static let releasePage = URL(string: "https://github.com/meb99/QianliIR/releases/tag/mac-latest")!

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var showSheet = false
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "QianliIR.autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "QianliIR.autoUpdate") }
    }

    private var timer: Timer?
    private var downloadObservation: NSKeyValueObservation?

    var localBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    var localVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–" }

    var available: UpdateManifest? {
        if case .available(let m) = state { return m }
        return nil
    }

    /// Checks at launch and then every six hours.
    func startAutomaticChecks() {
        guard timer == nil else { return }
        if autoCheck { Task { await check(userInitiated: false) } }
        let updater = self
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                guard updater.autoCheck else { return }
                await updater.check(userInitiated: false)
            }
        }
    }

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .installing: return
        default: break
        }
        state = .checking
        if userInitiated { showSheet = true }
        do {
            var req = URLRequest(url: Updater.releaseBase.appendingPathComponent("version.json"))
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            if manifest.isNewer(thanBuild: localBuild) {
                state = .available(manifest)
                showSheet = true
            } else {
                state = .upToDate
            }
        } catch {
            state = userInitiated ? .failed("Update-Prüfung fehlgeschlagen: \(error.localizedDescription)") : .idle
        }
    }

    func install() {
        guard let manifest = available else { return }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            state = .failed("Die App läuft nicht aus einem .app-Paket – bitte manuell aktualisieren.")
            return
        }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("Keine Schreibrechte in „\(appURL.deletingLastPathComponent().path)“. Bitte die neue Version über die Download-Seite installieren.")
            return
        }
        state = .downloading(0)
        let url = Updater.releaseBase.appendingPathComponent(manifest.zip)
        let updater = self
        let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
            // Move the file before this callback returns, the temp file is deleted afterwards.
            var result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let tmp, (response as? HTTPURLResponse)?.statusCode == 200 {
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent("QianLiIR-Update-\(UUID().uuidString).zip")
                do {
                    try FileManager.default.moveItem(at: tmp, to: keep)
                    result = .success(keep)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(UpdateError.server)
            }
            let final = result
            Task { @MainActor in updater.downloaded(final, appURL: appURL) }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in
                if case .downloading = updater.state { updater.state = .downloading(f) }
            }
        }
        task.resume()
    }

    private func downloaded(_ result: Result<URL, Error>, appURL: URL) {
        downloadObservation = nil
        switch result {
        case .failure(let e):
            state = .failed("Download fehlgeschlagen: \(e.localizedDescription)")
        case .success(let zip):
            state = .installing
            do {
                try replaceAndRelaunch(zip: zip, appURL: appURL)
            } catch {
                state = .failed("Installation fehlgeschlagen: \(error.localizedDescription)")
            }
        }
    }

    /// Unpacks the new app next to the old one, then a small shell script swaps them
    /// as soon as this process has quit and starts the new version.
    private func replaceAndRelaunch(zip: URL, appURL: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("QianLiIR-Update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.badArchive }
        try run("/usr/bin/codesign", ["--verify", newApp.path])

        // Stage inside the target folder so the final swap is a rename on the same disk.
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".QianLiIR-update.app")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: newApp, to: staged)

        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$OLD" && mv "$NEW" "$OLD"
        xattr -dr com.apple.quarantine "$OLD" 2>/dev/null
        open "$OLD"
        rm -rf "$WORK" "$ZIP"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.environment = ["OLD": appURL.path, "NEW": staged.path, "WORK": work.path, "ZIP": zip.path,
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        try p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.tool(URL(fileURLWithPath: tool).lastPathComponent) }
    }

    enum UpdateError: LocalizedError {
        case server, badArchive, tool(String)
        var errorDescription: String? {
            switch self {
            case .server: return "Server nicht erreichbar"
            case .badArchive: return "Update-Paket ist beschädigt"
            case .tool(let t): return "\(t) meldet einen Fehler"
            }
        }
    }
}
