import Darwin
import Foundation

/// Runs the same checked render planner as the MCP tool, without handing exact timeline edits
/// to an AI conversation. The detached renderer continues in Cutmark's existing Jobs board.
enum TimelineRender {
    enum Failure: LocalizedError {
        case invalidDraft
        case missingServer
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidDraft: "The timeline changed unexpectedly. Reopen the editor and try again."
            case .missingServer: "The Cutmark render helper is missing from this app."
            case .unavailable(let detail): detail
            }
        }
    }

    /// Only the canonical raw recipe or the ordered operations on a published base cross this
    /// boundary. Replaying prevents a stale or malformed draft from rendering a different cut.
    static func request(draft: EditTimelineDraft, session: URL) throws -> Data {
        guard !draft.segments.isEmpty else { throw Failure.invalidDraft }
        var replay = EditTimelineDraft(base: draft.base, fps: draft.fps,
                                      source: draft.source, segments: draft.source)
        for action in draft.actions {
            guard replay.apply(action) else { throw Failure.invalidDraft }
        }
        guard replay.segments == draft.segments else { throw Failure.invalidDraft }
        var payload: [String: Any] = ["session": session.standardizedFileURL.path]
        if draft.isRawTake {
            guard let recipe = draft.initialRecipe() else { throw Failure.invalidDraft }
            payload["recipe"] = recipe
        } else {
            guard !draft.actions.isEmpty, draft.base.hasPrefix("edits/"),
                  let data = try? JSONEncoder().encode(draft.actions),
                  let actions = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { throw Failure.invalidDraft }
            payload["base"] = draft.base
            payload["actions"] = actions
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    /// Returns a job id as soon as the backend starts its detached render. Original footage and
    /// published recipe versions remain intact; the user reviews the result before publishing.
    static func start(draft: EditTimelineDraft, session: URL) async throws -> String {
        let payload = try request(draft: draft, session: session)
        guard let script = Bundle.main.url(forResource: "cutmark_mcp", withExtension: "py") else {
            throw Failure.missingServer
        }
        return try await run(request: payload, script: script)
    }

    /// Separate for testing broken pipes, nonzero exits and stalled helpers without a render.
    static func run(request payload: Data, script: URL, timeoutSeconds: Double = 30) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            // Passing a read-only file as stdin avoids SIGPIPE if Python exits before consuming
            // the request. A private temporary folder prevents other users reading the recipe.
            let scratch = FileManager.default.temporaryDirectory.appending(
                path: "cutmark-timeline-render-\(UUID().uuidString)", directoryHint: .isDirectory)
            let file = scratch.appending(path: "request.json")
            do {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                         attributes: [.posixPermissions: 0o700])
                try payload.write(to: file, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: scratch)
                throw Failure.unavailable("Could not prepare the render request: \(error.localizedDescription)")
            }
            defer { try? FileManager.default.removeItem(at: scratch) }
            let input: FileHandle
            do { input = try FileHandle(forReadingFrom: file) }
            catch { throw Failure.unavailable("Could not open the render request: \(error.localizedDescription)") }
            defer { try? input.close() }
            // A regular file for the response avoids waiting for EOF from a detached descendant
            // that inadvertently inherits stdout; the native helper itself has a hard deadline.
            let responseFile = scratch.appending(path: "response.json")
            guard FileManager.default.createFile(atPath: responseFile.path, contents: Data(),
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw Failure.unavailable("Could not prepare the render response.")
            }
            let output: FileHandle
            do { output = try FileHandle(forWritingTo: responseFile) }
            catch { throw Failure.unavailable("Could not open the render response: \(error.localizedDescription)") }
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = [script.path, "--timeline-render"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(Setup.localBin):" +
                (env["PATH"] ?? "/usr/bin:/bin")
            if let root = UserDefaults.standard.string(forKey: "root") {
                env["CUTMARK_ROOT"] = root
            }
            process.environment = env
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { throw Failure.unavailable("Could not launch Cutmark's render helper: \(error.localizedDescription)") }
            let pid = process.processIdentifier
            let limit = max(0.1, timeoutSeconds)
            let deadline = DispatchWorkItem {
                if process.isRunning { _ = Darwin.kill(pid, SIGTERM) }
            }
            let hardStop = DispatchWorkItem {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + limit, execute: deadline)
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + limit + 2, execute: hardStop)
            defer { deadline.cancel(); hardStop.cancel() }
            process.waitUntilExit()
            if process.terminationReason == .uncaughtSignal &&
                (process.terminationStatus == SIGTERM || process.terminationStatus == SIGKILL) {
                throw Failure.unavailable("The render helper did not respond. Try again.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: responseFile.path)[.size]) as? NSNumber
            guard (size?.intValue ?? Int.max) <= 1024 * 1024,
                  let data = try? Data(contentsOf: responseFile) else {
                throw Failure.unavailable("The render helper returned an invalid response.")
            }
            guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unavailable("The render helper did not return a valid result.")
            }
            if let error = response["error"] as? String {
                throw Failure.unavailable(error)
            }
            guard process.terminationStatus == 0,
                  let job = response["job"] as? String, !job.isEmpty else {
                throw Failure.unavailable("Cutmark could not start the render.")
            }
            return job
        }.value
    }
}
