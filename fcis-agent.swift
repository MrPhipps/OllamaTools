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

// MARK: - Stderr

func printErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
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

func ollamaChat(model: String, messages: [[String: Any]], tools: [[String: Any]]?, think: Bool) -> [String: Any] {
    guard let url = URL(string: "\(Config.ollamaBase)/api/chat") else { return [:] }
    var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
    if let tools, !tools.isEmpty { body["tools"] = tools }
    if think { body["think"] = true }
    guard let data = try? JSONSerialization.data(withJSONObject: body) else { return [:] }
    var req = URLRequest(url: url, timeoutInterval: 300)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = data
    let sema = DispatchSemaphore(value: 0)
    var response: [String: Any] = [:]
    URLSession.shared.dataTask(with: req) { data, _, error in
        defer { sema.signal() }
        if let error {
            printErr("[fcis-agent] Ollama request failed: \(error.localizedDescription)")
            return
        }
        guard let data else { return }
        response = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }.resume()
    sema.wait()
    return response
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

func bashExecTool(_ args: [String: Any]) throws -> String {
    guard let command = args["command"] as? String else { throw ToolError.missingArg("command") }
    let cwd = (args["cwd"] as? String).map { expandPath($0).path }
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
]

// MARK: - Agent loop

func runAgent(model: String, prompt: String, system: String, useTools: Bool, think: Bool) -> String {
    var messages: [[String: Any]] = []
    if !system.isEmpty { messages.append(["role": "system", "content": system]) }
    messages.append(["role": "user", "content": prompt])
    let tools: [[String: Any]]? = useTools ? toolSchema : nil

    while true {
        let response = ollamaChat(model: model, messages: messages, tools: tools, think: think)
        // Empty dict signals a network/serialization error — ollamaChat already printed why.
        if response.isEmpty { return "ERROR: no response from Ollama — see stderr for details" }

        let msg = response["message"] as? [String: Any] ?? [:]
        let calls = msg["tool_calls"] as? [[String: Any]] ?? []

        if calls.isEmpty {
            let thinking = msg["thinking"] as? String ?? ""
            if !thinking.isEmpty { printErr("\n<think>\n\(thinking)\n</think>\n") }
            let content = msg["content"] as? String ?? ""
            // qwen3 sometimes puts its full answer in <think> and emits empty content.
            return content.isEmpty && !thinking.isEmpty ? thinking : content
        }

        var assistantMsg: [String: Any] = ["role": "assistant"]
        for (k, v) in msg where k != "role" { assistantMsg[k] = v }
        messages.append(assistantMsg)

        for call in calls {
            let fn = call["function"] as? [String: Any] ?? [:]
            let name = fn["name"] as? String ?? ""
            let args = fn["arguments"] as? [String: Any] ?? [:]
            let result = executeTool(name: name, args: args)
            if result.hasPrefix("ERROR:") {
                printErr("[fcis-agent] Tool error (passing to model): \(result)")
            }
            messages.append(["role": "tool", "content": result])
        }
    }
}

// MARK: - Logging

func logSession(model: String, prompt: String, response: String) {
    let logDir = FileManager.default.currentDirectoryPath + "/logs"
    try? FileManager.default.createDirectory(atPath: logDir, withIntermediateDirectories: true)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyyMMdd_HHmmss"
    let file = "\(logDir)/\(fmt.string(from: Date()))_\(model).json"
    let entry: [String: Any] = ["model": model, "prompt": prompt, "response": response]
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
let response = runAgent(model: resolvedModel, prompt: cli.prompt, system: system, useTools: !cli.noTools, think: !cli.noThink)
print(response)

if cli.doLog { logSession(model: resolvedModel, prompt: cli.prompt, response: response) }
