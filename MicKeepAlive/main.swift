import Cocoa

// 如果已经有一个 MicKeepAlive 在运行，当前实例直接退出，避免多开
if isAnotherInstanceRunning() {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

private func isAnotherInstanceRunning() -> Bool {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", "MicKeepAlive"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    guard let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
        return false
    }
    let pids = output.split(separator: "\n").compactMap { Int($0) }
    return pids.contains { $0 != currentPID }
}
