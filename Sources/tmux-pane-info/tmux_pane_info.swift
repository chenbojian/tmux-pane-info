import Foundation
import Darwin

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let isClaude: Bool
}

func getAllProcesses() -> [pid_t: ProcInfo] {
    let bufferSize = proc_listallpids(nil, 0)
    guard bufferSize > 0 else { return [:] }

    var pids = [pid_t](repeating: 0, count: Int(bufferSize))
    let actual = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
    guard actual > 0 else { return [:] }

    var result: [pid_t: ProcInfo] = [:]
    result.reserveCapacity(Int(actual))

    for i in 0..<Int(actual) {
        let pid = pids[i]
        guard pid > 0 else { continue }

        var info = proc_bsdinfo()
        let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard size == MemoryLayout<proc_bsdinfo>.size else { continue }

        let ppid = pid_t(info.pbi_ppid)

        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuf, 4096)
        let isClaude: Bool
        if pathLen > 0 {
            let path = pathBuf.prefix(Int(pathLen)).withUnsafeBufferPointer { buf in
                String(cString: buf.baseAddress!)
            }
            isClaude = path.contains("/claude/")
        } else {
            isClaude = false
        }

        result[pid] = ProcInfo(pid: pid, ppid: ppid, isClaude: isClaude)
    }

    return result
}

func findClaudePanes(panePids: Set<pid_t>, processes: [pid_t: ProcInfo]) -> Set<pid_t> {
    var claudePanes: Set<pid_t> = []

    for (pid, info) in processes {
        guard info.isClaude else { continue }

        var cur = pid
        var visited: Set<pid_t> = []
        while cur > 0 && !visited.contains(cur) {
            if panePids.contains(cur) {
                claudePanes.insert(cur)
                break
            }
            visited.insert(cur)
            guard let parent = processes[cur] else { break }
            cur = parent.ppid
        }
    }

    return claudePanes
}

func getProcessArgs(_ pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size: Int = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

    // KERN_PROCARGS2 layout: [argc: Int32][execpath\0][padding\0...][argv0\0][argv1\0]...
    guard size > MemoryLayout<Int32>.size else { return nil }
    let argc = buf.withUnsafeBufferPointer { ptr in
        ptr.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
    }
    guard argc > 0 else { return nil }

    // Skip past argc and exec_path
    var pos = MemoryLayout<Int32>.size
    while pos < size && buf[pos] != 0 { pos += 1 }
    // Skip null padding
    while pos < size && buf[pos] == 0 { pos += 1 }

    // Collect argv strings
    var args: [String] = []
    var collected: Int32 = 0
    while pos < size && collected < argc {
        let start = pos
        while pos < size && buf[pos] != 0 { pos += 1 }
        let arg = String(bytes: buf[start..<pos], encoding: .utf8) ?? ""
        args.append(arg)
        collected += 1
        pos += 1
    }

    guard !args.isEmpty else { return nil }

    // Use basename of argv[0] + rest of args
    let execName = (args[0] as NSString).lastPathComponent
    var result = execName
    if args.count > 1 {
        result += " " + args[1...].joined(separator: " ")
    }

    if result.count > 40 {
        let idx = result.index(result.startIndex, offsetBy: 37)
        result = String(result[...idx]) + "..."
    }

    return result
}

func getFirstChildArgs(panePid: pid_t, processes: [pid_t: ProcInfo]) -> String? {
    // Find the first child of the pane pid (the foreground process)
    for (_, info) in processes {
        if info.ppid == panePid && info.pid != panePid {
            if let args = getProcessArgs(info.pid) {
                return args
            }
        }
    }
    return nil
}

func getTmuxPanes() -> [(id: String, windowName: String, pid: pid_t, command: String, path: String)] {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["tmux", "list-panes", "-a", "-F",
                         "#{session_name}:#{window_index}.#{pane_index}\t#{window_name}\t#{pane_pid}\t#{pane_current_command}\t#{pane_current_path}"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var panes: [(id: String, windowName: String, pid: pid_t, command: String, path: String)] = []
    for line in output.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 5 else { continue }
        let pid = pid_t(parts[2]) ?? 0
        panes.append((
            id: String(parts[0]),
            windowName: String(parts[1]),
            pid: pid,
            command: String(parts[3]),
            path: String(parts[4])
        ))
    }

    return panes
}

@main
struct TmuxPaneInfo {
    static func main() {
        let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let panes = getTmuxPanes()
        guard !panes.isEmpty else { return }

        let panePids = Set(panes.map { $0.pid })
        let processes = getAllProcesses()
        let claudePanes = findClaudePanes(panePids: panePids, processes: processes)

        for pane in panes {
            let command: String
            if claudePanes.contains(pane.pid) {
                command = "claude"
            } else if let args = getFirstChildArgs(panePid: pane.pid, processes: processes) {
                command = args
            } else {
                command = pane.command
            }
            var path = pane.path
            if !homeDir.isEmpty && path.hasPrefix(homeDir) {
                path = "~" + path.dropFirst(homeDir.count)
            }
            print("\(pane.id)\t\(pane.windowName)\t\(command)\t\(path)")
        }
    }
}
