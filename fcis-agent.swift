#!/usr/bin/env swift
import Foundation
import Darwin

// MARK: - Config

enum Config {
    static let ollamaBase = ProcessInfo.processInfo.environment["OLLAMA_HOST"] ?? "http://localhost:11434"
    static let coderModel = "qwen3-coder-30b-fcis"
    static let generalModel = "qwen3-8b-fcis"
    static let coderSignals: Set<String> = [
        "implement", "write", "fix", "generate", "refactor", "code", "snippet",
        "func", "struct", "enum", "class", "protocol", "actor", "extension",
        "async", "await", "throws", "init", "type", "generic", "conform",
        "method", "property", "closure", "build", "compile", "error", "crash",
        "parse", "encode", "decode", "test", "spec", "assert", "mock"
    ]
}

// MARK: - Stderr / Activity indicator

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

// Spinning indicator shown while a tool call executes.
// Writes to stderr; caller must call stop() to erase it before the next printErr.
final class Spinner {
    private let frames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]
    private var idx = 0
    private var label: String
    private var timer: DispatchSourceTimer?

    init(label: String) {
        self.label = label
        let src = DispatchSource.makeTimerSource(queue: .global())
        src.schedule(deadline: .now(), repeating: .milliseconds(80))
        src.setEventHandler { [weak self] in self?.tick() }
        src.resume()
        timer = src
    }

    private func tick() {
        let frame = frames[idx % frames.count]
        idx += 1
        FileHandle.standardError.write(Data("\r\u{1B}[K[fcis-agent] \(frame) \(label)".utf8))
    }

    func stop() {
        timer?.cancel()
        timer = nil
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))  // erase spinner line
    }
}

// MARK: - String helpers

extension String {
    var shellEscaped: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
    var expandingTilde: String { (self as NSString).expandingTildeInPath }
}

func expandPath(_ raw: String) -> URL {
    URL(fileURLWithPath: raw.expandingTilde)
}

// MARK: - AGENTS.md discovery (git-style: walk up from cwd)

func findAgentsMD() -> URL? {
    if let env = ProcessInfo.processInfo.environment["FCIS_AGENTS_MD"] {
        let url = URL(fileURLWithPath: env.expandingTilde)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        let candidate = dir.appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

func loadSystemContext(override: String? = nil) -> String {
    let url: URL?
    if let override {
        url = URL(fileURLWithPath: override.expandingTilde)
    } else {
        url = findAgentsMD()
    }
    guard let url, let content = try? String(contentsOf: url, encoding: .utf8) else {
        printErr("[fcis-agent] WARNING: no AGENTS.md found — using built-in FCIS invariants only")
        return ""
    }
    printErr("[fcis-agent] context=\(url.path)")
    return "# Project Context (\(url.lastPathComponent))\n\n\(content)"
}

// MARK: - Routing

func routeModel(prompt: String) -> String {
    let words = Set(prompt.lowercased().components(separatedBy: .whitespacesAndNewlines))
    return words.intersection(Config.coderSignals).isEmpty ? Config.generalModel : Config.coderModel
}

// MARK: - Shell helper

func runShell(_ command: String, cwd: String? = nil, timeout: Double = 30) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do { try process.run() } catch { return "ERROR: \(error)" }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { process.terminate(); return "ERROR: timed out after \(Int(timeout))s" }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return String((out + err).prefix(8000))
}

// MARK: - HTTP helpers

func syncHTTP(_ request: URLRequest) -> String {
    let sema = DispatchSemaphore(value: 0)
    var result = ""
    URLSession.shared.dataTask(with: request) { data, _, error in
        defer { sema.signal() }
        if let error { result = "ERROR: \(error.localizedDescription)"; return }
        result = String(data: data ?? Data(), encoding: .utf8) ?? "ERROR: non-UTF8 response"
    }.resume()
    sema.wait()
    return String(result.prefix(8000))
}

// MARK: - Ollama API

var thinkSupportCache: [String: Bool] = [:]

// Returns (responseData, errorDescription). Non-200 HTTP status is surfaced as errorDescription.
func _postRaw(url: URL, body: [String: Any]) -> (Data?, String?) {
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
        return (nil, "JSON serialization failed")
    }
    var req = URLRequest(url: url, timeoutInterval: 300)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = bodyData
    let sema = DispatchSemaphore(value: 0)
    var resultData: Data?
    var errorMsg: String?
    URLSession.shared.dataTask(with: req) { data, resp, error in
        defer { sema.signal() }
        if let error { errorMsg = error.localizedDescription; return }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            errorMsg = "HTTP \(http.statusCode): \(String(data: data ?? Data(), encoding: .utf8) ?? "")"
            return
        }
        resultData = data
    }.resume()
    sema.wait()
    return (resultData, errorMsg)
}

func ollamaChat(model: String, messages: [[String: Any]], tools: [[String: Any]]?, think: Bool) -> [String: Any] {
    guard let url = URL(string: "\(Config.ollamaBase)/api/chat") else { return [:] }
    var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
    if let tools, !tools.isEmpty { body["tools"] = tools }

    let wantThink = think && (thinkSupportCache[model] ?? true)
    if wantThink { body["think"] = true }

    func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    let (data, errorMsg) = _postRaw(url: url, body: body)
    if let errorMsg {
        if wantThink && errorMsg.contains("does not support thinking") {
            thinkSupportCache[model] = false
            printErr("[fcis-agent] \(model) does not support thinking — retrying without")
            body.removeValue(forKey: "think")
            let (data2, err2) = _postRaw(url: url, body: body)
            if let err2 { printErr("[fcis-agent] Ollama error: \(err2)"); return [:] }
            return data2.map(parse) ?? [:]
        }
        if errorMsg.contains("Connection refused") || errorMsg.contains("Could not connect") {
            printErr("[fcis-agent] Ollama unreachable — brew services start ollama")
            exit(1)
        }
        printErr("[fcis-agent] Ollama request failed: \(errorMsg)")
        return [:]
    }
    return data.map(parse) ?? [:]
}

// MARK: - Tool implementations

enum ToolError: Error {
    case missingArg(String)
    case unknown(String)
}

func readFileTool(_ args: [String: Any]) throws -> String {
    guard let pathStr = args["path"] as? String else { throw ToolError.missingArg("path") }
    let url = expandPath(pathStr)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return "ERROR: not found or unreadable: \(url.path)"
    }
    if let lines = args["lines"] as? String {
        let parts = lines.components(separatedBy: "-")
        if parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) {
            let all = text.components(separatedBy: "\n")
            return all[max(0, lo - 1)..<min(hi, all.count)].joined(separator: "\n")
        }
    }
    return text
}

func writeFileTool(_ args: [String: Any]) throws -> String {
    guard let pathStr = args["path"] as? String else { throw ToolError.missingArg("path") }
    guard let content = args["content"] as? String else { throw ToolError.missingArg("content") }
    let url = expandPath(pathStr)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
    return "Written \(content.utf8.count) bytes to \(url.path)"
}

func listDirectoryTool(_ args: [String: Any]) throws -> String {
    guard let pathStr = args["path"] as? String else { throw ToolError.missingArg("path") }
    let url = expandPath(pathStr)
    let ext = args["extension"] as? String
    let recursive = (args["recursive"] as? Bool) ?? false
    var cmd = "find \(url.path.shellEscaped)"
    if !recursive { cmd += " -maxdepth 1" }
    if let ext { cmd += " -name \("*.\(ext)".shellEscaped)" }
    return runShell(cmd)
}

func grepCodebaseTool(_ args: [String: Any]) throws -> String {
    guard let pattern = args["pattern"] as? String else { throw ToolError.missingArg("pattern") }
    let path = (args["path"] as? String).map { expandPath($0).path } ?? FileManager.default.currentDirectoryPath
    let ext = args["extension"] as? String
    var cmd = "grep -rn \(pattern.shellEscaped) \(path.shellEscaped)"
    if let ext { cmd += " --include=\("*.\(ext)".shellEscaped)" }
    return runShell(cmd)
}

// Commands the agent must never run — use write_file or targeted tools instead.
let bashBlocklist: [NSRegularExpression] = [
    "rm\\s+(-[a-zA-Z]*r[a-zA-Z]*f?|-[a-zA-Z]*f[a-zA-Z]*r?|--recursive)\\s",
    "rm\\s+--recursive",
    "\\brmdir\\s",
    "\\bgit\\s+clean\\s",
    "\\btuist\\s+clean\\b",
    "\\bxcodebuild\\s+clean\\b",
    "\\bmkfs\\b",
    "\\bdd\\s+if=",
].compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

func isBashBlocked(_ command: String) -> Bool {
    let range = NSRange(command.startIndex..., in: command)
    return bashBlocklist.contains { $0.firstMatch(in: command, range: range) != nil }
}

func bashExecTool(_ args: [String: Any]) throws -> String {
    guard let command = args["command"] as? String else { throw ToolError.missingArg("command") }
    let cwd = (args["cwd"] as? String).map { expandPath($0).path }
    printErr("  [bash_exec] \(command)")
    if isBashBlocked(command) {
        return "ERROR: command blocked — contains a potentially destructive operation: \(command). Use write_file, git operations, or a more targeted command instead."
    }
    return runShell(command, cwd: cwd, timeout: 30)
}

func swiftDiagnosticsTool(_ args: [String: Any]) throws -> String {
    guard let pathStr = args["path"] as? String else { throw ToolError.missingArg("path") }
    return runShell("swiftc -typecheck -swift-version 6 \(expandPath(pathStr).path.shellEscaped) 2>&1", timeout: 60)
}

func swiftBuildTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path } ?? FileManager.default.currentDirectoryPath
    return runShell("swift build 2>&1", cwd: cwd, timeout: 120)
}

func swiftTestTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path } ?? FileManager.default.currentDirectoryPath
    let filterArg = (args["filter"] as? String).map { "--filter \($0.shellEscaped)" } ?? ""
    return runShell("swift test \(filterArg) 2>&1", cwd: cwd, timeout: 120)
}

func gitDiffTool(_ args: [String: Any]) throws -> String {
    let staged = (args["staged"] as? Bool) ?? false
    let fileArg = (args["file"] as? String).map { "-- \($0.shellEscaped)" } ?? ""
    return runShell("git diff \(staged ? "--staged" : "") \(fileArg)")
}

func gitStatusTool(_ args: [String: Any]) throws -> String {
    return runShell("git status --short")
}

func sdkSearchTool(_ args: [String: Any]) throws -> String {
    guard let query = args["query"] as? String else { throw ToolError.missingArg("query") }
    return runShell("find $(xcrun --show-sdk-path 2>/dev/null) \\( -name '*.swiftinterface' -o -name '*.h' \\) 2>/dev/null | xargs grep -l \(query.shellEscaped) 2>/dev/null | head -20", timeout: 60)
}

func webSearchTool(_ args: [String: Any]) throws -> String {
    guard let query = args["query"] as? String else { throw ToolError.missingArg("query") }
    let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
    var req = URLRequest(url: URL(string: "https://duckduckgo.com/html/?q=\(encoded)")!, timeoutInterval: 30)
    req.setValue("fcis-agent/1.0", forHTTPHeaderField: "User-Agent")
    return syncHTTP(req)
}

func webFetchTool(_ args: [String: Any]) throws -> String {
    guard let urlStr = args["url"] as? String else { throw ToolError.missingArg("url") }
    guard let url = URL(string: urlStr) else { return "ERROR: invalid URL: \(urlStr)" }
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.setValue("fcis-agent/1.0", forHTTPHeaderField: "User-Agent")
    return syncHTTP(req)
}


func tuistGenerateTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path }
    return runShell("tuist generate", cwd: cwd, timeout: 120)
}

func tuistInstallTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path }
    return runShell("tuist install", cwd: cwd, timeout: 120)
}

func tuistLintTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path }
    return runShell("tuist lint project", cwd: cwd, timeout: 60)
}

func tuistGraphTool(_ args: [String: Any]) throws -> String {
    let cwd = (args["path"] as? String).map { expandPath($0).path }
    let fmt = args["format"] as? String ?? "json"
    return runShell("tuist graph --format \(fmt)", cwd: cwd, timeout: 60)
}

// Synchronous GET — returns raw response body or "ERROR: ..." string.
func httpGet(url urlStr: String, timeout: Double = 15) -> String {
    guard let url = URL(string: urlStr) else { return "ERROR: invalid URL: \(urlStr)" }
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("fcis-agent/1.0", forHTTPHeaderField: "User-Agent")
    return syncHTTP(req)
}

func formatOpenAPI(spec: [String: Any], endpointFilter: String?, maxChars: Int) -> String {
    var lines: [String] = []
    if let info = spec["info"] as? [String: Any] {
        let title = info["title"] as? String ?? "?"
        let version = info["version"] as? String ?? "?"
        lines.append("API: \(title) v\(version)")
    }
    // Base URL (OpenAPI 3 servers or OpenAPI 2 host)
    if let servers = spec["servers"] as? [[String: Any]],
       let base = servers.first?["url"] as? String {
        lines.append("Base URL: \(base)")
    } else if let host = spec["host"] as? String {
        let base = spec["basePath"] as? String ?? "/"
        lines.append("Base URL: https://\(host)\(base)")
    }
    lines.append("")

    guard let paths = spec["paths"] as? [String: Any] else {
        return lines.joined(separator: "\n")
    }
    for path in paths.keys.sorted() {
        if let filter = endpointFilter, !path.contains(filter) { continue }
        guard let methods = paths[path] as? [String: Any] else { continue }
        for method in methods.keys.sorted() {
            guard method != "parameters",
                  let op = methods[method] as? [String: Any] else { continue }
            let summary = op["summary"] as? String ?? op["operationId"] as? String ?? ""
            lines.append("\(method.uppercased()) \(path)\(summary.isEmpty ? "" : " — \(summary)")")
            for param in (op["parameters"] as? [[String: Any]] ?? []) {
                let name = param["name"] as? String ?? "?"
                let loc  = param["in"]   as? String ?? "?"
                let req  = (param["required"] as? Bool ?? false) ? " (required)" : ""
                let ptype = (param["schema"] as? [String: Any])?["type"] as? String
                         ?? param["type"] as? String ?? "?"
                lines.append("  param [\(loc)] \(name): \(ptype)\(req)")
            }
            if let rb = op["requestBody"] as? [String: Any],
               let content = rb["content"] as? [String: Any] {
                for (ct, media) in content {
                    if let schema = (media as? [String: Any])?["schema"],
                       let schemaData = try? JSONSerialization.data(withJSONObject: schema),
                       let schemaStr = String(data: schemaData, encoding: .utf8) {
                        lines.append("  body (\(ct)): \(String(schemaStr.prefix(200)))")
                    }
                }
            }
            for (code, resp) in (op["responses"] as? [String: Any] ?? [:]) {
                let desc = (resp as? [String: Any])?["description"] as? String ?? ""
                lines.append("  → \(code): \(desc)")
            }
            lines.append("")
        }
    }
    return String(lines.joined(separator: "\n").prefix(maxChars))
}

func apiDocsFetchTool(_ args: [String: Any]) throws -> String {
    guard let urlStr = args["url"] as? String else { throw ToolError.missingArg("url") }
    let endpointFilter = args["endpoint"] as? String
    let maxChars = args["max_chars"] as? Int ?? 12000

    // Attempt 1: fetch the provided URL
    let raw = httpGet(url: urlStr)
    if raw.hasPrefix("ERROR:") { return raw }

    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
       let data = raw.data(using: .utf8),
       let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       spec["paths"] != nil || spec["openapi"] != nil || spec["swagger"] != nil {
        return formatOpenAPI(spec: spec, endpointFilter: endpointFilter, maxChars: maxChars)
    }

    // Attempt 2: probe common OpenAPI spec paths
    let root = urlStr.hasSuffix("/") ? String(urlStr.dropLast()) : urlStr
    for suffix in ["/openapi.json", "/swagger.json", "/api-docs",
                   "/v3/api-docs", "/swagger/v1/swagger.json", "/api/openapi.json"] {
        let candidate = httpGet(url: root + suffix, timeout: 8)
        if candidate.hasPrefix("ERROR:") { continue }
        if let data = candidate.data(using: .utf8),
           let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           spec["paths"] != nil {
            return formatOpenAPI(spec: spec, endpointFilter: endpointFilter, maxChars: maxChars)
        }
    }

    // Fallback: plain text
    return String(raw.prefix(maxChars))
}

func executeTool(name: String, args: [String: Any]) -> String {
    do {
        switch name {
        case "read_file":         return try readFileTool(args)
        case "write_file":        return try writeFileTool(args)
        case "bash_exec":         return try bashExecTool(args)
        case "list_directory":    return try listDirectoryTool(args)
        case "grep_codebase":     return try grepCodebaseTool(args)
        case "swift_diagnostics": return try swiftDiagnosticsTool(args)
        case "swift_build":       return try swiftBuildTool(args)
        case "swift_test":        return try swiftTestTool(args)
        case "git_diff":          return try gitDiffTool(args)
        case "git_status":        return try gitStatusTool(args)
        case "sdk_search":        return try sdkSearchTool(args)
        case "web_search":        return try webSearchTool(args)
        case "web_fetch":         return try webFetchTool(args)
        case "tuist_generate":    return try tuistGenerateTool(args)
        case "tuist_install":     return try tuistInstallTool(args)
        case "tuist_lint":        return try tuistLintTool(args)
        case "tuist_graph":       return try tuistGraphTool(args)
        case "api_docs_fetch":    return try apiDocsFetchTool(args)
        default:                  return "ERROR: unknown tool: \(name)"
        }
    } catch {
        return "ERROR: \(error)"
    }
}

// MARK: - Tool schema

func makeTool(_ name: String, _ desc: String, _ params: [(name: String, type: String, required: Bool)]) -> [String: Any] {
    var props: [String: Any] = [:]
    var required: [String] = []
    for p in params {
        props[p.name] = ["type": p.type]
        if p.required { required.append(p.name) }
    }
    return [
        "type": "function",
        "function": [
            "name": name,
            "description": desc,
            "parameters": ["type": "object", "properties": props, "required": required]
        ]
    ]
}

let toolSchema: [[String: Any]] = [
    makeTool("read_file",         "Read a file; supports lines range e.g. \"10-40\"",         [("path","string",true), ("lines","string",false)]),
    makeTool("write_file",        "Write or overwrite a file",                                  [("path","string",true), ("content","string",true)]),
    makeTool("bash_exec",         "Run a shell command (30s timeout, 8KB cap)",                 [("command","string",true), ("cwd","string",false)]),
    makeTool("list_directory",    "List files, optional extension filter or recursive",         [("path","string",true), ("extension","string",false), ("recursive","boolean",false)]),
    makeTool("grep_codebase",     "grep -rn across files with optional extension filter",       [("pattern","string",true), ("path","string",false), ("extension","string",false)]),
    makeTool("swift_diagnostics", "Type-check a .swift file with Swift 6, return errors",      [("path","string",true)]),
    makeTool("swift_build",       "swift build in a project directory (120s timeout)",          [("path","string",false)]),
    makeTool("swift_test",        "swift test with optional --filter (120s timeout)",           [("path","string",false), ("filter","string",false)]),
    makeTool("git_diff",          "Working tree or staged diff, optionally scoped to a file",   [("staged","boolean",false), ("file","string",false)]),
    makeTool("git_status",        "Current modified/staged/untracked files",                    []),
    makeTool("sdk_search",        "Search Apple SDK .swiftinterface and .h headers",            [("query","string",true)]),
    makeTool("web_search",        "DuckDuckGo search",                                          [("query","string",true)]),
    makeTool("web_fetch",         "Fetch a URL as plain text (Swift Evolution, docs, etc.)",    [("url","string",true)]),
    makeTool("tuist_generate",    "Run tuist generate to create/update the Xcode project",        [("path","string",false)]),
    makeTool("tuist_install",     "Run tuist install to fetch manifest Swift Package deps",       [("path","string",false)]),
    makeTool("tuist_lint",        "Run tuist lint project to validate the Tuist manifest",        [("path","string",false)]),
    makeTool("tuist_graph",       "Run tuist graph to emit the dependency graph",                 [("path","string",false), ("format","string",false)]),
    makeTool("api_docs_fetch",    "Fetch REST API docs; auto-detects OpenAPI JSON specs",         [("url","string",true), ("endpoint","string",false), ("max_chars","integer",false)]),
]

// MARK: - Agent loop

struct AgentResult {
    var response: String
    var toolTrace: [[String: Any]]
    var iterationsUsed: Int
    var hitIterationCap: Bool
    var promptTokens: Int
    var evalTokens: Int
}

func runAgent(model: String, prompt: String, system: String, useTools: Bool, think: Bool) -> AgentResult {
    let maxIterations = 10
    var messages: [[String: Any]] = []
    if !system.isEmpty { messages.append(["role": "system", "content": system]) }
    messages.append(["role": "user", "content": prompt])
    let tools: [[String: Any]]? = useTools ? toolSchema : nil

    var toolTrace: [[String: Any]] = []
    var iteration = 0

    while iteration < maxIterations {
        let ollamaResponse = ollamaChat(model: model, messages: messages, tools: tools, think: think)
        if ollamaResponse.isEmpty {
            return AgentResult(response: "ERROR: no response from Ollama — see stderr for details",
                               toolTrace: toolTrace, iterationsUsed: iteration,
                               hitIterationCap: false, promptTokens: 0, evalTokens: 0)
        }

        let msg = ollamaResponse["message"] as? [String: Any] ?? [:]
        let calls = msg["tool_calls"] as? [[String: Any]] ?? []

        if calls.isEmpty {
            let thinking = msg["thinking"] as? String ?? ""
            if !thinking.isEmpty { printErr("\n<think>\n\(thinking)\n</think>\n") }
            let content = msg["content"] as? String ?? ""
            let finalText = content.isEmpty && !thinking.isEmpty ? thinking : content
            let promptTokens = ollamaResponse["prompt_eval_count"] as? Int ?? 0
            let evalTokens   = ollamaResponse["eval_count"] as? Int ?? 0
            return AgentResult(response: finalText, toolTrace: toolTrace,
                               iterationsUsed: iteration, hitIterationCap: false,
                               promptTokens: promptTokens, evalTokens: evalTokens)
        }

        var assistantMsg: [String: Any] = ["role": "assistant"]
        for (k, v) in msg where k != "role" { assistantMsg[k] = v }
        messages.append(assistantMsg)

        for call in calls {
            let fn     = call["function"] as? [String: Any] ?? [:]
            let name   = fn["name"] as? String ?? ""
            let args   = fn["arguments"] as? [String: Any] ?? [:]
            let argsSummary = args.map { k, v -> String in
                let preview = String(describing: v).prefix(60)
                return "\(k)=\(preview)"
            }.joined(separator: ", ")

            let spinner = Spinner(label: "\(name)(\(argsSummary))")
            let start   = Date()
            let result  = executeTool(name: name, args: args)
            let ms      = Int(Date().timeIntervalSince(start) * 1000)
            spinner.stop()

            let isError = result.hasPrefix("ERROR:")
            if isError {
                printErr("[fcis-agent] Tool error (passing to model): \(result)")
            } else {
                printErr("[fcis-agent] ✓ \(name) → \(result.count)b in \(ms)ms")
            }
            toolTrace.append([
                "tool":        name,
                "args":        argsSummary,
                "result_len":  result.count,
                "duration_ms": ms,
                "is_error":    isError,
            ])
            messages.append(["role": "tool", "content": result])
        }
        iteration += 1
    }

    return AgentResult(response: "ERROR: tool loop exceeded \(maxIterations) iterations",
                       toolTrace: toolTrace, iterationsUsed: maxIterations,
                       hitIterationCap: true, promptTokens: 0, evalTokens: 0)
}

// MARK: - Logging

func logSession(model: String, prompt: String, result: AgentResult) {
    let logDir = FileManager.default.currentDirectoryPath + "/.logs"
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd_HHmmss"
    let file = "\(logDir)/\(fmt.string(from: Date()))_\(model).json"
    let entry: [String: Any] = [
        "timestamp":          fmt.string(from: Date()),
        "model":              model,
        "prompt":             prompt,
        "response":           result.response,
        "iterations_used":    result.iterationsUsed,
        "hit_iteration_cap":  result.hitIterationCap,
        "prompt_tokens":      result.promptTokens,
        "eval_tokens":        result.evalTokens,
        "tool_trace":         result.toolTrace,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: entry, options: .prettyPrinted) {
        try? data.write(to: URL(fileURLWithPath: file))
        printErr("[fcis-agent] session logged to \(file)")
    }
}

// MARK: - CLI argument parsing

struct CLIArgs {
    var prompt: String = ""
    var model: String? = nil
    var agentsPath: String? = nil
    var noTools: Bool = false
    var noThink: Bool = false
    var doLog: Bool = false
    var showModel: Bool = false
}

func parseArgs() -> CLIArgs {
    var result = CLIArgs()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--model":
            guard !args.isEmpty else { break }
            let val = args.removeFirst()
            switch val {
            case "coder":   result.model = Config.coderModel
            case "general": result.model = Config.generalModel
            case "auto":    result.model = nil
            default:        result.model = val
            }
        case "--agents":
            guard !args.isEmpty else { break }
            result.agentsPath = args.removeFirst()
        case "--no-tools":   result.noTools = true
        case "--no-think":   result.noThink = true
        case "--log":        result.doLog = true
        case "--show-model": result.showModel = true
        default:
            if !arg.hasPrefix("-") { result.prompt = arg }
        }
    }
    if result.prompt.isEmpty, isatty(STDIN_FILENO) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        result.prompt = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return result
}

// MARK: - Entry point

let cli = parseArgs()

if cli.prompt.isEmpty {
    printErr("Usage: swift fcis-agent.swift [--model coder|general|auto] [--agents PATH] [--no-tools] [--no-think] [--log] [--show-model] \"prompt\"")
    exit(1)
}

let resolvedModel = cli.model ?? routeModel(prompt: cli.prompt)

if cli.showModel {
    print("Routed to: \(resolvedModel)")
    exit(0)
}

let system = loadSystemContext(override: cli.agentsPath)
let result = runAgent(model: resolvedModel, prompt: cli.prompt, system: system, useTools: !cli.noTools, think: !cli.noThink)
print(result.response)

if result.hitIterationCap {
    printErr("[fcis-agent] WARNING: tool loop hit \(result.iterationsUsed)-iteration cap — response may be incomplete")
}
if result.evalTokens > 0 {
    printErr("[fcis-agent] tokens: prompt=\(result.promptTokens) eval=\(result.evalTokens) total=\(result.promptTokens + result.evalTokens)")
}
if cli.doLog { logSession(model: resolvedModel, prompt: cli.prompt, result: result) }
