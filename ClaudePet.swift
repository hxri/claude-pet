import Cocoa
import Network

// ============================================================================
//  Claude Pet — a desktop companion that mirrors your Claude Code sessions,
//  and can visit a friend's pet over the local / peer-to-peer network.
//
//  State comes from two tiny scripts registered in ~/.claude/settings.json:
//    hook.sh        writes sessions/<id>.json on every hook event
//    statusline.sh  writes status/<id>.json  (model, context, cost, limits)
//  Build with ~/.claude/pet/build.sh (plain swiftc, no Xcode project).
// ============================================================================

let home = NSHomeDirectory()
let petHome = home + "/.claude/pet"
let sessionsDir = petHome + "/sessions"
let statusDir = petHome + "/status"
let bundleID = "com.claudepet.app"
let launchAgentPath = home + "/Library/LaunchAgents/" + bundleID + ".plist"
let serviceType = "_claudepet._tcp"
/// CLAUDEPET_PROFILE=<name> runs a second, independent instance (used for testing visits on one Mac).
let profile = ProcessInfo.processInfo.environment["CLAUDEPET_PROFILE"] ?? ""
let defaults: UserDefaults = profile.isEmpty ? UserDefaults.standard : (UserDefaults(suiteName: bundleID + "." + profile) ?? .standard)
let controlDir = petHome + (profile.isEmpty ? "/control" : "/control-" + profile)
let netStatePath = petHome + (profile.isEmpty ? "/net-state.json" : "/net-state-" + profile + ".json")

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// MARK: - Model

enum PetState: Int, Comparable {
    case sleeping = 0, ready, waiting, working, attention
    static func < (a: PetState, b: PetState) -> Bool { return a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .sleeping: return "Sleeping"
        case .ready: return "Ready for a prompt"
        case .waiting: return "Your turn"
        case .working: return "Working"
        case .attention: return "Needs you"
        }
    }
    var color: NSColor {
        switch self {
        case .sleeping: return rgb(142, 142, 147)
        case .ready: return rgb(88, 160, 255)
        case .waiting: return rgb(52, 199, 89)
        case .working: return rgb(255, 159, 10)
        case .attention: return rgb(255, 69, 58)
        }
    }
    var name: String {
        switch self {
        case .sleeping: return "sleeping"
        case .ready: return "ready"
        case .waiting: return "waiting"
        case .working: return "working"
        case .attention: return "attention"
        }
    }
    static func named(_ s: String) -> PetState {
        switch s.lowercased() {
        case "ready": return .ready
        case "waiting": return .waiting
        case "working": return .working
        case "attention": return .attention
        default: return .sleeping
        }
    }
}

struct Session {
    var id: String
    var cwd: String
    var pid: Int32
    var started: Date
    var updated: Date
    var event: String
    var state: PetState = .ready
    var tool: String? = nil
    var detail: String? = nil
    var transcript: String? = nil
    var model: String? = nil
    var contextPct: Double? = nil
    var contextSize: Int? = nil
    var contextTokens: Int? = nil
    var cost: Double? = nil
    var title: String? = nil

    var project: String {
        let last = (cwd as NSString).lastPathComponent
        return last.isEmpty ? cwd : last
    }
    /// What the status card calls the session: its conversation title, else the folder.
    var displayName: String { return title ?? project }
}

struct RateLimit { var usedPct: Double; var resetsAt: Date? }
struct RateLimits { var fiveHour: RateLimit?; var sevenDay: RateLimit?; var updated: Date }

enum Fmt {
    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m ago" }
        return "\(s / 86400)d ago"
    }
    static func duration(_ since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if n >= 1000 { return "\(n / 1000)k" }
        return "\(n)"
    }
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst(7).split(separator: "-").map(String.init)
        guard let first = parts.first else { return id }
        let nums = parts.dropFirst().filter { $0.count <= 2 && Int($0) != nil }
        let name = first.prefix(1).uppercased() + first.dropFirst()
        return nums.isEmpty ? name : name + " " + nums.joined(separator: ".")
    }
    static func resets(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = d.timeIntervalSince(now) < 20 * 3600 ? "HH:mm" : "EEE HH:mm"
        return f.string(from: d)
    }
    static func oneLine(_ s: String, max n: Int) -> String {
        let words = s.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).joined(separator: " ")
        if words.count <= n { return words }
        return String(words.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Session store

final class SessionStore {
    private(set) var sessions: [Session] = []
    private(set) var rateLimits: RateLimits? = nil
    private var transcriptCache: [String: (mtime: Date, model: String?, tokens: Int?)] = [:]
    private var titleCache: [String: (mtime: Date, title: String?)] = [:]
    private let fm = FileManager.default

    /// Most urgent state across sessions (drives the collar tag colour).
    var topState: PetState { return sessions.map { $0.state }.max() ?? .sleeping }

    /// What the pet animates. A pet left alone at the prompt dozes off after a while.
    var petState: PetState {
        let top = topState
        if top == .ready || top == .waiting, let newest = sessions.map({ $0.updated }).max(),
           Date().timeIntervalSince(newest) > 15 * 60 { return .sleeping }
        return top
    }

    func reload() {
        var out: [Session] = []
        let now = Date()
        let names = (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? []
        for name in names where name.hasSuffix(".json") {
            let path = sessionsDir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ev = obj["event"] as? [String: Any] else { continue }
            let pid = Int32(truncatingIfNeeded: (obj["pid"] as? NSNumber)?.intValue ?? 0)
            let updated = Date(timeIntervalSince1970: (obj["ts"] as? NSNumber)?.doubleValue ?? 0)
            let started = Date(timeIntervalSince1970: (obj["started"] as? NSNumber)?.doubleValue ?? updated.timeIntervalSince1970)
            if !processAlive(pid, updated: updated, now: now) {
                try? fm.removeItem(atPath: path)
                try? fm.removeItem(atPath: statusDir + "/" + name)
                continue
            }
            var s = Session(id: String(name.dropLast(5)),
                            cwd: ev["cwd"] as? String ?? "",
                            pid: pid, started: started, updated: updated,
                            event: ev["hook_event_name"] as? String ?? "")
            s.transcript = ev["transcript_path"] as? String
            apply(event: ev, to: &s)
            applyStatus(to: &s)
            if (s.model == nil || s.contextTokens == nil), let t = s.transcript {
                let info = transcriptInfo(t)
                if s.model == nil { s.model = info.model }
                if s.contextTokens == nil { s.contextTokens = info.tokens }
            }
            if let t = s.transcript { s.title = transcriptTitle(t) }
            out.append(s)
        }
        // Sessions that have a status line but no hook event yet, e.g. ones that
        // were already open when the pet was installed.
        let known = Set(out.map { $0.id })
        for name in ((try? fm.contentsOfDirectory(atPath: statusDir)) ?? []) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            if known.contains(id) { continue }
            let path = statusDir + "/" + name
            guard let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            guard pid > 1 else { continue }
            let ts = Date(timeIntervalSince1970: (o["ts"] as? NSNumber)?.doubleValue ?? 0)
            if !processAlive(pid, updated: ts, now: now) { try? fm.removeItem(atPath: path); continue }
            let ws = o["workspace"] as? [String: Any]
            let cwd = (o["cwd"] as? String) ?? (ws?["current_dir"] as? String) ?? ""
            let dur = ((o["cost"] as? [String: Any])?["total_duration_ms"] as? NSNumber)?.doubleValue ?? 0
            var s = Session(id: id, cwd: cwd, pid: pid, started: ts.addingTimeInterval(-dur / 1000), updated: ts, event: "StatusLine")
            s.state = .ready
            s.detail = "No activity seen yet"
            s.transcript = o["transcript_path"] as? String
            applyStatus(to: &s)
            if (s.model == nil || s.contextTokens == nil), let t = s.transcript {
                let info = transcriptInfo(t)
                if s.model == nil { s.model = info.model }
                if s.contextTokens == nil { s.contextTokens = info.tokens }
            }
            if let t = s.transcript { s.title = transcriptTitle(t) }
            out.append(s)
        }
        out.sort { $0.updated > $1.updated }
        sessions = out
        loadRateLimits()
        pruneStatusFiles(now: now)
    }

    private func processAlive(_ pid: Int32, updated: Date, now: Date) -> Bool {
        if pid > 1 {
            if kill(pid, 0) == 0 { return true }
            return errno != ESRCH
        }
        return now.timeIntervalSince(updated) < 12 * 3600
    }

    private func apply(event ev: [String: Any], to s: inout Session) {
        let tool = ev["tool_name"] as? String
        let input = ev["tool_input"] as? [String: Any]
        switch s.event {
        case "SessionStart":
            s.state = .ready
            s.detail = "Session started"
        case "UserPromptSubmit":
            s.state = .working
            if let p = ev["prompt"] as? String, !p.isEmpty { s.detail = "“" + Fmt.oneLine(p, max: 70) + "”" }
        case "PreToolUse":
            s.tool = tool
            s.detail = toolDetail(tool, input)
            s.state = (tool == "AskUserQuestion") ? .attention : .working
        case "PostToolUse", "PostToolUseFailure":
            s.tool = tool
            s.detail = toolDetail(tool, input)
            s.state = .working
        case "PermissionRequest":
            s.state = .attention
            s.tool = tool
            s.detail = "Permission: " + (toolDetail(tool, input) ?? "tool call")
        case "Notification":
            let type = ev["notification_type"] as? String ?? ""
            s.detail = (ev["message"] as? String).map { Fmt.oneLine($0, max: 80) }
            switch type {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                s.state = .attention
            case "idle_prompt", "agent_completed":
                s.state = .waiting
            default:
                s.state = .working
            }
        case "Stop":
            s.state = .waiting
            if let m = ev["last_assistant_message"] as? String, !m.isEmpty { s.detail = Fmt.oneLine(m, max: 80) }
            else { s.detail = "Finished responding" }
        case "StopFailure":
            s.state = .attention
            s.detail = "Error: " + Fmt.oneLine((ev["error"] as? String) ?? "the last turn failed", max: 70)
        case "PreCompact":
            s.state = .working
            s.detail = "Compacting context"
        default:
            s.state = .working
        }
    }

    private func toolDetail(_ tool: String?, _ input: [String: Any]?) -> String? {
        guard let tool = tool else { return nil }
        var arg: String? = nil
        if let i = input {
            if tool == "Bash" || tool == "PowerShell" {
                arg = (i["description"] as? String) ?? (i["command"] as? String)
            } else if let p = i["file_path"] as? String {
                arg = (p as NSString).lastPathComponent
            } else if let p = i["notebook_path"] as? String {
                arg = (p as NSString).lastPathComponent
            } else if let p = i["pattern"] as? String {
                arg = p
            } else if let d = i["description"] as? String {
                arg = d
            } else if let s = i["skill"] as? String {
                arg = s
            } else if let q = i["query"] as? String {
                arg = q
            } else if let u = i["url"] as? String {
                arg = u
            } else if let p = i["prompt"] as? String {
                arg = p
            }
        }
        if let a = arg, !a.isEmpty { return tool + " · " + Fmt.oneLine(a, max: 60) }
        return tool
    }

    private func applyStatus(to s: inout Session) {
        let path = statusDir + "/" + s.id + ".json"
        guard let data = fm.contents(atPath: path),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let m = o["model"] as? [String: Any] {
            s.model = (m["display_name"] as? String) ?? (m["id"] as? String)
        }
        if let c = o["context_window"] as? [String: Any] {
            s.contextPct = (c["used_percentage"] as? NSNumber)?.doubleValue
            s.contextSize = (c["context_window_size"] as? NSNumber)?.intValue
            if let u = c["current_usage"] as? [String: Any] {
                let i = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                let cc = (u["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
                let cr = (u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                if i + cc + cr > 0 { s.contextTokens = i + cc + cr }
            }
        }
        if let c = o["cost"] as? [String: Any] {
            s.cost = (c["total_cost_usd"] as? NSNumber)?.doubleValue
            // The status line knows the real session age; hook files only know when the pet was installed.
            if let dur = (c["total_duration_ms"] as? NSNumber)?.doubleValue, dur > 0,
               let ts = (o["ts"] as? NSNumber)?.doubleValue {
                s.started = min(s.started, Date(timeIntervalSince1970: ts - dur / 1000))
            }
        }
    }

    /// The conversation's title: the latest `custom-title` line, which is what the Claude
    /// desktop app shows in its sidebar and what `/rename` sets. Those lines are re-written
    /// as the conversation goes on, so after one full read only the tail is checked.
    private func transcriptTitle(_ path: String) -> String? {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return nil }
        let cached = titleCache[path]
        if let c = cached, c.mtime == mtime { return c.title }
        guard let fh = FileHandle(forReadingAtPath: path) else { return cached?.title }
        let tail = 64 * 1024
        let seeked = cached != nil && size > tail
        if seeked { fh.seek(toFileOffset: UInt64(size - tail)) }
        var data = fh.readDataToEndOfFile()
        fh.closeFile()
        // Start at a line boundary so a cut multi-byte character can't spoil the decoding.
        if seeked, let nl = data.firstIndex(of: 0x0A) { data = data.subdata(in: (nl + 1)..<data.endIndex) }
        var title = cached?.title
        if let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"custom-title\"") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let t = (o["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !t.isEmpty else { continue }
                title = t
                break
            }
        }
        titleCache[path] = (mtime, title)
        return title
    }

    private func transcriptInfo(_ path: String) -> (model: String?, tokens: Int?) {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue else { return (nil, nil) }
        if let c = transcriptCache[path], c.mtime == mtime { return (c.model, c.tokens) }
        var model: String? = nil
        var tokens: Int? = nil
        if let fh = FileHandle(forReadingAtPath: path) {
            let tail = 512 * 1024
            if size > tail { fh.seek(toFileOffset: UInt64(size - tail)) }
            let data = fh.readDataToEndOfFile()
            fh.closeFile()
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                for line in text.split(separator: "\n").reversed() where line.contains("\"type\":\"assistant\"") {
                    guard let d = line.data(using: .utf8),
                          let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                          let msg = o["message"] as? [String: Any] else { continue }
                    model = msg["model"] as? String
                    if let u = msg["usage"] as? [String: Any] {
                        let i = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                        let cc = (u["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
                        let cr = (u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                        if i + cc + cr > 0 { tokens = i + cc + cr }
                    }
                    break
                }
            }
        }
        transcriptCache[path] = (mtime, model, tokens)
        return (model, tokens)
    }

    private func loadRateLimits() {
        var best: RateLimits? = nil
        let names = (try? fm.contentsOfDirectory(atPath: statusDir)) ?? []
        for name in names where name.hasSuffix(".json") {
            guard let data = fm.contents(atPath: statusDir + "/" + name),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rl = o["rate_limits"] as? [String: Any] else { continue }
            let ts = Date(timeIntervalSince1970: (o["ts"] as? NSNumber)?.doubleValue ?? 0)
            if let b = best, b.updated >= ts { continue }
            func lim(_ k: String) -> RateLimit? {
                guard let d = rl[k] as? [String: Any], let p = (d["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
                let r = (d["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return RateLimit(usedPct: p, resetsAt: r)
            }
            let five = lim("five_hour"), seven = lim("seven_day")
            if five != nil || seven != nil { best = RateLimits(fiveHour: five, sevenDay: seven, updated: ts) }
        }
        rateLimits = best
    }

    private func pruneStatusFiles(now: Date) {
        let live = Set(sessions.map { $0.id + ".json" })
        let names = (try? fm.contentsOfDirectory(atPath: statusDir)) ?? []
        for name in names where name.hasSuffix(".json") && !live.contains(name) {
            let path = statusDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: path), let m = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(m) > 6 * 3600 {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}

// MARK: - Coats

struct Coat {
    let name: String
    let fur: NSColor, furLight: NSColor, furDark: NSColor, belly: NSColor
    let stripe: NSColor?, ear: NSColor, nose: NSColor, blush: NSColor
    let eye: NSColor, pupil: NSColor?, collar: NSColor

    static let all: [Coat] = [
        Coat(name: "Snow", fur: rgb(250, 247, 242), furLight: rgb(255, 255, 255), furDark: rgb(168, 160, 158), belly: rgb(255, 255, 255),
             stripe: nil, ear: rgb(255, 170, 185), nose: rgb(240, 120, 145), blush: rgb(255, 120, 140, 0.4),
             eye: rgb(44, 44, 54), pupil: nil, collar: rgb(255, 143, 171)),
        Coat(name: "Ginger", fur: rgb(244, 164, 92), furLight: rgb(255, 200, 134), furDark: rgb(186, 106, 44), belly: rgb(255, 242, 222),
             stripe: rgb(190, 104, 40, 0.5), ear: rgb(250, 172, 182), nose: rgb(232, 120, 140), blush: rgb(255, 120, 140, 0.42),
             eye: rgb(44, 44, 54), pupil: nil, collar: rgb(46, 196, 182)),
        Coat(name: "Grey", fur: rgb(170, 174, 188), furLight: rgb(204, 208, 220), furDark: rgb(112, 116, 134), belly: rgb(240, 241, 246),
             stripe: rgb(100, 104, 122, 0.45), ear: rgb(250, 172, 182), nose: rgb(225, 120, 140), blush: rgb(255, 120, 140, 0.38),
             eye: rgb(44, 44, 54), pupil: nil, collar: rgb(255, 107, 107)),
        Coat(name: "Black", fur: rgb(60, 60, 72), furLight: rgb(90, 90, 108), furDark: rgb(28, 28, 38), belly: rgb(82, 82, 98),
             stripe: nil, ear: rgb(240, 150, 165), nose: rgb(220, 120, 140), blush: rgb(255, 120, 140, 0.3),
             eye: rgb(176, 232, 120), pupil: rgb(24, 24, 30), collar: rgb(255, 200, 60)),
        Coat(name: "Cream", fur: rgb(246, 231, 206), furLight: rgb(255, 247, 230), furDark: rgb(198, 172, 132), belly: rgb(255, 252, 246),
             stripe: nil, ear: rgb(250, 172, 182), nose: rgb(232, 130, 150), blush: rgb(255, 120, 140, 0.38),
             eye: rgb(80, 130, 200), pupil: rgb(24, 24, 30), collar: rgb(120, 160, 255)),
        Coat(name: "Cocoa", fur: rgb(141, 96, 62), furLight: rgb(178, 126, 84), furDark: rgb(92, 58, 34), belly: rgb(232, 211, 190),
             stripe: rgb(80, 50, 28, 0.45), ear: rgb(240, 160, 170), nose: rgb(90, 55, 45), blush: rgb(255, 120, 140, 0.32),
             eye: rgb(44, 44, 54), pupil: nil, collar: rgb(46, 196, 182)),
    ]
}

// MARK: - Animation

enum EyeStyle { case open, happy, sleep }
enum MouthStyle { case smile, open }

/// Per-frame animation values. Pet specs bind their parts to these channels.
struct Anim {
    var hop: CGFloat = 0, tilt: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1
    var tail: CGFloat = 0                        // -1…1 sway
    var earL: CGFloat = 0, earR: CGFloat = 0     // -1 flat/drooped … 0 neutral … +1 perked
    var pawL: CGFloat = 0, pawR: CGFloat = 0     // 0…1 lift (typing)
    var feet: CGFloat = 0                        // 0…1 while being carried
    var nose: CGFloat = 0                        // -1…1 twitch
    var headTilt: CGFloat = 0                    // -1…1
    var breath: CGFloat = 0, bob: CGFloat = 0, bobFast: CGFloat = 0
    var eyeOpen: CGFloat = 1
    var eyeStyle: EyeStyle = .open
    var eyeScale: CGFloat = 1
    var lookX: CGFloat = 0, lookY: CGFloat = 0
    var mouth: MouthStyle = .smile
    var since: TimeInterval = 0                  // seconds in the current state
}

/// Per-pet animation bookkeeping (blinks, twitches, time in state).
final class AnimDriver {
    private(set) var state: PetState = .sleeping
    private(set) var stateChangedAt: TimeInterval = 0
    private var nextBlink: TimeInterval = 2, blinkStart: TimeInterval = -1
    private var nextTwitch: TimeInterval = 4, twitchStart: TimeInterval = -1

    func set(_ s: PetState, at t: TimeInterval) {
        if s != state { state = s; stateChangedAt = t }
    }

    func compute(t: TimeInterval, hovering: Bool, dragging: Bool, look: CGPoint?) -> Anim {
        var a = Anim()
        let since = t - stateChangedAt
        a.since = since
        let breath = CGFloat(sin(t * 2 * .pi * (state == .sleeping ? 0.2 : 0.38)))
        a.breath = breath
        a.sy = 1 + 0.018 * breath
        a.sx = 1 - 0.007 * breath
        a.bob = CGFloat(sin(t * 2 * .pi * 2))
        a.bobFast = CGFloat(sin(t * 2 * .pi * 5))

        if blinkStart < 0 && t >= nextBlink && state != .sleeping { blinkStart = t }
        if blinkStart >= 0 {
            let p = (t - blinkStart) / 0.16
            if p >= 1 { blinkStart = -1; nextBlink = t + Double.random(in: 2.5...6.5) }
            else { a.eyeOpen = CGFloat(1 - sin(p * .pi)) }
        }
        var twitch: CGFloat = 0
        if twitchStart < 0 && t >= nextTwitch { twitchStart = t }
        if twitchStart >= 0 {
            let p = (t - twitchStart) / 0.3
            if p >= 1 { twitchStart = -1; nextTwitch = t + Double.random(in: 4...11) }
            else { twitch = CGFloat(sin(p * .pi)) }
        }
        if state != .sleeping {
            let ph = t.truncatingRemainder(dividingBy: 3.4)
            if ph < 0.7 { a.nose = CGFloat(sin(ph * 2 * .pi * 7)) }
        }
        if let l = look, state != .sleeping { a.lookX = l.x; a.lookY = l.y }
        else { a.lookX = CGFloat(sin(t * 0.5)) * 1.3; a.lookY = CGFloat(sin(t * 0.33)) * 0.6 }

        switch state {
        case .sleeping:
            a.eyeStyle = .sleep
            a.earL = -1; a.earR = -1
            a.tail = 0.15 * CGFloat(sin(t * 2 * .pi * 0.12))
            a.lookX = 0; a.lookY = 0
            a.headTilt = 1
        case .ready:
            a.tail = 0.4 * CGFloat(sin(t * 2 * .pi * 0.35))
            a.earL = 0.05; a.earR = 0.05 + twitch * 0.6
        case .working:
            a.earL = 0.3 + a.bob * 0.12; a.earR = 0.3 - a.bob * 0.12
            a.tail = 0.7 * CGFloat(sin(t * 2 * .pi * 2.0))
            a.pawL = max(0, a.bobFast); a.pawR = max(0, -a.bobFast)
            a.eyeScale = 0.92
            a.lookY -= 1.3
        case .waiting:
            a.tail = 0.6 * CGFloat(sin(t * 2 * .pi * 0.9))
            a.earL = 0.3; a.earR = 0.3 + twitch * 0.5
            if since < 20 {
                let ph = since.truncatingRemainder(dividingBy: 2.6)
                if ph < 0.45 { a.hop = 14 * CGFloat(sin(ph / 0.45 * .pi)) }
                if ph < 0.9 { a.eyeStyle = .happy }
            }
            let trail = a.hop / 14 * 0.5
            a.earL -= trail; a.earR -= trail
        case .attention:
            a.earL = 1; a.earR = 1
            a.eyeScale = 1.2
            a.tail = CGFloat(sin(t * 2 * .pi * 3.5))
            let ph = t.truncatingRemainder(dividingBy: 3.0)
            if ph < 1.2 { a.tilt = (3.5 * .pi / 180) * CGFloat(sin(ph * 2 * .pi * 5)) }
            a.mouth = .open
        }
        if hovering && !dragging && state != .sleeping {
            a.earL = max(a.earL, 0.7); a.earR = max(a.earR, 0.7)
            a.eyeScale = max(a.eyeScale, 1.08)
        }
        if dragging {
            a.sx = 1.06; a.sy = 0.94
            a.eyeScale = 1.28; a.eyeOpen = 1; a.eyeStyle = .open
            a.earL = -0.6; a.earR = -0.6
            a.tail = -1
            a.feet = 1
            a.mouth = .open
        }
        a.earL = min(1, max(-1, a.earL)); a.earR = min(1, max(-1, a.earR))
        a.tail = min(1, max(-1, a.tail))
        return a
    }
}

// MARK: - Pet spec (data-driven pets: pets/<id>.json, see CLAUDE.md)

struct SpecTransform {
    enum Kind { case rotate, translate, scale }
    var kind: Kind
    var channel: String
    var pivot = CGPoint.zero
    var range: [CGFloat]? = nil      // rotate: degrees at channel -1, 0, +1
    var deg: CGFloat = 0             // rotate: degrees per unit of channel
    var dx: CGFloat = 0, dy: CGFloat = 0
    var sx: CGFloat = 0, sy: CGFloat = 0
}

final class SpecPart {
    var type = "group"
    var show: String? = nil
    var mirror = false
    var anim: [SpecTransform] = []
    var fill: String? = nil
    var gradient: [String]? = nil
    var stroke: String? = nil
    var outline: String? = nil
    var width: CGFloat = 1.5
    var outlineWidth: CGFloat = 0
    var alpha: CGFloat = 1
    var cx: CGFloat = 0, cy: CGFloat = 0, rx: CGFloat = 0, ry: CGFloat = 0, r: CGFloat = 0
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0, radius: CGFloat = 0
    var start: CGFloat = 0, end: CGFloat = 360, size: CGFloat = 1
    var path: CGPath? = nil
    var lines: [[CGFloat]] = []
    var parts: [SpecPart] = []
}

struct PetSpec {
    var id: String
    var name: String
    var palette: [String: NSColor?]
    var layout: PetArtist.Layout
    var parts: [SpecPart]
    var json: String                 // the source text, sent to hosts when visiting

    static let maxBytes = 200_000
    static let standardKeys = ["fur", "furLight", "furDark", "belly", "ear", "nose", "blush", "eye", "pupil", "collar", "stripe"]

    static func load(path: String) -> PetSpec? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return fromData(data)
    }

    static func fromJSON(_ text: String) -> PetSpec? {
        guard let d = text.data(using: .utf8) else { return nil }
        return fromData(d)
    }

    static func fromData(_ data: Data) -> PetSpec? {
        guard data.count <= maxBytes,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(obj, json: String(data: data, encoding: .utf8) ?? "")
    }

    static func parse(_ o: [String: Any], json: String) -> PetSpec? {
        guard let rawParts = o["parts"] as? [[String: Any]], !rawParts.isEmpty else { return nil }
        let id = sanitize(o["id"] as? String ?? "pet", max: 32)
        let name = sanitize(o["name"] as? String ?? id, max: 24)
        var palette: [String: NSColor?] = [:]
        if let p = o["palette"] as? [String: Any] {
            for (k, v) in p {
                if let s = v as? String { palette[k] = hexColor(s) }
                else { palette[k] = .some(nil) }
            }
        }
        let l = o["layout"] as? [String: Any] ?? [:]
        func pt(_ key: String, _ def: CGPoint) -> CGPoint {
            guard let a = l[key] as? [Any], a.count >= 2, let x = num(a[0]), let y = num(a[1]) else { return def }
            return CGPoint(x: x, y: y)
        }
        let headArr = (l["head"] as? [Any]) ?? []
        let hx = headArr.count > 0 ? (num(headArr[0]) ?? 84) : 84
        let hy = headArr.count > 1 ? (num(headArr[1]) ?? 90) : 90
        let hr = headArr.count > 2 ? (num(headArr[2]) ?? 36) : 36
        let layout = PetArtist.Layout(gy: num(l["groundY"]) ?? 18, hx: hx, hy: hy, hr: hr,
                                      bubble: pt("bubble", CGPoint(x: 120, y: 140)), zzz: pt("zzz", CGPoint(x: 122, y: 130)),
                                      badge: pt("badge", CGPoint(x: 120, y: 105)), shadowRX: num(l["shadowRX"]) ?? 36)
        var count = 0
        let parts = rawParts.compactMap { parsePart($0, depth: 0, count: &count) }
        guard !parts.isEmpty else { return nil }
        return PetSpec(id: id, name: name, palette: palette, layout: layout, parts: parts, json: json)
    }

    private static func sanitize(_ s: String, max: Int) -> String {
        let cleaned = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(max))
    }

    static func num(_ v: Any?) -> CGFloat? {
        if let n = v as? NSNumber { let d = n.doubleValue; return d.isFinite ? CGFloat(d) : nil }
        if let s = v as? String, let d = Double(s), d.isFinite { return CGFloat(d) }
        return nil
    }

    private static func parsePart(_ o: [String: Any], depth: Int, count: inout Int) -> SpecPart? {
        count += 1
        guard count <= 600, depth <= 8, let type = o["type"] as? String else { return nil }
        let p = SpecPart()
        p.type = type
        p.show = o["show"] as? String
        p.mirror = (o["mirror"] as? Bool) ?? false
        p.fill = o["fill"] as? String
        p.gradient = o["gradient"] as? [String]
        p.stroke = o["stroke"] as? String
        p.outline = o["outline"] as? String
        p.width = num(o["width"]) ?? 1.5
        p.outlineWidth = num(o["outlineWidth"]) ?? (p.width + 3.5)
        p.alpha = min(1, max(0, num(o["alpha"]) ?? 1))
        p.cx = num(o["cx"]) ?? 0; p.cy = num(o["cy"]) ?? 0
        p.rx = num(o["rx"]) ?? (num(o["r"]) ?? 0); p.ry = num(o["ry"]) ?? p.rx
        p.r = num(o["r"]) ?? p.rx
        p.x = num(o["x"]) ?? 0; p.y = num(o["y"]) ?? 0; p.w = num(o["w"]) ?? 0; p.h = num(o["h"]) ?? 0
        p.radius = num(o["radius"]) ?? 0
        p.start = num(o["start"]) ?? 0; p.end = num(o["end"]) ?? 360
        p.size = num(o["size"]) ?? 1
        if let d = o["d"] as? String { p.path = SVGPath.parse(d) }
        if let ls = o["lines"] as? [[Any]] {
            p.lines = ls.compactMap { l in
                let v = l.compactMap { num($0) }
                return v.count == 4 ? v : nil
            }
        }
        if let anims = o["anim"] as? [[String: Any]] {
            for a in anims {
                var tr: SpecTransform
                if let ch = a["rotate"] as? String {
                    tr = SpecTransform(kind: .rotate, channel: ch)
                    if let r = a["range"] as? [Any], r.count == 3 { tr.range = r.compactMap { num($0) }; if tr.range?.count != 3 { tr.range = nil } }
                    tr.deg = num(a["deg"]) ?? 0
                } else if let ch = a["translate"] as? String {
                    tr = SpecTransform(kind: .translate, channel: ch)
                    tr.dx = num(a["dx"]) ?? 0; tr.dy = num(a["dy"]) ?? 0
                } else if let ch = a["scale"] as? String {
                    tr = SpecTransform(kind: .scale, channel: ch)
                    tr.sx = num(a["sx"]) ?? 0; tr.sy = num(a["sy"]) ?? 0
                } else { continue }
                if let pv = a["pivot"] as? [Any], pv.count >= 2, let px = num(pv[0]), let py = num(pv[1]) { tr.pivot = CGPoint(x: px, y: py) }
                p.anim.append(tr)
            }
        }
        if let kids = o["parts"] as? [[String: Any]] {
            for k in kids { if let c = parsePart(k, depth: depth + 1, count: &count) { p.parts.append(c) } }
        }
        return p
    }

    /// "#RRGGBB" or "#RRGGBBAA".
    static func hexColor(_ s: String) -> NSColor? {
        var h = s.trimmingCharacters(in: .whitespaces)
        guard h.hasPrefix("#") else { return nil }
        h.removeFirst()
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let hasA = h.count == 8
        let r = CGFloat((v >> (hasA ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasA ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasA ? 8 : 0)) & 0xFF) / 255
        let a = hasA ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Recolour with one of the built-in coats (keeps the spec's own colours where the coat has none).
    func applying(coat: Coat) -> PetSpec {
        var s = self
        s.palette["fur"] = coat.fur; s.palette["furLight"] = coat.furLight; s.palette["furDark"] = coat.furDark
        s.palette["belly"] = coat.belly; s.palette["ear"] = coat.ear; s.palette["nose"] = coat.nose
        s.palette["blush"] = coat.blush; s.palette["eye"] = coat.eye; s.palette["pupil"] = .some(coat.pupil)
        s.palette["collar"] = coat.collar; s.palette["stripe"] = .some(coat.stripe)
        return s
    }

    /// Simple sanity report for pet authors.
    func problems() -> [String] {
        var out: [String] = []
        var hasTag = false, hasEye = false
        func walk(_ ps: [SpecPart]) {
            for p in ps {
                if p.type == "tag" { hasTag = true }
                if p.type == "eye" { hasEye = true }
                if !["group", "ellipse", "path", "rect", "arc", "lines", "eye", "tag"].contains(p.type) { out.append("unknown part type \"\(p.type)\"") }
                if p.type == "path" && p.path == nil { out.append("a path part has no valid \"d\"") }
                for c in [p.fill, p.stroke, p.outline].compactMap({ $0 }) + (p.gradient ?? []) {
                    if !c.hasPrefix("#") && palette[c] == nil { out.append("colour \"\(c)\" is neither #hex nor a palette key") }
                }
                walk(p.parts)
            }
        }
        walk(parts)
        if !hasTag { out.append("no \"tag\" part: the status light will be missing") }
        if !hasEye { out.append("no \"eye\" parts: the pet cannot blink or look around") }
        for k in ["fur", "furDark"] where palette[k] == nil { out.append("palette has no \"\(k)\" (coats need the standard keys)") }
        return Array(Set(out)).sorted()
    }
}

/// Minimal SVG path parser: M L H V C Q Z (absolute and relative), numbers separated by spaces or commas.
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        let p = CGMutablePath()
        var nums: [CGFloat] = []
        var cmd: Character = "M"
        var cur = CGPoint.zero
        var startPt = CGPoint.zero
        var ok = false
        var i = d.startIndex
        func flush() {
            var k = 0
            func n(_ j: Int) -> CGFloat { return nums[k + j] }
            let rel = cmd.isLowercase
            let c = Character(cmd.uppercased())
            while true {
                switch c {
                case "M", "L":
                    guard k + 2 <= nums.count else { return }
                    var pt = CGPoint(x: n(0), y: n(1))
                    if rel { pt.x += cur.x; pt.y += cur.y }
                    if c == "M" && k == 0 { p.move(to: pt); startPt = pt } else { p.addLine(to: pt) }
                    cur = pt; k += 2; ok = true
                case "H":
                    guard k + 1 <= nums.count else { return }
                    cur = CGPoint(x: rel ? cur.x + n(0) : n(0), y: cur.y); p.addLine(to: cur); k += 1
                case "V":
                    guard k + 1 <= nums.count else { return }
                    cur = CGPoint(x: cur.x, y: rel ? cur.y + n(0) : n(0)); p.addLine(to: cur); k += 1
                case "C":
                    guard k + 6 <= nums.count else { return }
                    var c1 = CGPoint(x: n(0), y: n(1)), c2 = CGPoint(x: n(2), y: n(3)), e = CGPoint(x: n(4), y: n(5))
                    if rel { c1.x += cur.x; c1.y += cur.y; c2.x += cur.x; c2.y += cur.y; e.x += cur.x; e.y += cur.y }
                    p.addCurve(to: e, control1: c1, control2: c2); cur = e; k += 6
                case "Q":
                    guard k + 4 <= nums.count else { return }
                    var c1 = CGPoint(x: n(0), y: n(1)), e = CGPoint(x: n(2), y: n(3))
                    if rel { c1.x += cur.x; c1.y += cur.y; e.x += cur.x; e.y += cur.y }
                    p.addQuadCurve(to: e, control: c1); cur = e; k += 4
                default:
                    return
                }
                if k >= nums.count { return }
            }
        }
        while i < d.endIndex {
            let ch = d[i]
            if "MLHVCQZmlhvcqz".contains(ch) {
                flush(); nums.removeAll()
                if ch == "Z" || ch == "z" { if ok { p.closeSubpath(); cur = startPt } } else { cmd = ch }
                i = d.index(after: i)
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                i = d.index(after: i)
            } else {
                var j = i
                while j < d.endIndex, "0123456789.-+eE".contains(d[j]) { j = d.index(after: j) }
                guard j > i, let v = Double(d[i..<j]), v.isFinite else { return nil }
                nums.append(CGFloat(v))
                i = j
            }
        }
        flush()
        return ok ? p : nil
    }
}

// MARK: - Pet artist (renders a spec in a 180×190 canvas)

final class PetArtist {
    static let canvas = CGSize(width: 180, height: 190)
    let CX: CGFloat = 84

    struct Layout {
        let gy: CGFloat, hx: CGFloat, hy: CGFloat, hr: CGFloat
        let bubble: CGPoint, zzz: CGPoint, badge: CGPoint, shadowRX: CGFloat
    }

    var spec: PetSpec
    var layout: Layout { return spec.layout }
    var state: PetState = .sleeping
    var tagColor: NSColor = PetState.sleeping.color
    var sessionCount = 0
    var name: String = ""
    var showName = false
    private var dragging = false

    init(spec: PetSpec) { self.spec = spec }

    func draw(_ ctx: CGContext, _ a: Anim, t: TimeInterval, facing: CGFloat, scale: CGFloat) {
        let l = layout
        dragging = a.feet > 0.5
        let lift = min(1, a.hop / 40)
        let srx = l.shadowRX * (1 - lift * 0.25) * scale
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.16 * (1 - lift * 0.6)).cgColor)
        ctx.fillEllipse(in: CGRect(x: CX - srx, y: l.gy - 7.5 * scale, width: 2 * srx, height: 15 * scale))

        ctx.saveGState()
        ctx.translateBy(x: CX, y: l.gy + a.hop)
        ctx.rotate(by: a.tilt)
        ctx.scaleBy(x: a.sx * scale * facing, y: a.sy * scale)
        ctx.translateBy(x: -CX, y: -l.gy)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        for p in spec.parts { drawPart(ctx, p, a, mirrored: false) }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setAlpha(scale)
        drawBubble(ctx, a, t)
        drawBadge(ctx)
        if showName && !name.isEmpty { drawNameTag(ctx, name, at: CGPoint(x: CX, y: l.gy - 13)) }
        ctx.restoreGState()
    }

    // Spec evaluation ---------------------------------------------------------

    private func color(_ key: String?, alpha: CGFloat = 1) -> NSColor? {
        guard let k = key else { return nil }
        var c: NSColor? = nil
        if k.hasPrefix("#") { c = PetSpec.hexColor(k) }
        else if let v = spec.palette[k] { c = v }
        guard let col = c else { return nil }
        return alpha < 1 ? col.withAlphaComponent(col.alphaComponent * alpha) : col
    }

    private func channel(_ name: String, _ a: Anim, mirrored: Bool) -> CGFloat {
        var n = name
        if mirrored {
            if n.hasSuffix("L") { n = String(n.dropLast()) + "R" }
            else if n.hasSuffix("R") { n = String(n.dropLast()) + "L" }
        }
        switch n {
        case "tail": return a.tail
        case "earL": return a.earL
        case "earR": return a.earR
        case "pawL": return a.pawL
        case "pawR": return a.pawR
        case "feet": return a.feet
        case "nose": return a.nose
        case "noseUp": return max(0, a.nose)
        case "headTilt": return a.headTilt
        case "breath": return a.breath
        case "bob": return a.bob
        case "bobFast": return a.bobFast
        case "hop": return a.hop / 14
        case "one": return 1
        default: return 0
        }
    }

    private func visible(_ show: String?, _ a: Anim) -> Bool {
        guard let s = show else { return true }
        switch s {
        case "smile": return a.mouth == .smile
        case "open": return a.mouth == .open
        case "awake": return state != .sleeping
        case "asleep": return state == .sleeping
        case "dragging": return dragging
        case "working": return state == .working
        case "attention": return state == .attention
        case "waiting": return state == .waiting
        case "ready": return state == .ready
        default: return true
        }
    }

    private func drawPart(_ ctx: CGContext, _ p: SpecPart, _ a: Anim, mirrored: Bool) {
        guard visible(p.show, a) else { return }
        drawOnce(ctx, p, a, mirrored: mirrored)
        if p.mirror {
            ctx.saveGState()
            ctx.translateBy(x: CX, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.translateBy(x: -CX, y: 0)
            drawOnce(ctx, p, a, mirrored: !mirrored)
            ctx.restoreGState()
        }
    }

    private func drawOnce(_ ctx: CGContext, _ p: SpecPart, _ a: Anim, mirrored: Bool) {
        ctx.saveGState()
        for tr in p.anim {
            let v = channel(tr.channel, a, mirrored: mirrored)
            switch tr.kind {
            case .rotate:
                var deg: CGFloat
                if let r = tr.range { deg = v < 0 ? r[1] + (r[0] - r[1]) * (-v) : r[1] + (r[2] - r[1]) * v }
                else { deg = v * tr.deg }
                ctx.translateBy(x: tr.pivot.x, y: tr.pivot.y)
                ctx.rotate(by: deg * .pi / 180)
                ctx.translateBy(x: -tr.pivot.x, y: -tr.pivot.y)
            case .translate:
                ctx.translateBy(x: v * tr.dx, y: v * tr.dy)
            case .scale:
                ctx.translateBy(x: tr.pivot.x, y: tr.pivot.y)
                ctx.scaleBy(x: max(0.05, 1 + v * tr.sx), y: max(0.05, 1 + v * tr.sy))
                ctx.translateBy(x: -tr.pivot.x, y: -tr.pivot.y)
            }
        }
        if p.alpha < 1 { ctx.setAlpha(p.alpha) }
        switch p.type {
        case "group":
            for c in p.parts { drawPart(ctx, c, a, mirrored: mirrored) }
        case "ellipse":
            let r = CGRect(x: p.cx - p.rx, y: p.cy - p.ry, width: 2 * p.rx, height: 2 * p.ry)
            fillAndStroke(ctx, CGPath(ellipseIn: r, transform: nil), bounds: r, p)
        case "rect":
            let r = CGRect(x: p.x, y: p.y, width: p.w, height: p.h)
            let rad = min(p.radius, min(p.w, p.h) / 2)
            let path = rad > 0 ? CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) : CGPath(rect: r, transform: nil)
            fillAndStroke(ctx, path, bounds: r, p)
        case "path":
            if let path = p.path { fillAndStroke(ctx, path, bounds: path.boundingBoxOfPath, p) }
        case "arc":
            if let s = color(p.stroke) {
                ctx.setStrokeColor(s.cgColor)
                ctx.setLineWidth(p.width)
                ctx.addArc(center: CGPoint(x: p.cx, y: p.cy), radius: p.r, startAngle: p.start * .pi / 180, endAngle: p.end * .pi / 180, clockwise: false)
                ctx.strokePath()
            }
        case "lines":
            if let s = color(p.stroke) {
                ctx.setStrokeColor(s.cgColor)
                ctx.setLineWidth(p.width)
                for l in p.lines {
                    ctx.move(to: CGPoint(x: l[0], y: l[1]))
                    ctx.addLine(to: CGPoint(x: l[2], y: l[3]))
                }
                ctx.strokePath()
            }
        case "eye":
            drawEye(ctx, p.cx, p.cy, a, size: p.size, mirrored: mirrored)
        case "tag":
            drawTag(ctx, center: CGPoint(x: p.cx, y: p.cy), r: p.r)
        default:
            break
        }
        ctx.restoreGState()
    }

    private func fillAndStroke(_ ctx: CGContext, _ path: CGPath, bounds r: CGRect, _ p: SpecPart) {
        if let o = color(p.outline) {
            ctx.addPath(path); ctx.setStrokeColor(o.cgColor); ctx.setLineWidth(p.outlineWidth); ctx.strokePath()
        }
        if let g = p.gradient, g.count >= 2, let top = color(g[0]), let bottom = color(g[1]) {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            if let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gr, start: CGPoint(x: r.midX, y: r.maxY), end: CGPoint(x: r.midX, y: r.minY), options: [])
            }
            ctx.restoreGState()
        } else if let f = color(p.fill) {
            ctx.addPath(path); ctx.setFillColor(f.cgColor); ctx.fillPath()
        }
        if let s = color(p.stroke) {
            ctx.addPath(path); ctx.setStrokeColor(s.cgColor); ctx.setLineWidth(p.width); ctx.strokePath()
        }
    }

    private func drawEye(_ ctx: CGContext, _ ex: CGFloat, _ ey: CGFloat, _ a: Anim, size: CGFloat, mirrored: Bool) {
        ctx.saveGState()
        if mirrored {   // keep highlights and the gaze direction consistent on both eyes
            ctx.translateBy(x: ex, y: 0); ctx.scaleBy(x: -1, y: 1); ctx.translateBy(x: -ex, y: 0)
        }
        let line = color("furDark") ?? NSColor.black
        let rx: CGFloat = 7.5 * size * a.eyeScale, ry: CGFloat = 9.5 * size * a.eyeScale
        let cx = ex + a.lookX, cy = ey + a.lookY
        ctx.setStrokeColor(line.cgColor)
        var done = false
        switch a.eyeStyle {
        case .sleep:
            ctx.setLineWidth(2.3)
            ctx.move(to: CGPoint(x: ex - rx, y: ey + 1))
            ctx.addQuadCurve(to: CGPoint(x: ex + rx, y: ey + 1), control: CGPoint(x: ex, y: ey - 6))
            ctx.strokePath()
            done = true
        case .happy:
            ctx.setLineWidth(2.5)
            ctx.move(to: CGPoint(x: ex - rx, y: ey - 2))
            ctx.addQuadCurve(to: CGPoint(x: ex + rx, y: ey - 2), control: CGPoint(x: ex, y: ey + 10))
            ctx.strokePath()
            done = true
        case .open:
            break
        }
        if !done && a.eyeOpen < 0.2 {
            ctx.setLineWidth(2.3)
            ctx.move(to: CGPoint(x: ex - rx * 0.9, y: ey))
            ctx.addLine(to: CGPoint(x: ex + rx * 0.9, y: ey))
            ctx.strokePath()
            done = true
        }
        if !done {
            let ery = ry * a.eyeOpen
            ctx.setFillColor((color("eye") ?? rgb(44, 44, 54)).cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ery, width: rx * 2, height: ery * 2))
            if let p = color("pupil") {
                ctx.setFillColor(p.cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - rx * 0.42, y: cy - ery * 0.72, width: rx * 0.84, height: ery * 1.44))
            }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: cx - rx * 0.55, y: cy + ery * 0.12, width: rx * 0.6, height: rx * 0.6))
            ctx.fillEllipse(in: CGRect(x: cx + rx * 0.1, y: cy - ery * 0.45, width: rx * 0.3, height: rx * 0.3))
        }
        ctx.restoreGState()
    }

    private func drawTag(_ ctx: CGContext, center: CGPoint, r: CGFloat) {
        ctx.saveGState()
        if state == .working || state == .attention {
            ctx.setShadow(offset: .zero, blur: 9, color: tagColor.withAlphaComponent(0.95).cgColor)
        }
        let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(tagColor.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: rect)
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r * 0.5, y: center.y + r * 0.15, width: r * 0.42, height: r * 0.42))
    }

    // Bubbles, badge, labels --------------------------------------------------

    func drawNameTag(_ ctx: CGContext, _ text: String, at c: CGPoint) {
        let str = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white])
        let sz = str.size()
        let r = CGRect(x: c.x - sz.width / 2 - 6, y: c.y - sz.height / 2 - 1.5, width: sz.width + 12, height: sz.height + 3)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil))
        ctx.setFillColor(rgb(40, 40, 52, 0.78).cgColor)
        ctx.fillPath()
        str.draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
    }

    func drawText(_ s: String, at c: CGPoint, size: CGFloat, weight: NSFont.Weight = .bold, color: NSColor) {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        let sz = str.size()
        str.draw(at: NSPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
    }

    func speechBubble(_ ctx: CGContext, _ r: CGRect, scale: CGFloat = 1) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        let p = CGMutablePath()
        p.addRoundedRect(in: r, cornerWidth: 10, cornerHeight: 10)
        p.move(to: CGPoint(x: r.minX + 7, y: r.minY + 0.5))
        p.addLine(to: CGPoint(x: r.minX - 3, y: r.minY - 8))
        p.addLine(to: CGPoint(x: r.minX + 18, y: r.minY + 0.5))
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 4, color: NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.addPath(p); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(p); ctx.setStrokeColor(rgb(60, 60, 70, 0.3).cgColor); ctx.setLineWidth(1); ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawBubble(_ ctx: CGContext, _ a: Anim, _ t: TimeInterval) {
        let since = a.since
        let l = layout
        let r = CGRect(x: l.bubble.x, y: l.bubble.y + a.hop, width: 44, height: 26)
        let dark = color("furDark") ?? rgb(80, 80, 90)
        switch state {
        case .working:
            speechBubble(ctx, r)
            ctx.setFillColor(rgb(90, 90, 110).cgColor)
            for i in 0..<3 {
                let bounce = max(0, CGFloat(sin(t * 2 * .pi * 1.4 - Double(i) * 0.9))) * 3.5
                ctx.fillEllipse(in: CGRect(x: r.midX - 10 + CGFloat(i) * 10 - 2.6, y: r.midY - 2.6 - 1.5 + bounce, width: 5.2, height: 5.2))
            }
        case .attention:
            let pulse = 1 + 0.12 * CGFloat(sin(t * 2 * .pi * 2))
            speechBubble(ctx, r, scale: pulse)
            drawText("!", at: CGPoint(x: r.midX + (pulse - 1) * 22, y: r.midY + 1 + (pulse - 1) * 13), size: 19, weight: .heavy, color: PetState.attention.color)
        case .waiting:
            if since < 20 {
                let fade = since > 17 ? CGFloat(20 - since) / 3 : 1
                ctx.saveGState()
                ctx.setAlpha(fade)
                speechBubble(ctx, r)
                drawText("✓", at: CGPoint(x: r.midX, y: r.midY + 1), size: 17, weight: .heavy, color: PetState.waiting.color)
                ctx.restoreGState()
            }
        case .sleeping:
            for i in 0..<3 {
                let ph = (t * 0.4 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let x = l.zzz.x + CGFloat(i) * 9 + 5 * CGFloat(sin(ph * 2 * .pi))
                let y = l.zzz.y + 36 * CGFloat(ph)
                let alpha = CGFloat(sin(ph * .pi))
                drawText("z", at: CGPoint(x: x, y: y), size: 11 + CGFloat(i) * 3.5, weight: .heavy, color: dark.withAlphaComponent(alpha * 0.9))
            }
        case .ready:
            break
        }
    }

    private func drawBadge(_ ctx: CGContext) {
        guard sessionCount > 1 else { return }
        let c = layout.badge
        let rect = CGRect(x: c.x - 9.5, y: c.y - 9.5, width: 19, height: 19)
        ctx.setFillColor(tagColor.cgColor); ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.8); ctx.strokeEllipse(in: rect)
        drawText("\(sessionCount)", at: CGPoint(x: c.x, y: c.y + 0.5), size: 11, weight: .bold, color: .white)
    }
}

extension PetSpec {
    /// Used when no pet file can be loaded at all.
    static let fallback: PetSpec = {
        let j = """
        {"format":1,"id":"blob","name":"Blob",
         "palette":{"fur":"#9ECBFF","furLight":"#D6EBFF","furDark":"#4A7FB5","belly":"#FFFFFF","ear":"#FFB3C6","nose":"#E8788C","blush":"#FF788C66","eye":"#2C2C36","pupil":null,"collar":"#2EC4B6","stripe":null},
         "layout":{"groundY":18,"head":[84,70,40],"bubble":[120,120],"zzz":[122,115],"badge":[118,95],"shadowRX":38},
         "parts":[{"type":"ellipse","cx":84,"cy":60,"rx":40,"ry":42,"gradient":["furLight","fur"],"stroke":"furDark","width":1.6},
                  {"type":"eye","mirror":true,"cx":70,"cy":70,"size":1},
                  {"type":"path","show":"smile","d":"M 77 54 Q 84 48 91 54","stroke":"furDark","width":1.8},
                  {"type":"ellipse","show":"open","cx":84,"cy":52,"rx":3.2,"ry":3.8,"fill":"furDark"},
                  {"type":"tag","cx":84,"cy":22,"r":5.5}]}
        """
        return PetSpec.fromJSON(j) ?? PetSpec(id: "blob", name: "Blob", palette: [:],
                                             layout: PetArtist.Layout(gy: 18, hx: 84, hy: 70, hr: 40, bubble: CGPoint(x: 120, y: 120), zzz: CGPoint(x: 122, y: 115), badge: CGPoint(x: 118, y: 95), shadowRX: 38),
                                             parts: [SpecPart()], json: "{}")
    }()

    /// Loads `pets/<id>.json` from ~/.claude/pet or the app bundle; a path (containing "/") is loaded directly.
    static func builtin(_ idOrPath: String) -> PetSpec? {
        if idOrPath.contains("/") { return load(path: idOrPath) }
        let id = idOrPath.hasSuffix(".json") ? String(idOrPath.dropLast(5)) : idOrPath
        let candidates = [petHome + "/pets/" + id + ".json", (Bundle.main.resourcePath ?? "") + "/pets/" + id + ".json"]
        for c in candidates { if let s = load(path: c) { return s } }
        return nil
    }

    /// The source JSON with the current (possibly recoloured) palette baked in.
    func jsonWithPalette() -> String {
        guard let data = json.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return json }
        var pal: [String: Any] = [:]
        for (k, v) in palette {
            if let c = v { pal[k] = PetSpec.hex(c) } else { pal[k] = NSNull() }
        }
        obj["palette"] = pal
        guard let out = try? JSONSerialization.data(withJSONObject: obj) else { return json }
        return String(data: out, encoding: .utf8) ?? json
    }

    static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        let r = Int(round(s.redComponent * 255)), g = Int(round(s.greenComponent * 255))
        let b = Int(round(s.blueComponent * 255)), a = Int(round(s.alphaComponent * 255))
        return a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
    }
}

// MARK: - Play director (choreographs a visiting pet with the host)

final class PlayDirector {
    enum Kind: CaseIterable { case greet, approach, chase, zoomies, rest, wiggle }
    struct Frame {
        var hostDX: CGFloat = 0, hostHop: CGFloat = 0, hostFacing: CGFloat = 1, hostHappy = false, hostTilt: CGFloat = 0
        var visDX: CGFloat = 0, visHop: CGFloat = 0, visFacing: CGFloat = 1, visHappy = false, visTilt: CGFloat = 0
        var hearts = false
    }
    /// +1 when the visitor's slot is to the right of the host.
    let dir: CGFloat
    private(set) var kind: Kind = .greet
    private var start: TimeInterval
    private var duration: TimeInterval = 2.6
    private static let slot: CGFloat = 180, near: CGFloat = 96

    init(dir: CGFloat, at t: TimeInterval) { self.dir = dir; start = t }

    private func ease(_ p: CGFloat) -> CGFloat { let q = min(max(p, 0), 1); return q * q * (3 - 2 * q) }
    private func hops(_ p: CGFloat, count: CGFloat, height: CGFloat) -> CGFloat { return height * abs(sin(p * count * .pi)) }

    func frame(at t: TimeInterval) -> Frame {
        var p = CGFloat((t - start) / duration)
        if p >= 1 { next(at: t); p = 0 }
        p = max(0, p)
        var f = Frame()
        f.visFacing = dir          // face the host by default
        let travel = PlayDirector.slot - PlayDirector.near
        switch kind {
        case .greet:
            f.visHop = hops(p, count: 3, height: 12)
            if p > 0.45 && p < 0.75 { f.hostHop = 12 * sin((p - 0.45) / 0.3 * .pi) }
            f.visHappy = true; f.hostHappy = true
            f.hearts = p > 0.5
        case .approach:
            if p < 0.35 {
                let q = p / 0.35
                f.visDX = -dir * travel * ease(q)
                f.visHop = hops(q, count: 3, height: 8)
            } else if p < 0.7 {
                f.visDX = -dir * travel
                f.visHappy = true; f.hostHappy = true; f.hearts = true
                f.visTilt = -dir * 6 * .pi / 180
                f.hostTilt = dir * 4 * .pi / 180
            } else {
                let q = (p - 0.7) / 0.3
                f.visDX = -dir * travel * (1 - ease(q))
                f.visHop = hops(q, count: 2, height: 8)
                f.visFacing = -dir
            }
        case .chase:
            let far = PlayDirector.slot + PlayDirector.near
            func crossHop(_ q: CGFloat) -> CGFloat {
                let distToHost = abs(dir * PlayDirector.slot + f.visDX)
                return distToHost < 70 ? 30 * (1 - distToHost / 70) + 6 : hops(q, count: 4, height: 6)
            }
            if p < 0.45 {
                let q = p / 0.45
                f.visDX = -dir * far * ease(q)
                f.visHop = crossHop(q)
            } else if p < 0.55 {
                f.visDX = -dir * far
                f.visFacing = -dir
            } else {
                let q = (p - 0.55) / 0.45
                f.visDX = -dir * far * (1 - ease(q))
                f.visHop = crossHop(q)
                f.visFacing = -dir
            }
            f.hostFacing = (dir * PlayDirector.slot + f.visDX) >= 0 ? -1 : 1
            f.hostHappy = true
        case .zoomies:
            let cyc = (p * 2).truncatingRemainder(dividingBy: 1)
            let tri = 1 - abs(cyc * 2 - 1)
            f.visDX = -dir * travel * tri
            f.visHop = hops(p, count: 10, height: 6)
            f.visFacing = cyc < 0.5 ? dir : -dir
            f.hostHappy = true
        case .rest:
            break
        case .wiggle:
            f.hostTilt = 5 * .pi / 180 * sin(p * 2 * .pi * 2.5)
            f.visTilt = -f.hostTilt
            f.hostHappy = true; f.visHappy = true
        }
        return f
    }

    private func next(at t: TimeInterval) {
        var k = Kind.allCases.randomElement() ?? .rest
        while k == kind { k = Kind.allCases.randomElement() ?? .rest }
        kind = k
        start = t
        switch k {
        case .greet: duration = 2.6
        case .approach: duration = 4.2
        case .chase: duration = 4.6
        case .zoomies: duration = 3.2
        case .rest: duration = Double.random(in: 4...7)
        case .wiggle: duration = 2.4
        }
    }
}

// MARK: - Dance director (Control+Option, the Dance! menu item, or control/dance)

final class DanceDirector {
    enum Move: CaseIterable { case bounce, twist, spin, slide, shimmy, clap }
    struct Frame {
        var hop: CGFloat = 0, tilt: CGFloat = 0, dx: CGFloat = 0, facing: CGFloat = 1
        var sx: CGFloat = 1, sy: CGFloat = 1
        var earL: CGFloat = 0.5, earR: CGFloat = 0.5, tail: CGFloat = 0
        var pawL: CGFloat = 0, pawR: CGFloat = 0
        var sing = false
    }
    let start: TimeInterval
    var holdUntil: TimeInterval
    private let sequence: [Move]
    private let moveLen: TimeInterval = 2.0

    init(at t: TimeInterval, seconds: TimeInterval) {
        start = t
        holdUntil = t + seconds
        sequence = Move.allCases.shuffled()
    }

    var currentMove: Move {
        return sequence[0]
    }

    /// `partner` mirrors the routine so two pets dance as a pair.
    func frame(at t: TimeInterval, partner: Bool = false) -> Frame {
        let el = max(0, t - start)
        let idx = Int(el / moveLen) % sequence.count
        let move = sequence[idx]
        let tt = el + (partner ? 0.25 : 0)
        let beat = tt * 2 * .pi * 2          // 120 bpm
        var f = Frame()
        f.tail = CGFloat(sin(tt * 2 * .pi * 3))
        f.earL = 0.5 + 0.5 * CGFloat(sin(beat))
        f.earR = 0.5 - 0.5 * CGFloat(sin(beat))
        switch move {
        case .bounce:
            f.hop = 12 * abs(CGFloat(sin(tt * 2 * .pi)))
            f.tilt = 8 * .pi / 180 * CGFloat(sin(tt * 2 * .pi))
            f.sing = sin(beat) > 0.6
        case .twist:
            f.tilt = 12 * .pi / 180 * CGFloat(sin(tt * 2 * .pi * 2))
            f.sx = 1 + 0.08 * CGFloat(sin(tt * 2 * .pi * 4))
            f.sy = 1 - 0.08 * CGFloat(sin(tt * 2 * .pi * 4))
            f.hop = 3 * abs(CGFloat(sin(tt * 2 * .pi * 2)))
        case .spin:
            let c = CGFloat(cos(tt * 2 * .pi * 1.5))
            f.facing = c >= 0 ? 1 : -1
            f.sx = 0.45 + 0.55 * abs(c)
            f.hop = 6 * abs(CGFloat(sin(tt * 2 * .pi * 3)))
            f.tilt = 5 * .pi / 180 * CGFloat(sin(tt * 2 * .pi * 2))
        case .slide:
            let c = CGFloat(cos(tt * 2 * .pi * 0.5))
            f.dx = 28 * CGFloat(sin(tt * 2 * .pi * 0.5))
            f.facing = c > 0 ? -1 : 1
            f.hop = 4 * abs(CGFloat(sin(tt * 2 * .pi * 4)))
            f.tilt = -4 * .pi / 180 * c
            f.sing = sin(beat) > 0.6
        case .shimmy:
            f.tilt = 4 * .pi / 180 * CGFloat(sin(tt * 2 * .pi * 8))
            f.sx = 1 + 0.03 * CGFloat(sin(tt * 2 * .pi * 8))
            f.earL = 1; f.earR = 1
            f.hop = 2
        case .clap:
            let c = max(0, CGFloat(sin(tt * 2 * .pi * 3)))
            f.pawL = c; f.pawR = c
            f.hop = 8 * abs(CGFloat(sin(tt * 2 * .pi * 1.5)))
            f.tilt = 6 * .pi / 180 * CGFloat(sin(tt * 2 * .pi * 1.5))
            f.sing = true
        }
        if partner { f.dx = -f.dx; f.tilt = -f.tilt; f.facing = -f.facing }
        return f
    }
}

// MARK: - Pet view (window content: host pet, optional visitor, bed, effects)

final class PetView: NSView {
    static let slotWidth: CGFloat = 180, canvasHeight: CGFloat = 190
    let CX: CGFloat = 84

    var slots = 1 { didSet { needsDisplay = true } }
    var hostSlot = 0
    let host = PetArtist(spec: PetSpec.fallback)
    let hostDriver = AnimDriver()
    private(set) var visitor: PetArtist?
    let visitorDriver = AnimDriver()
    private var director: PlayDirector?
    private(set) var away = false
    private var awayText: String?
    var frozenTime: TimeInterval? = nil
    var onClick: (() -> Void)?
    var onVisitorClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onMoved: (() -> Void)?
    private var lastPlay: PlayDirector.Frame?
    private var dance: DanceDirector?
    private var comboDown = false
    var isDancing: Bool { return dance != nil }

    private struct Scaling { var start: TimeInterval; var appearing: Bool }
    private var hostScaling: Scaling?
    private var hostVisible = true
    private var visitorScaling: Scaling?
    private struct Poof { var x: CGFloat; var start: TimeInterval }
    private var poofs: [Poof] = []
    private var note: (text: String, until: TimeInterval)?

    private let epoch = Date()
    var now: TimeInterval { return frozenTime ?? Date().timeIntervalSince(epoch) }
    private var hovering = false
    private var dragging = false
    private var dragOrigin = NSPoint.zero
    private var windowOrigin = NSPoint.zero
    private var frame30: Timer?
    private var tracking: NSTrackingArea?
    private var frameCount = 0

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        frame30 = t
    }

    private func tick() {
        frameCount += 1
        pollDanceKeys()
        let idle = hostDriver.state == .sleeping && visitor == nil && poofs.isEmpty && hostScaling == nil && !hovering && !dragging && dance == nil
        if idle && frameCount % 3 != 0 { return }
        needsDisplay = true
    }

    /// Control+Option held together starts a dance; it keeps going while held (at least 4 s).
    private func pollDanceKeys() {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let combo = flags.contains(.control) && flags.contains(.option)
        let t = now
        if combo && !comboDown { startDance(seconds: 4) }
        if combo, let d = dance { d.holdUntil = max(d.holdUntil, t + 0.4) }
        comboDown = combo
        if let d = dance, t > d.holdUntil { dance = nil }
    }

    func startDance(seconds: TimeInterval) {
        guard !away else { return }
        if let d = dance { d.holdUntil = max(d.holdUntil, now + seconds); return }
        dance = DanceDirector(at: now, seconds: seconds)
    }

    var canvasSize: CGSize { return CGSize(width: PetView.slotWidth * CGFloat(slots), height: PetView.canvasHeight) }
    func slotX(_ i: Int) -> CGFloat { return CX + CGFloat(i) * PetView.slotWidth }
    var hostX: CGFloat { return slotX(hostSlot) }
    var visitorSlot: Int { return 1 - hostSlot }

    // State changes ------------------------------------------------------------

    func setHostState(_ s: PetState) { hostDriver.set(s, at: now); host.state = s }
    func setVisitorState(_ s: PetState) { visitorDriver.set(s, at: now); visitor?.state = s; visitor?.tagColor = s.color }

    func departHost(label: String) {
        let t = now
        awayText = label
        hostScaling = Scaling(start: t, appearing: false)
        poofs.append(Poof(x: hostX, start: t))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let s = self, let sc = s.hostScaling, !sc.appearing else { return }
            s.hostVisible = false
            s.away = true
            s.hostScaling = nil
        }
    }
    func returnHost() {
        guard away || hostScaling != nil else { return }
        away = false
        awayText = nil
        hostVisible = true
        hostScaling = Scaling(start: now, appearing: true)
        poofs.append(Poof(x: hostX, start: now))
    }
    func arriveVisitor(_ artist: PetArtist, state: PetState) {
        let t = now
        artist.showName = true
        artist.state = state
        artist.tagColor = state.color
        visitor = artist
        visitorDriver.set(state, at: t)
        visitorScaling = Scaling(start: t, appearing: true)
        poofs.append(Poof(x: slotX(visitorSlot), start: t))
        director = PlayDirector(dir: visitorSlot > hostSlot ? 1 : -1, at: t + 0.8)
    }
    func leaveVisitor() {
        guard visitor != nil, visitorScaling?.appearing != false else { return }
        let t = now
        visitorScaling = Scaling(start: t, appearing: false)
        poofs.append(Poof(x: slotX(visitorSlot) + (director?.frame(at: t).visDX ?? 0), start: t))
        director = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let s = self, let sc = s.visitorScaling, !sc.appearing else { return }
            s.visitor = nil
            s.visitorScaling = nil
        }
    }
    func showNote(_ text: String, seconds: Double = 3) { note = (text, now + seconds) }

    // Interaction ------------------------------------------------------------

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override var acceptsFirstResponder: Bool { return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = NSEvent.mouseLocation
        windowOrigin = window?.frame.origin ?? .zero
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - dragOrigin.x, dy = p.y - dragOrigin.y
        if !dragging && hypot(dx, dy) > 3 { dragging = true; NSCursor.closedHand.push() }
        if dragging { window?.setFrameOrigin(NSPoint(x: windowOrigin.x + dx, y: windowOrigin.y + dy)) }
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { NSCursor.pop(); dragging = false; onMoved?() }
        else if visitorHit(event) { onVisitorClick?() }
        else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    private func visitorHit(_ event: NSEvent) -> Bool {
        guard visitor != nil else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let (s, ox, _) = layout()
        let cx = (p.x - ox) / s
        let vx = slotX(visitorSlot) + (lastPlay?.visDX ?? 0)
        let hx = hostX + (lastPlay?.hostDX ?? 0)
        return abs(cx - vx) < abs(cx - hx)
    }

    /// Anchor for the visitor's card: the visiting pet's head.
    var visitorHeadRect: NSRect {
        guard let v = visitor else { return headRect }
        let (s, ox, oy) = layout()
        let l = v.layout
        let vx = slotX(visitorSlot) + (lastPlay?.visDX ?? 0)
        return NSRect(x: ox + (vx - l.hr) * s, y: oy + (l.hy - l.hr) * s, width: 2 * l.hr * s, height: 2 * l.hr * s)
    }

    /// Anchor for the popover: the host pet's head, or its bed while it is away.
    var headRect: NSRect {
        let (s, ox, oy) = layout()
        let l = host.layout
        if away { return NSRect(x: ox + (hostX - 44) * s, y: oy + (l.gy - 14) * s, width: 88 * s, height: 34 * s) }
        return NSRect(x: ox + (hostX - l.hr) * s, y: oy + (l.hy - l.hr) * s, width: 2 * l.hr * s, height: 2 * l.hr * s)
    }
    func layout() -> (CGFloat, CGFloat, CGFloat) {
        let c = canvasSize
        let s = min(bounds.width / c.width, bounds.height / c.height)
        return (s, (bounds.width - c.width * s) / 2, (bounds.height - c.height * s) / 2)
    }

    private func lookVector(forCanvasX x: CGFloat) -> CGPoint? {
        guard let w = window else { return nil }
        let (s, ox, oy) = layout()
        let c = NSPoint(x: w.frame.minX + ox + x * s, y: w.frame.minY + oy + 100 * s)
        let m = NSEvent.mouseLocation
        let dx = m.x - c.x, dy = m.y - c.y
        let dist = hypot(dx, dy)
        guard dist < 520 else { return nil }
        let k = min(1, dist / 220)
        return CGPoint(x: dx / max(dist, 1) * 2.8 * k, y: dy / max(dist, 1) * 2.0 * k)
    }

    // Drawing ----------------------------------------------------------------

    private func scaleFactor(_ sc: Scaling?, _ t: TimeInterval) -> CGFloat {
        guard let sc = sc else { return 1 }
        let p = CGFloat(min(1, max(0, (t - sc.start) / 0.45)))
        let e = p * p * (3 - 2 * p)
        return sc.appearing ? e : 1 - e
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let t = now
        let (s, ox, oy) = layout()
        ctx.saveGState()
        ctx.translateBy(x: ox, y: oy)
        ctx.scaleBy(x: s, y: s)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        let play = director?.frame(at: t)
        lastPlay = play
        let danceH = dance?.frame(at: t)
        let danceV = dance?.frame(at: t, partner: true)
        let hostXNow = hostX + (play?.hostDX ?? 0) + (danceH?.dx ?? 0)
        let visXNow = slotX(visitorSlot) + (play?.visDX ?? 0) + (danceV?.dx ?? 0)

        if away { drawBed(ctx, x: hostX, t: t) }
        if hostVisible {
            var a = hostDriver.compute(t: t, hovering: hovering, dragging: dragging, look: lookVector(forCanvasX: hostXNow))
            if let p = play {
                a.hop += p.hostHop
                a.tilt += p.hostTilt
                if p.hostHappy && a.eyeStyle == .open && hostDriver.state != .attention { a.eyeStyle = .happy }
            }
            var facing = play?.hostFacing ?? 1
            if let d = danceH { applyDance(d, to: &a); facing = d.facing }
            host.showName = visitor != nil
            ctx.saveGState()
            ctx.translateBy(x: hostXNow - CX, y: 0)
            host.draw(ctx, a, t: t, facing: facing, scale: scaleFactor(hostScaling, t))
            ctx.restoreGState()
        }
        if let v = visitor {
            var a = visitorDriver.compute(t: t, hovering: false, dragging: false, look: lookVector(forCanvasX: visXNow))
            if let p = play {
                a.hop += p.visHop
                a.tilt += p.visTilt
                if p.visHappy && a.eyeStyle == .open { a.eyeStyle = .happy }
            }
            var facing = play?.visFacing ?? 1
            if let d = danceV { applyDance(d, to: &a); facing = d.facing }
            ctx.saveGState()
            ctx.translateBy(x: visXNow - CX, y: 0)
            v.draw(ctx, a, t: t, facing: facing, scale: scaleFactor(visitorScaling, t))
            ctx.restoreGState()
        }
        if let p = play, p.hearts { drawHearts(ctx, x: (hostXNow + visXNow) / 2, y: 140, t: t) }
        if dance != nil && hostVisible {
            drawNotes(ctx, x: hostXNow, t: t)
            if visitor != nil { drawNotes(ctx, x: visXNow, t: t + 0.7) }
        }
        drawPoofs(ctx, t)
        drawNote(ctx, t)
        ctx.restoreGState()
    }

    private func applyDance(_ d: DanceDirector.Frame, to a: inout Anim) {
        a.hop += d.hop
        a.tilt += d.tilt
        a.sx *= d.sx
        a.sy *= d.sy
        a.earL = d.earL; a.earR = d.earR
        a.tail = d.tail
        a.pawL = max(a.pawL, d.pawL); a.pawR = max(a.pawR, d.pawR)
        a.headTilt = 0
        if a.eyeOpen > 0.2 { a.eyeStyle = .happy }
        a.mouth = d.sing ? .open : .smile
    }

    private func drawNotes(_ ctx: CGContext, x: CGFloat, t: TimeInterval) {
        let colors = [rgb(255, 107, 138), rgb(138, 107, 255), rgb(255, 170, 60), rgb(60, 190, 160)]
        for i in 0..<4 {
            let ph = (t * 0.55 + Double(i) * 0.25).truncatingRemainder(dividingBy: 1)
            let side: CGFloat = i % 2 == 0 ? -1 : 1
            let nx = x + side * (44 + 8 * CGFloat(sin(ph * 2 * .pi + Double(i))))
            let ny = 70 + 80 * CGFloat(ph)
            let alpha = CGFloat(sin(ph * .pi))
            host.drawText(i % 2 == 0 ? "♪" : "♫", at: CGPoint(x: nx, y: ny), size: 13 + CGFloat(i) * 2, weight: .bold, color: colors[i].withAlphaComponent(alpha))
        }
    }

    private func drawBed(_ ctx: CGContext, x: CGFloat, t: TimeInterval) {
        let gy = host.layout.gy
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.fillEllipse(in: CGRect(x: x - 46, y: gy - 9, width: 92, height: 16))
        let outer = CGRect(x: x - 44, y: gy - 12, width: 88, height: 30)
        ctx.setFillColor(rgb(214, 196, 172).cgColor)
        ctx.fillEllipse(in: outer)
        ctx.setStrokeColor(rgb(168, 148, 122).cgColor)
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: outer)
        ctx.setFillColor(rgb(241, 229, 210).cgColor)
        ctx.fillEllipse(in: CGRect(x: x - 34, y: gy - 6, width: 68, height: 17))
        ctx.setFillColor(rgb(255, 250, 244).cgColor)
        ctx.fillEllipse(in: CGRect(x: x - 30, y: gy - 2, width: 26, height: 11))
        ctx.setStrokeColor(rgb(200, 184, 160).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: x - 30, y: gy - 2, width: 26, height: 11))
        if let label = awayText {
            host.drawNameTag(ctx, label, at: CGPoint(x: x, y: gy + 36))
        }
    }

    private func drawHeart(_ ctx: CGContext, x: CGFloat, y: CGFloat, s: CGFloat, alpha: CGFloat) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x, y: y - s))
        p.addCurve(to: CGPoint(x: x - s, y: y + 0.25 * s), control1: CGPoint(x: x - 0.4 * s, y: y - 0.6 * s), control2: CGPoint(x: x - 1.1 * s, y: y - 0.2 * s))
        p.addCurve(to: CGPoint(x: x, y: y + 0.35 * s), control1: CGPoint(x: x - 0.9 * s, y: y + 0.95 * s), control2: CGPoint(x: x - 0.15 * s, y: y + 0.9 * s))
        p.addCurve(to: CGPoint(x: x + s, y: y + 0.25 * s), control1: CGPoint(x: x + 0.15 * s, y: y + 0.9 * s), control2: CGPoint(x: x + 0.9 * s, y: y + 0.95 * s))
        p.addCurve(to: CGPoint(x: x, y: y - s), control1: CGPoint(x: x + 1.1 * s, y: y - 0.2 * s), control2: CGPoint(x: x + 0.4 * s, y: y - 0.6 * s))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setFillColor(rgb(255, 99, 132, alpha).cgColor)
        ctx.fillPath()
    }

    private func drawHearts(_ ctx: CGContext, x: CGFloat, y: CGFloat, t: TimeInterval) {
        for i in 0..<3 {
            let ph = (t * 0.5 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            let hx = x + CGFloat(i - 1) * 14 + 6 * CGFloat(sin(ph * 2 * .pi + Double(i)))
            let hy = y + 34 * CGFloat(ph)
            drawHeart(ctx, x: hx, y: hy, s: 5 + CGFloat(i) * 1.5, alpha: CGFloat(sin(ph * .pi)) * 0.95)
        }
    }

    private func drawPoofs(_ ctx: CGContext, _ t: TimeInterval) {
        poofs.removeAll { t - $0.start > 0.65 }
        for p in poofs {
            let q = CGFloat(min(1, (t - p.start) / 0.6))
            let e = q * q * (3 - 2 * q)
            for i in 0..<7 {
                let ang = CGFloat(i) / 7 * 2 * .pi + 0.3
                let r = 12 + 30 * e
                let cx = p.x + cos(ang) * r, cy = 62 + sin(ang) * r * 0.6
                let rad = 8 * (1 - q) + 1
                ctx.setFillColor(rgb(225, 225, 232, 0.85 * (1 - q)).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
            }
        }
    }

    private func drawNote(_ ctx: CGContext, _ t: TimeInterval) {
        guard let n = note else { return }
        if t > n.until { note = nil; return }
        let fade = CGFloat(min(1, n.until - t))
        let str = NSAttributedString(string: n.text, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: rgb(50, 50, 60)])
        let sz = str.size()
        let r = CGRect(x: hostX - sz.width / 2 - 8, y: 160, width: sz.width + 16, height: sz.height + 8)
        ctx.saveGState()
        ctx.setAlpha(fade)
        host.speechBubble(ctx, r)
        str.draw(at: NSPoint(x: r.minX + 8, y: r.minY + 4))
        ctx.restoreGState()
    }
}

// MARK: - Status popover

struct VisitInfo {
    let text: String
    let button: String?
    let action: (() -> Void)?
}

final class ClosureButton: NSButton {
    var handler: (() -> Void)?
    @objc func fire() { handler?() }
}

final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { return NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let w = max(6, bounds.width * min(1, max(0, fraction)))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

final class StatusViewController: NSViewController {
    private let stack = NSStackView()
    private let width: CGFloat = 340
    private let inset: CGFloat = 16
    private let padTop: CGFloat = 14, padBottom: CGFloat = 12

    override func loadView() {
        // The root view is sized by its frame (the popover owns it); only the
        // stack carries a fixed width, so nothing can conflict.
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width - 2 * inset),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: inset),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: padTop),
        ])
        let bottom = v.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: padBottom)
        bottom.priority = NSLayoutConstraint.Priority(999)
        bottom.isActive = true
        view = v
    }

    private func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, fixed: Bool = false) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        l.setContentCompressionResistancePriority(fixed ? .required : .defaultLow, for: .horizontal)
        return l
    }
    private func dot(_ c: NSColor, size: CGFloat = 9) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = c.cgColor
        v.layer?.cornerRadius = size / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: size).isActive = true
        v.heightAnchor.constraint(equalToConstant: size).isActive = true
        return v
    }
    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        v.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return v
    }
    private func hrow(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.spacing = spacing
        h.alignment = .centerY
        h.distribution = .fill
        return h
    }
    private func vstack(_ spacing: CGFloat) -> NSStackView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = spacing
        return v
    }
    private func add(_ v: NSView, to parent: NSStackView) {
        parent.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: parent.widthAnchor).isActive = true
    }
    private func separator() -> NSView {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    func render(_ store: SessionStore, visit: VisitInfo?) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let now = Date()
        let n = store.sessions.count
        let top = store.topState

        let title = label("Claude Code", size: 14, weight: .bold)
        let sub = label(n == 0 ? "no sessions" : "\(n) session\(n == 1 ? "" : "s") · \(top.title.lowercased())", size: 12, color: .secondaryLabelColor, fixed: true)
        add(hrow([dot(n == 0 ? PetState.sleeping.color : top.color, size: 10), title, spacer(), sub]), to: stack)

        if let vi = visit {
            let l = label(vi.text, size: 12, color: .secondaryLabelColor)
            l.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            var views: [NSView] = [l]
            if let b = vi.button {
                let btn = ClosureButton(title: b, target: nil, action: nil)
                btn.handler = vi.action
                btn.target = btn
                btn.action = #selector(ClosureButton.fire)
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                btn.setContentHuggingPriority(.required, for: .horizontal)
                btn.setContentCompressionResistancePriority(.required, for: .horizontal)
                views.append(btn)
            }
            add(hrow(views, spacing: 8), to: stack)
        }

        if let rl = store.rateLimits {
            let v = vstack(6)
            let pairs: [(String, RateLimit?)] = [("5-hour", rl.fiveHour), ("Weekly", rl.sevenDay)]
            for (name, lim) in pairs {
                guard let l = lim else { continue }
                let t = label(name, size: 11, weight: .medium, color: .secondaryLabelColor, fixed: true)
                t.widthAnchor.constraint(equalToConstant: 46).isActive = true
                let bar = BarView()
                bar.fraction = CGFloat(l.usedPct / 100)
                bar.color = l.usedPct >= 90 ? PetState.attention.color : (l.usedPct >= 70 ? PetState.working.color : PetState.waiting.color)
                bar.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
                bar.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
                var txt = "\(Int(l.usedPct.rounded()))%"
                if let r = l.resetsAt { txt += " · resets " + Fmt.resets(r, now: now) }
                let val = label(txt, size: 11, color: .tertiaryLabelColor, fixed: true)
                add(hrow([t, bar, val], spacing: 8), to: v)
            }
            if !v.arrangedSubviews.isEmpty {
                add(separator(), to: stack)
                add(v, to: stack)
            }
        }

        add(separator(), to: stack)

        if n == 0 {
            add(label("No Claude Code sessions running.", size: 12, color: .secondaryLabelColor), to: stack)
            add(label("Start one in a terminal and I'll wake up.", size: 12, color: .tertiaryLabelColor), to: stack)
        }
        for s in store.sessions {
            let v = vstack(3)
            let name = label(s.displayName, size: 13, weight: .semibold)
            name.toolTip = s.cwd
            let when = label(Fmt.ago(s.updated, now: now), size: 11, color: .tertiaryLabelColor, fixed: true)
            add(hrow([dot(s.state.color), name, spacer(), when]), to: v)

            let st = label(s.state.title, size: 12, weight: .medium, color: s.state.color, fixed: true)
            let detail = label(s.detail.map { "· " + $0 } ?? "", size: 12, color: .secondaryLabelColor)
            detail.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            add(hrow([st, detail], spacing: 4), to: v)

            var bits: [String] = []
            if let m = s.model { bits.append(Fmt.model(m)) }
            if let p = s.contextPct {
                bits.append("ctx \(Int(p.rounded()))%" + (s.contextSize.map { " of \(Fmt.tokens($0))" } ?? ""))
            } else if let t = s.contextTokens {
                bits.append("ctx \(Fmt.tokens(t))")
            }
            if let c = s.cost, c > 0 { bits.append(String(format: "$%.2f", c)) }
            bits.append("up " + Fmt.duration(s.started, now: now))
            add(label(bits.joined(separator: " · "), size: 11, color: .tertiaryLabelColor), to: v)
            add(v, to: stack)
        }

        add(label("Drag me around · right-click for options", size: 10, color: .quaternaryLabelColor), to: stack)

        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(60, view.fittingSize.height))
        preferredContentSize = size
        if view.window == nil { view.frame.size = size }
    }
}

// MARK: - Nearby pets (Bonjour over local and peer-to-peer Wi-Fi)

struct PetIdentity {
    var id: String
    var name: String
    var owner: String
    var host: String
    var pet: String
    var spec: PetSpec? = nil      // only carried in the "hello" message, not in Bonjour TXT records

    var label: String { return "\(name) (\(owner))" }
    var dict: [String: Any] { return ["id": id, "name": name, "owner": owner, "host": host, "pet": pet] }
    var txt: [String: String] { return ["id": id, "name": name, "owner": owner, "host": host, "pet": pet] }

    init(id: String, name: String, owner: String, host: String, pet: String, spec: PetSpec? = nil) {
        self.id = id; self.name = name; self.owner = owner; self.host = host; self.pet = pet; self.spec = spec
    }
    init?(dict d: [String: Any]) {
        guard let id = d["id"] as? String, let name = d["name"] as? String, !id.isEmpty, !name.isEmpty else { return nil }
        var spec: PetSpec? = nil
        if let s = d["spec"] as? String, s.utf8.count <= PetSpec.maxBytes { spec = PetSpec.fromJSON(s) }
        self.init(id: String(id.prefix(64)), name: String(name.prefix(24)), owner: String((d["owner"] as? String ?? "").prefix(40)),
                  host: String((d["host"] as? String ?? "").prefix(40)), pet: String((d["pet"] as? String ?? "").prefix(24)), spec: spec)
    }
    init?(txt: NWTXTRecord) {
        var d: [String: Any] = [:]
        for k in ["id", "name", "owner", "host", "pet"] { if let v = txt[k] { d[k] = v } }
        self.init(dict: d)
    }
}

/// One TCP connection carrying newline-delimited JSON messages.
final class Link {
    let conn: NWConnection
    private var buffer = Data()
    private var closed = false
    private(set) var lastSeen = Date()
    var onReady: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    init(connection: NWConnection) { conn = connection }

    func start() {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self = self else { return }
            switch st {
            case .ready: self.onReady?()
            case .failed(_), .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: .main)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            if let d = data, !d.isEmpty { self.buffer.append(d); self.drain() }
            if complete || error != nil { self.finish(); return }
            self.receive()
        }
    }

    private func drain() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                lastSeen = Date()
                onMessage?(obj)
            }
        }
        if buffer.count > 2_000_000 { buffer.removeAll() }
    }

    func send(_ obj: [String: Any]) {
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    private func finish() {
        if closed { return }
        closed = true
        conn.cancel()
        let cb = onClose
        onClose = nil
        cb?()
    }
    func close() { finish() }
    func close(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.finish() }
    }
}

final class PetNet {
    struct Peer {
        let identity: PetIdentity
        let endpoint: NWEndpoint
    }
    private(set) var peers: [Peer] = []
    var onPeersChanged: (() -> Void)?
    var onIncoming: ((Link) -> Void)?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var identity: PetIdentity
    private(set) var lastError: String? = nil

    init(identity: PetIdentity) { self.identity = identity }

    static func params() -> NWParameters {
        let p = NWParameters.tcp
        p.includePeerToPeer = true
        return p
    }

    func start() {
        startListener()
        startBrowser()
    }

    func update(identity: PetIdentity) {
        self.identity = identity
        listener?.cancel()
        listener = nil
        startListener()
    }

    private func startListener() {
        guard let l = try? NWListener(using: PetNet.params()) else { return }
        let name = String("\(identity.name) · \(identity.owner)".prefix(60))
        l.service = NWListener.Service(name: name, type: serviceType, txtRecord: NWTXTRecord(identity.txt))
        l.newConnectionHandler = { [weak self] c in self?.onIncoming?(Link(connection: c)) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: NSLog("Claude Pet listener ready as \(name)")
            case .failed(let e): self?.lastError = "listener: \(e)"; NSLog("Claude Pet listener failed: \(e)")
            case .waiting(let e): self?.lastError = "listener waiting: \(e)"; NSLog("Claude Pet listener waiting: \(e)")
            default: break
            }
        }
        l.start(queue: .main)
        listener = l
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: PetNet.params())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results) }
        b.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed(let e): self?.lastError = "browser: \(e)"; NSLog("Claude Pet browser failed: \(e)")
            case .waiting(let e): self?.lastError = "browser waiting: \(e)"; NSLog("Claude Pet browser waiting: \(e)")
            default: break
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var out: [Peer] = []
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = PetIdentity(txt: txt), id.id != identity.id else { continue }
            if out.contains(where: { $0.identity.id == id.id }) { continue }
            out.append(Peer(identity: id, endpoint: r.endpoint))
        }
        peers = out.sorted { $0.identity.name.lowercased() < $1.identity.name.lowercased() }
        onPeersChanged?()
    }

    func connect(to peer: Peer) -> Link {
        return Link(connection: NWConnection(to: peer.endpoint, using: PetNet.params()))
    }
}

// MARK: - Visitor card (what you see when you click a visiting pet)

final class VisitorCardController: NSViewController {
    private let stack = NSStackView()
    private let width: CGFloat = 270

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width - 32),
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            stack.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
        ])
        let bottom = v.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 12)
        bottom.priority = NSLayoutConstraint.Priority(999)
        bottom.isActive = true
        view = v
    }

    private func label(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, lines: Int = 1) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.maximumNumberOfLines = lines
        l.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        l.setContentHuggingPriority(lines == 1 ? .defaultHigh : .defaultLow, for: .horizontal)
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }
    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func render(identity id: PetIdentity, state: PetState, since: Date, onSendHome: @escaping () -> Void) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = state.color.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let name = label(id.name, size: 14, weight: .bold)
        name.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let mood = label(state.title, size: 12, weight: .medium, color: state.color)
        mood.setContentCompressionResistancePriority(.required, for: .horizontal)
        let head = NSStackView(views: [dot, name, mood])
        head.orientation = .horizontal
        head.spacing = 6
        head.alignment = .centerY
        add(head)

        let whose = id.owner.isEmpty ? id.pet : "\(id.owner)'s \(id.pet.lowercased())"
        add(label(whose + (id.host.isEmpty ? "" : " · from \(id.host)"), size: 12, color: .secondaryLabelColor))
        add(label("Visiting for " + Fmt.duration(since, now: Date()), size: 11, color: .tertiaryLabelColor))

        let sep = NSBox(); sep.boxType = .separator
        add(sep)
        add(label("A visiting pet shares only its name, its owner's name, their computer's name, its look and its mood.", size: 10, color: .tertiaryLabelColor, lines: 3))

        let btn = ClosureButton(title: "Send home", target: nil, action: nil)
        btn.handler = onSendHome
        btn.target = btn
        btn.action = #selector(ClosureButton.fire)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [spacer, btn])
        row.orientation = .horizontal
        row.alignment = .centerY
        add(row)

        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: width, height: max(60, view.fittingSize.height))
        preferredContentSize = size
        if view.window == nil { view.frame.size = size }
    }
}

// MARK: - Window & app

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var window: PetWindow!
    var pet: PetView!
    let store = SessionStore()
    var popover: NSPopover?
    var statusVC: StatusViewController?
    var sources: [DispatchSourceFileSystemObject] = []
    var pollTimer: Timer?
    var refreshPending = false
    var controlPending = false
    var petReloadPending = false
    var baseSpec: PetSpec = PetSpec.fallback

    var net: PetNet!
    enum AwayPhase { case none, connecting, away, returning }
    var awayPhase: AwayPhase = .none
    var awayLink: Link?
    var awayPeer: PetNet.Peer?
    var visitorLink: Link?
    var visitorIdentity: PetIdentity?
    var visitorSince: Date?
    var pendingLinks: [Link] = []
    var netTimer: Timer?
    var lastPing = Date.distantPast
    var lastSentState: PetState?

    // Preferences ------------------------------------------------------------

    static let sizes: [(String, CGFloat)] = [("Small", 0.72), ("Medium", 0.95), ("Large", 1.3)]
    var sizeIndex: Int {
        get { return min(max(defaults.integer(forKey: "size"), 0), AppDelegate.sizes.count - 1) }
        set { defaults.set(newValue, forKey: "size") }
    }
    var sizeFactor: CGFloat { return AppDelegate.sizes[sizeIndex].1 }
    var petFile: String {
        get { return defaults.string(forKey: "pet") ?? "rabbit" }
        set { defaults.set(newValue, forKey: "pet") }
    }
    /// nil = the pet's own colours; otherwise an index into Coat.all.
    var coatIndex: Int? {
        get {
            guard defaults.object(forKey: "coat") != nil else { return nil }
            let i = defaults.integer(forKey: "coat")
            return (0..<Coat.all.count).contains(i) ? i : nil
        }
        set {
            if let v = newValue { defaults.set(v, forKey: "coat") } else { defaults.removeObject(forKey: "coat") }
        }
    }
    var petName: String {
        get { return defaults.string(forKey: "petName") ?? (profile.isEmpty ? "" : "Tester") }
        set { defaults.set(newValue, forKey: "petName") }
    }
    var defaultPetName: String {
        switch baseSpec.id {
        case "rabbit": return "Mochi"
        case "cat": return "Miso"
        default: return baseSpec.name
        }
    }
    var allowVisitors: Bool {
        get { return defaults.object(forKey: "allowVisitors") == nil ? true : defaults.bool(forKey: "allowVisitors") }
        set { defaults.set(newValue, forKey: "allowVisitors") }
    }
    var peerId: String {
        if let s = defaults.string(forKey: "peerId") { return s }
        let s = UUID().uuidString
        defaults.set(s, forKey: "peerId")
        return s
    }
    var currentSpec: PetSpec {
        if let i = coatIndex { return baseSpec.applying(coat: Coat.all[i]) }
        return baseSpec
    }
    var identity: PetIdentity {
        return PetIdentity(id: peerId, name: petName.isEmpty ? defaultPetName : petName, owner: NSFullUserName(),
                           host: Host.current().localizedName ?? "Mac", pet: baseSpec.name)
    }

    private func migrateOldPrefs() {
        guard profile.isEmpty, defaults.object(forKey: "posX") == nil, let old = UserDefaults(suiteName: "com.hari.claudepet") else { return }
        for k in ["posX", "posY", "size", "coat"] where old.object(forKey: k) != nil {
            defaults.set(old.object(forKey: k), forKey: k)
        }
        if old.object(forKey: "species") != nil { defaults.set(old.integer(forKey: "species") == 1 ? "cat" : "rabbit", forKey: "pet") }
    }

    static func availablePets() -> [(id: String, name: String, path: String)] {
        let dir = petHome + "/pets"
        var out: [(id: String, name: String, path: String)] = []
        for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted() where f.hasSuffix(".json") {
            let path = dir + "/" + f
            guard let s = PetSpec.load(path: path) else { continue }
            out.append((id: String(f.dropLast(5)), name: s.name, path: path))
        }
        let order = ["rabbit", "cat"]
        out.sort { a, b in
            let ia = order.firstIndex(of: a.id) ?? 99, ib = order.firstIndex(of: b.id) ?? 99
            return ia != ib ? ia < ib : a.name.lowercased() < b.name.lowercased()
        }
        return out
    }

    func loadPet() {
        baseSpec = PetSpec.builtin(petFile) ?? PetSpec.builtin("rabbit") ?? PetSpec.fallback
        pet.host.spec = currentSpec
        pet.host.name = identity.name
        pet.needsDisplay = true
    }

    // Launch -----------------------------------------------------------------

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        migrateOldPrefs()
        for d in [sessionsDir, statusDir, controlDir, petHome + "/pets"] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }

        let size = NSSize(width: PetView.slotWidth * sizeFactor, height: PetView.canvasHeight * sizeFactor)
        window = PetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true

        pet = PetView(frame: NSRect(origin: .zero, size: size))
        pet.autoresizingMask = [.width, .height]
        pet.onClick = { [weak self] in self?.togglePopover() }
        pet.onVisitorClick = { [weak self] in self?.showVisitorCard() }
        pet.onRightClick = { [weak self] e in self?.showMenu(e) }
        pet.onMoved = { [weak self] in self?.savePosition() }
        window.contentView = pet
        loadPet()

        restorePosition()
        window.orderFrontRegardless()

        watch(sessionsDir) { [weak self] in self?.scheduleRefresh() }
        watch(statusDir) { [weak self] in self?.scheduleRefresh() }
        watch(controlDir) { [weak self] in self?.scheduleControl() }
        watch(petHome + "/pets") { [weak self] in self?.schedulePetReload() }
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        net = PetNet(identity: identity)
        net.onPeersChanged = { [weak self] in self?.peersChanged() }
        net.onIncoming = { [weak self] link in self?.incoming(link) }
        net.start()
        netTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.netTick() }
        processControl()
        writeNetState()

        if petName.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.askName() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if awayPhase == .away { awayLink?.send(["t": "recall"]) }
        visitorLink?.send(["t": "bye"])
        usleep(150_000)
    }

    private func watch(_ path: String, _ handler: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        sources.append(src)
    }

    private func scheduleRefresh() {
        if refreshPending { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }
    private func scheduleControl() {
        if controlPending { return }
        controlPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.controlPending = false
            self?.processControl()
        }
    }
    private func schedulePetReload() {
        if petReloadPending { return }
        petReloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.petReloadPending = false
            let before = self.baseSpec.json
            self.loadPet()
            if self.baseSpec.json != before { self.net.update(identity: self.identity) }
        }
    }

    func refresh() {
        store.reload()
        let st = store.petState
        pet.setHostState(st)
        pet.host.tagColor = store.topState.color
        pet.host.sessionCount = store.sessions.count
        if awayPhase == .away, st != lastSentState {
            awayLink?.send(["t": "state", "state": st.name])
            lastSentState = st
        }
        refreshPopover()
    }
    private func refreshPopover() {
        if let p = popover, p.isShown { statusVC?.render(store, visit: visitInfo()) }
    }

    // Popover ----------------------------------------------------------------

    func visitInfo() -> VisitInfo? {
        switch awayPhase {
        case .connecting:
            return VisitInfo(text: "Sending \(identity.name) to \(awayPeer?.identity.name ?? "…")…", button: nil, action: nil)
        case .away, .returning:
            return VisitInfo(text: "\(identity.name) is visiting \(awayPeer?.identity.label ?? "a friend")",
                             button: awayPhase == .away ? "Call back" : nil, action: { [weak self] in self?.callBack() })
        case .none:
            break
        }
        if let v = visitorIdentity {
            return VisitInfo(text: "\(v.label) is visiting", button: "Send home", action: { [weak self] in self?.dismissVisitor() })
        }
        let peers = net.peers
        if peers.count == 1, let p = peers.first {
            return VisitInfo(text: "\(p.identity.label) is nearby", button: "Send \(identity.name)", action: { [weak self] in self?.sendPet(to: p) })
        }
        if peers.count > 1 {
            return VisitInfo(text: "\(peers.count) pets nearby · right-click to visit", button: nil, action: nil)
        }
        return nil
    }

    func togglePopover() {
        if let p = popover, p.isShown { p.performClose(nil); return }
        let vc = StatusViewController()
        vc.render(store, visit: visitInfo())
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        statusVC = vc
        popover = p
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: pet.headRect, of: pet, preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) {
        popover = nil
        statusVC = nil
    }

    func showVisitorCard() {
        guard let id = visitorIdentity else { togglePopover(); return }
        if let p = popover, p.isShown { p.performClose(nil); return }
        let vc = VisitorCardController()
        vc.render(identity: id, state: pet.visitorDriver.state, since: visitorSince ?? Date()) { [weak self] in
            self?.popover?.performClose(nil)
            self?.dismissVisitor()
        }
        let p = NSPopover()
        p.contentViewController = vc
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        popover = p
        statusVC = nil
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: pet.visitorHeadRect, of: pet, preferredEdge: .maxY)
    }

    // Position & size --------------------------------------------------------

    func restorePosition() {
        var origin: NSPoint
        if defaults.object(forKey: "posX") != nil {
            origin = NSPoint(x: defaults.double(forKey: "posX"), y: defaults.double(forKey: "posY"))
        } else {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: vf.maxX - window.frame.width - 28 - (profile.isEmpty ? 0 : 320), y: vf.minY + 6)
        }
        window.setFrameOrigin(clamped(origin))
    }
    func savePosition() {
        defaults.set(Double(window.frame.origin.x), forKey: "posX")
        defaults.set(Double(window.frame.origin.y), forKey: "posY")
    }
    func clamped(_ o: NSPoint) -> NSPoint {
        guard !NSScreen.screens.isEmpty else { return o }
        var union = NSRect.null
        for s in NSScreen.screens { union = union.union(s.visibleFrame) }
        let w = window.frame.width, h = window.frame.height
        var p = o
        p.x = min(max(p.x, union.minX - w * 0.4), union.maxX - w * 0.6)
        p.y = min(max(p.y, union.minY - h * 0.2), union.maxY - h * 0.7)
        return p
    }
    @objc func screensChanged() {
        window.setFrameOrigin(clamped(window.frame.origin))
    }

    /// Switches between one and two pet slots, keeping the host pet where it is on screen.
    func setSlots(_ n: Int) {
        guard n != pet.slots else { return }
        let f = sizeFactor
        let old = window.frame
        let hostScreenX = old.minX + pet.hostX * f
        var hostSlot = 0
        if n == 2 {
            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
            hostSlot = hostScreenX < screen.frame.midX ? 0 : 1
        }
        pet.hostSlot = hostSlot
        pet.slots = n
        let size = NSSize(width: PetView.slotWidth * CGFloat(n) * f, height: PetView.canvasHeight * f)
        let origin = NSPoint(x: hostScreenX - pet.hostX * f, y: old.minY)
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        window.setFrameOrigin(clamped(window.frame.origin))
        writeNetState()
    }

    // Menu -------------------------------------------------------------------

    func showMenu(_ event: NSEvent) {
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(withTitle: "Claude status…", action: #selector(menuStatus), keyEquivalent: "").target = self
        let dance = m.addItem(withTitle: "Dance!", action: #selector(danceAction), keyEquivalent: "")
        dance.target = self
        dance.toolTip = "Or hold Control and Option together"
        m.addItem(.separator())

        let nearby = NSMenu()
        nearby.autoenablesItems = false
        if net.peers.isEmpty {
            nearby.addItem(withTitle: "No pets nearby", action: nil, keyEquivalent: "").isEnabled = false
        }
        for (i, p) in net.peers.enumerated() {
            let it = nearby.addItem(withTitle: "Send to \(p.identity.label)", action: #selector(sendToPeer(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.isEnabled = awayPhase == .none
        }
        let nearbyItem = NSMenuItem(title: "Nearby pets", action: nil, keyEquivalent: "")
        nearbyItem.submenu = nearby
        m.addItem(nearbyItem)
        if awayPhase == .away {
            m.addItem(withTitle: "Call \(identity.name) back", action: #selector(callBackAction), keyEquivalent: "").target = self
        }
        if let v = visitorIdentity {
            m.addItem(withTitle: "Send \(v.name) home", action: #selector(dismissVisitorAction), keyEquivalent: "").target = self
        }
        let av = m.addItem(withTitle: "Allow visitors", action: #selector(toggleVisitors), keyEquivalent: "")
        av.target = self
        av.state = allowVisitors ? .on : .off
        m.addItem(.separator())

        m.addItem(withTitle: "Name my pet…", action: #selector(askNameAction), keyEquivalent: "").target = self
        let petMenu = NSMenu()
        for p in AppDelegate.availablePets() {
            let it = petMenu.addItem(withTitle: p.name, action: #selector(pickPet(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p.id
            it.state = (p.id == petFile) ? .on : .off
        }
        petMenu.addItem(.separator())
        petMenu.addItem(withTitle: "New pet with Claude…", action: #selector(newPetHelp), keyEquivalent: "").target = self
        let petItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        petItem.submenu = petMenu
        m.addItem(petItem)

        let coatMenu = NSMenu()
        let def = coatMenu.addItem(withTitle: "Default", action: #selector(pickCoat(_:)), keyEquivalent: "")
        def.target = self; def.tag = -1; def.state = coatIndex == nil ? .on : .off
        for (i, c) in Coat.all.enumerated() {
            let it = coatMenu.addItem(withTitle: c.name, action: #selector(pickCoat(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = (i == coatIndex) ? .on : .off
        }
        let coatItem = NSMenuItem(title: "Coat", action: nil, keyEquivalent: "")
        coatItem.submenu = coatMenu
        m.addItem(coatItem)

        let sizeMenu = NSMenu()
        for (i, s) in AppDelegate.sizes.enumerated() {
            let it = sizeMenu.addItem(withTitle: s.0, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = (i == sizeIndex) ? .on : .off
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        m.addItem(sizeItem)
        m.addItem(.separator())

        let login = m.addItem(withTitle: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled ? .on : .off
        m.addItem(withTitle: "Open pet folder", action: #selector(openFolder), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Claude Pet", action: #selector(quit), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: event, for: pet)
    }

    @objc func menuStatus() { if popover == nil { togglePopover() } }
    @objc func danceAction() { pet.startDance(seconds: 8) }
    @objc func sendToPeer(_ sender: NSMenuItem) {
        let peers = net.peers
        guard sender.tag >= 0, sender.tag < peers.count else { return }
        sendPet(to: peers[sender.tag])
    }
    @objc func callBackAction() { callBack() }
    @objc func dismissVisitorAction() { dismissVisitor() }
    @objc func askNameAction() { askName() }
    @objc func toggleVisitors() { allowVisitors = !allowVisitors }
    @objc func pickPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        petFile = id
        coatIndex = nil            // each pet starts in its own colours
        loadPet()
        net.update(identity: identity)
        writeNetState()
    }
    @objc func newPetHelp() {
        let alert = NSAlert()
        alert.messageText = "Create a pet with Claude"
        alert.informativeText = "Open a terminal in the pet folder and ask Claude Code, for example:\n\ncd ~/.claude/pet\nclaude \"Design me a fox pet with a big bushy tail\"\n\nClaude knows the pet format from CLAUDE.md there. It writes pets/<name>.json and previews it; the new pet then appears in this menu. Friends do the same on their own Macs, and their pets bring their look along when they visit."
        alert.addButton(withTitle: "Open folder")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openFolder() }
    }
    @objc func pickCoat(_ sender: NSMenuItem) {
        coatIndex = sender.tag < 0 ? nil : sender.tag
        pet.host.spec = currentSpec
    }
    @objc func pickSize(_ sender: NSMenuItem) {
        sizeIndex = sender.tag
        let old = window.frame
        let size = NSSize(width: PetView.slotWidth * CGFloat(pet.slots) * sizeFactor, height: PetView.canvasHeight * sizeFactor)
        let origin = NSPoint(x: old.midX - size.width / 2, y: old.minY)
        window.setFrame(NSRect(origin: clamped(origin), size: size), display: true, animate: true)
        savePosition()
    }
    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: petHome)) }
    @objc func quit() { NSApp.terminate(nil) }

    var loginEnabled: Bool { return FileManager.default.fileExists(atPath: launchAgentPath) }
    @objc func toggleLogin() { setLogin(!loginEnabled) }
    func setLogin(_ on: Bool) {
        let fm = FileManager.default
        if on {
            try? fm.createDirectory(atPath: (launchAgentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = ["Label": bundleID, "ProgramArguments": [exe], "RunAtLoad": true, "KeepAlive": false, "ProcessType": "Interactive"]
            (plist as NSDictionary).write(toFile: launchAgentPath, atomically: true)
        } else {
            try? fm.removeItem(atPath: launchAgentPath)
        }
    }

    // Naming -----------------------------------------------------------------

    func askName() {
        let alert = NSAlert()
        alert.messageText = "Name your pet"
        alert.informativeText = "Friends see this name when your pet visits them."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = petName.isEmpty ? defaultPetName : petName
        tf.placeholderString = defaultPetName
        alert.accessoryView = tf
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        if r == .alertFirstButtonReturn { setPetName(tf.stringValue) }
        else if petName.isEmpty { setPetName(defaultPetName) }
    }
    func setPetName(_ s: String) {
        let n = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        petName = n.isEmpty ? defaultPetName : n
        pet.host.name = identity.name
        net?.update(identity: identity)
        writeNetState()
    }

    // Visiting: owner side ---------------------------------------------------

    func sendPet(to peer: PetNet.Peer) {
        guard awayPhase == .none else { pet.showNote("\(identity.name) is already away"); return }
        let link = net.connect(to: peer)
        awayLink = link
        awayPeer = peer
        awayPhase = .connecting
        lastSentState = nil
        link.onReady = { [weak self, weak link] in
            guard let self = self, let link = link else { return }
            var hello = self.identity.dict
            hello["t"] = "hello"
            hello["spec"] = self.currentSpec.jsonWithPalette()
            link.send(hello)
            link.send(["t": "visit", "state": self.store.petState.name])
        }
        link.onMessage = { [weak self] msg in self?.ownerMessage(msg) }
        link.onClose = { [weak self, weak link] in self?.ownerLinkClosed(link) }
        link.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak link] in
            guard let self = self, let link = link, self.awayLink === link, self.awayPhase == .connecting else { return }
            self.pet.showNote("Couldn't reach \(peer.identity.name)")
            link.close()
        }
        pet.showNote("Sending \(identity.name) to \(peer.identity.name)…", seconds: 10)
        writeNetState()
        refreshPopover()
    }

    private func ownerMessage(_ msg: [String: Any]) {
        let t = msg["t"] as? String ?? ""
        switch t {
        case "welcome":
            guard awayPhase == .connecting else { return }
            awayPhase = .away
            pet.showNote("", seconds: 0)
            pet.departHost(label: "visiting \(awayPeer?.identity.name ?? "a friend")")
            lastSentState = store.petState
        case "busy":
            pet.showNote("\(awayPeer?.identity.name ?? "That pet") already has a visitor")
            awayLink?.close()
        case "bye":
            comeHome()
        case "ping":
            awayLink?.send(["t": "pong"])
        default:
            break
        }
        writeNetState()
        refreshPopover()
    }

    private func ownerLinkClosed(_ link: Link?) {
        guard awayLink == nil || awayLink === link else { return }
        switch awayPhase {
        case .away, .returning:
            comeHome()
        case .connecting:
            pet.showNote("Couldn't reach \(awayPeer?.identity.name ?? "that pet")")
            awayLink = nil; awayPhase = .none; awayPeer = nil
        case .none:
            break
        }
        writeNetState()
        refreshPopover()
    }

    private func comeHome() {
        if awayPhase == .away || awayPhase == .returning { pet.returnHost() }
        let l = awayLink
        awayLink = nil; awayPhase = .none; awayPeer = nil
        l?.close()
        writeNetState()
        refreshPopover()
    }

    func callBack() {
        guard awayPhase == .away, let l = awayLink else { return }
        awayPhase = .returning
        l.send(["t": "recall"])
        refreshPopover()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self = self, self.awayPhase == .returning else { return }
            self.comeHome()
        }
    }

    // Visiting: host side ----------------------------------------------------

    private func incoming(_ link: Link) {
        pendingLinks.append(link)
        var ident: PetIdentity? = nil
        link.onMessage = { [weak self, weak link] msg in
            guard let self = self, let link = link else { return }
            let t = msg["t"] as? String ?? ""
            switch t {
            case "hello":
                ident = PetIdentity(dict: msg)
            case "visit":
                if self.allowVisitors, self.visitorLink == nil, let id = ident {
                    self.acceptVisitor(id, link: link, state: PetState.named(msg["state"] as? String ?? "ready"))
                } else {
                    link.send(["t": "busy"])
                    link.close(after: 0.5)
                }
            case "state", "ping":
                if self.visitorLink === link, let s = msg["state"] as? String { self.pet.setVisitorState(PetState.named(s)) }
                if t == "ping" { link.send(["t": "pong"]) }
            case "recall":
                link.send(["t": "bye"])
                if self.visitorLink === link { self.removeVisitor() }
                link.close(after: 0.5)
            default:
                break
            }
        }
        link.onClose = { [weak self, weak link] in
            guard let self = self else { return }
            self.pendingLinks.removeAll { $0 === link }
            if let link = link, self.visitorLink === link { self.removeVisitor() }
        }
        link.start()
    }

    private func acceptVisitor(_ id: PetIdentity, link: Link, state: PetState) {
        visitorLink = link
        visitorIdentity = id
        visitorSince = Date()
        setSlots(2)
        let artist = PetArtist(spec: id.spec ?? PetSpec.builtin("rabbit") ?? PetSpec.fallback)
        artist.name = id.name
        pet.arriveVisitor(artist, state: state)
        link.send(["t": "welcome"])
        writeNetState()
        refreshPopover()
    }

    private func removeVisitor() {
        guard visitorIdentity != nil else { return }
        pet.leaveVisitor()
        visitorLink = nil
        visitorIdentity = nil
        visitorSince = nil
        if statusVC == nil, let p = popover, p.isShown { p.performClose(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.visitorIdentity == nil, self.pet.visitor == nil else { return }
            self.setSlots(1)
        }
        writeNetState()
        refreshPopover()
    }

    func dismissVisitor() {
        guard let l = visitorLink else { return }
        l.send(["t": "bye"])
        removeVisitor()
        l.close(after: 0.5)
    }

    private func netTick() {
        let now = Date()
        var ping = false
        if now.timeIntervalSince(lastPing) >= 5 { ping = true; lastPing = now }
        if let l = awayLink {
            if now.timeIntervalSince(l.lastSeen) > 25 { l.close() }
            else if ping { l.send(["t": "ping", "state": store.petState.name]) }
        }
        if let l = visitorLink {
            if now.timeIntervalSince(l.lastSeen) > 25 { l.close() }
            else if ping { l.send(["t": "ping"]) }
        }
        if ping { writeNetState() }
    }

    private func peersChanged() {
        writeNetState()
        refreshPopover()
    }

    // Control files & state dump (scripting + tests) ---------------------------

    private func processControl() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: controlDir)) ?? [] {
            let path = controlDir + "/" + name
            let body = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(atPath: path)
            switch name {
            case "send":
                let q = body.lowercased()
                if let p = net.peers.first(where: { q.isEmpty || $0.identity.id == body || $0.identity.name.lowercased().contains(q) }) {
                    sendPet(to: p)
                } else {
                    pet.showNote("No pet called “\(body)” nearby")
                }
            case "recall": callBack()
            case "dismiss": dismissVisitor()
            case "dance": pet.startDance(seconds: Double(body) ?? 8)
            case "snapshot": snapshot(to: body.isEmpty ? petHome + "/snapshot" + (profile.isEmpty ? "" : "-" + profile) + ".png" : body)
            case "name": if !body.isEmpty { setPetName(body) }
            case "pet":
                if !body.isEmpty {
                    petFile = body
                    coatIndex = nil
                    loadPet()
                    net.update(identity: identity)
                    writeNetState()
                }
            default: break
            }
        }
    }

    private func snapshot(to path: String) {
        pet.needsDisplay = true
        pet.displayIfNeeded()
        guard let rep = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { return }
        pet.cacheDisplay(in: pet.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    private func writeNetState() {
        var d: [String: Any] = [
            "me": identity.dict,
            "pet": baseSpec.id,
            "peers": net.peers.map { $0.identity.dict },
            "slots": pet.slots,
            "hostSlot": pet.hostSlot,
            "ts": Int(Date().timeIntervalSince1970),
        ]
        d["away"] = awayPhase == .none ? NSNull() : ["phase": "\(awayPhase)", "peer": awayPeer?.identity.dict ?? [:]]
        d["visitor"] = visitorIdentity?.dict ?? NSNull()
        d["error"] = net.lastError ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: netStatePath))
        }
    }
}

// MARK: - Command line: previews, checks, and the app itself

/// ClaudePet --render <state> <out.png> [coat|-] [points] [pet id or path]
func renderPNG(state: String, path: String, coat: Int?, points: CGFloat, petArg: String) {
    let size = NSSize(width: points, height: points * PetView.canvasHeight / PetView.slotWidth)
    let view = PetView(frame: NSRect(origin: .zero, size: size))
    var spec = PetSpec.builtin(petArg) ?? PetSpec.fallback
    if let c = coat, c >= 0, c < Coat.all.count { spec = spec.applying(coat: Coat.all[c]) }
    view.host.spec = spec
    view.setHostState(PetState.named(state))
    view.host.tagColor = view.host.state.color
    view.frozenTime = 1.0
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    gctx.cgContext.scaleBy(x: scale, y: scale)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// ClaudePet --render-status <out.png> [dark]  — renders the status card offline.
func renderStatusPNG(path: String, dark: Bool) {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let store = SessionStore()
    store.reload()
    let vc = StatusViewController()
    vc.render(store, visit: nil)
    let size = vc.preferredContentSize
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentViewController = vc
    let v = vc.view
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

func renderVisitorCardPNG(path: String, dark: Bool) {
    let app = NSApplication.shared
    app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let vc = VisitorCardController()
    let id = PetIdentity(id: "x", name: "Pixel", owner: "Aron Example", host: "Aron's MacBook Air", pet: "Fox")
    vc.render(identity: id, state: .working, since: Date().addingTimeInterval(-200)) {}
    let size = vc.preferredContentSize
    let win = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentViewController = vc
    let v = vc.view
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    v.layoutSubtreeIfNeeded()
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
    v.cacheDisplay(in: v.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let argv = CommandLine.arguments
if argv.count >= 3 && argv[1] == "--render-visitor-card" {
    renderVisitorCardPNG(path: argv[2], dark: argv.count > 3 && argv[3] == "dark")
    exit(0)
}
if argv.count >= 3 && argv[1] == "--render-status" {
    renderStatusPNG(path: argv[2], dark: argv.count > 3 && argv[3] == "dark")
    exit(0)
}
if argv.count >= 3 && argv[1] == "--check" {
    guard let data = FileManager.default.contents(atPath: argv[2]) else { print("cannot read \(argv[2])"); exit(2) }
    guard (try? JSONSerialization.jsonObject(with: data)) != nil else { print("not valid JSON: \(argv[2])"); exit(2) }
    guard let spec = PetSpec.fromData(data) else { print("not a pet spec (needs a non-empty \"parts\" array and size under 200 KB)"); exit(2) }
    let problems = spec.problems()
    if problems.isEmpty { print("ok: \(spec.name) (\(spec.id))"); exit(0) }
    for p in problems { print("warning: \(p)") }
    exit(1)
}
if argv.count >= 3 && argv[1] == "--render" {
    let coat: Int? = argv.count > 4 ? Int(argv[4]) : nil
    let points = argv.count > 5 ? CGFloat(Double(argv[5]) ?? 256) : 256
    let petArg = argv.count > 6 ? argv[6] : "rabbit"
    renderPNG(state: argv[2], path: argv[3], coat: coat, points: points, petArg: petArg)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
