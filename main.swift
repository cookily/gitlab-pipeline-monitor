import AppKit
import UserNotifications
import ServiceManagement

// MARK: - 配置与数据模型

struct Config: Codable {
    struct Repo: Codable {
        var project: String   // GitLab 项目路径（my-group/backend）或数字 ID
        var ref: String       // 监控的分支
        var alias: String?    // 菜单里显示的名字
        var jobs: [String]?   // 只关心这些 job（精确名字匹配）；省略=看整条流水线状态
    }
    var gitlabUrl: String
    var token: String
    var intervalSeconds: Int?
    var repos: [Repo]
}

struct Pipeline: Codable {
    var id: Int
    var status: String
    var sha: String?
    var source: String?
    var createdAt: String?
    var updatedAt: String?
    var webUrl: String?
    enum CodingKeys: String, CodingKey {
        case id, status, sha, source
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case webUrl = "web_url"
    }
}

// 流水线详情接口的响应（比列表接口多出触发人）
struct PipelineDetail: Codable {
    var user: User?
    struct User: Codable {
        var name: String?
        var username: String?
    }
}

struct Job: Codable {
    var id: Int?
    var name: String
    var status: String?
    var webUrl: String?
    enum CodingKeys: String, CodingKey {
        case id, name, status
        case webUrl = "web_url"
    }
}

final class RepoState {
    var cfg: Config.Repo
    var pipeline: Pipeline?
    var jobs: [Job] = []          // 最近一次查到该流水线的全部 job
    var jobsFetchedFor: Int?
    var filteredStatus: String?    // 配了 jobs 白名单时：按关心的 job 归并出的状态
    var failedJobs: [Job] = []
    var error: String?
    var notifiedStatus: String?
    var fetchedAt: Date?
    var pipelineUser: String?
    var detailFetchedFor: Int?
    init(_ cfg: Config.Repo) { self.cfg = cfg }
    // 菜单/通知/图标统一以 effectiveStatus 为准
    var effectiveStatus: String? { filteredStatus ?? pipeline?.status }
    var displayName: String {
        if let a = cfg.alias, !a.isEmpty { return a }
        return cfg.project.split(separator: "/").last.flatMap { String($0) } ?? cfg.project
    }
}

extension Date {
    func relativeText() -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}

func statusEmoji(_ s: String?) -> String {
    switch s {
    case "success": return "✅"
    case "failed": return "❌"
    case "running": return "🔄"
    case "pending": return "⏳"
    case "created": return "🕒"
    case "canceled": return "🚫"
    case "skipped": return "⏭️"
    case .some: return "•"
    case nil: return "➖"
    }
}

func statusText(_ s: String?) -> String {
    switch s {
    case "success": return "成功"
    case "failed": return "失败"
    case "running": return "进行中"
    case "pending": return "排队中"
    case "created": return "已创建"
    case "canceled": return "已取消"
    case "skipped": return "已跳过"
    case .some(let v): return v
    case nil: return "无流水线"
    }
}

func sourceText(_ s: String) -> String {
    switch s {
    case "push": return "推送"
    case "web": return "手动"
    case "schedule": return "定时"
    case "api": return "API"
    case "trigger": return "触发器"
    case "pipeline": return "父流水线"
    case "external": return "外部"
    default: return s
    }
}

// 按 job 白名单归并状态：只看关心的 job，全绿才绿（GitLab 整条流水线的状态可能被无关 job 拖红）
// 返回 nil 表示白名单里的 job 尚未出现在流水线中（还没排到）
func aggregateStatus(jobs: [Job], wanted: [String]) -> String? {
    let picked = jobs.filter { wanted.contains($0.name) }
    guard !picked.isEmpty else { return nil }
    let statuses = picked.map { $0.status ?? "unknown" }
    if statuses.contains("failed") { return "failed" }
    if statuses.contains("running") { return "running" }
    if statuses.contains("pending") || statuses.contains("created") { return "pending" }
    if statuses.allSatisfy({ $0 == "success" || $0 == "skipped" || $0 == "manual" }) {
        return statuses.contains("manual") ? "manual" : "success"
    }
    if statuses.contains("canceled") { return "canceled" }
    return picked.first?.status
}

let gitlabDateFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let gitlabDatePlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
let shortDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    return f
}()

func parseGitLabDate(_ s: String?) -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    return gitlabDateFractional.date(from: s) ?? gitlabDatePlain.date(from: s)
}

// 菜单里显示的流水线时间：已结束→完成时间（24h 内相对、超 24h 绝对）；进行中→已跑时长
func pipelineTimeText(_ st: RepoState) -> String? {
    guard let pipeline = st.pipeline,
          let created = parseGitLabDate(pipeline.createdAt) else { return nil }
    switch pipeline.status {
    case "success", "failed", "canceled", "skipped":
        let finish = parseGitLabDate(pipeline.updatedAt) ?? created
        let interval = Date().timeIntervalSince(finish)
        let text: String
        if interval < 3600 {
            text = finish.relativeText()
        } else if interval < 86400 {
            text = "\(Int(interval / 3600))小时前"
        } else {
            text = shortDateFormatter.string(from: finish)
        }
        return text + "完成"
    default:
        let elapsed = Int(Date().timeIntervalSince(created))
        if elapsed < 90 { return "刚刚开跑" }
        if elapsed < 3600 { return "已跑\(elapsed / 60)分钟" }
        return "已跑\(elapsed / 3600)小时\((elapsed % 3600) / 60)分钟"
    }
}

enum DotStyle { case filled, dashed, paused, warning }

// MARK: - 主逻辑

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    private let configPath = ("~/.config/gitlab-pipeline-monitor/config.json" as NSString).expandingTildeInPath

    private var config: Config?
    private var states: [RepoState] = []
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var pollInFlight = false
    private var lastConfigRaw: String?
    private var activityToken: NSObjectProtocol?
    private var paused = false
    private var notifAuthStatus: UNAuthorizationStatus = .notDetermined

    static let defaultConfigJSON = """
    {
      "gitlabUrl": "https://gitlab.example.com",
      "token": "",
      "intervalSeconds": 60,
      "repos": [
        { "project": "my-group/backend", "ref": "main", "alias": "Backend" },
        { "project": "my-group/frontend", "ref": "main", "alias": "Frontend" },
        { "project": "my-group/mobile-app", "ref": "main", "alias": "Mobile App" }
      ]
    }
    """

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 防止 App Nap 拖慢轮询
        activityToken = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "轮询 GitLab 流水线")

        let nc = UNUserNotificationCenter.current()
        nc.delegate = self
        nc.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.refreshNotifStatus() }
        }
        refreshNotifStatus()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = dotImage(.systemGray, style: .dashed)
            button.toolTip = "GitLab 流水线监控（各仓库已配置分支最近一次流水线）"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        poll()
    }

    // MARK: 轮询

    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        reloadConfigIfChanged()
        let group = DispatchGroup()
        for st in states {
            group.enter()
            fetchRepo(st) { group.leave() }
        }
        group.notify(queue: .main) {
            self.pollInFlight = false
            self.updateIcon()
            guard !self.paused else { return }  // 暂停时不排下一轮
            let interval = TimeInterval(max(15, self.config?.intervalSeconds ?? 60))
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.poll()
            }
        }
    }

    private func reloadConfigIfChanged() {
        let raw = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        if raw == lastConfigRaw { return }
        lastConfigRaw = raw
        guard let data = raw.data(using: .utf8),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            config = nil
            states = []
            return
        }
        config = cfg
        let old = Dictionary(uniqueKeysWithValues: states.map { ("\($0.cfg.project)@\($0.cfg.ref)", $0) })
        states = cfg.repos.map { r -> RepoState in
            let key = "\(r.project)@\(r.ref)"
            if let s = old[key] {
                s.cfg = r
                return s
            }
            return RepoState(r)
        }
    }

    private func fetchRepo(_ st: RepoState, done: @escaping () -> Void) {
        guard let cfg = config else {
            st.error = "读不到配置文件"
            done()
            return
        }
        guard !cfg.token.isEmpty else {
            st.error = "未配置 token"
            done()
            return
        }
        let base = cfg.gitlabUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let encProject = st.cfg.project.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").inverted) ?? st.cfg.project
        let encRef = st.cfg.ref.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "&?#= ").inverted) ?? st.cfg.ref
        let urlString = "\(base)/api/v4/projects/\(encProject)/pipelines?ref=\(encRef)&per_page=1&order_by=updated_at&sort=desc"
        guard let url = URL(string: urlString) else {
            st.error = "URL 无效"
            done()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(cfg.token, forHTTPHeaderField: "PRIVATE-TOKEN")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { done(); return }
                if let error = error {
                    st.error = error.localizedDescription
                } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    var msg = "HTTP \(http.statusCode)"
                    if http.statusCode == 401 { msg += "（token 无效或过期）" }
                    if http.statusCode == 403 { msg += "（token 权限不足，需 read_api）" }
                    if http.statusCode == 404 { msg += "（项目路径不对或无权限）" }
                    st.error = msg
                } else if let data = data,
                          let list = try? JSONDecoder().decode([Pipeline].self, from: data) {
                    st.error = nil
                    st.fetchedAt = Date()
                    st.pipeline = list.first
                    // 触发人不在列表接口里，取详情接口；每个流水线只查一次并缓存
                    if let pid = st.pipeline?.id, st.detailFetchedFor != pid {
                        st.detailFetchedFor = pid
                        st.pipelineUser = nil
                        self.fetchPipelineUser(st, pipelineId: pid, base: base, token: cfg.token)
                    }
                    guard let pid = st.pipeline?.id else {
                        st.jobs = []; st.jobsFetchedFor = nil
                        st.filteredStatus = nil; st.failedJobs = []
                        self.maybeNotify(st)
                        done()
                        return
                    }
                    // 配置了 jobs 白名单，或流水线失败需要列出失败 job —— 都要拉全部 job
                    let needJobs = (st.cfg.jobs?.isEmpty == false) || st.pipeline?.status == "failed"
                    if needJobs {
                        if st.jobsFetchedFor != pid { st.jobsFetchedFor = pid; st.jobs = [] }
                        self.fetchJobs(st, pipelineId: pid, base: base, token: cfg.token) {
                            self.applyJobs(st)
                            self.maybeNotify(st)
                            done()
                        }
                    } else {
                        st.jobs = []; st.filteredStatus = nil; st.failedJobs = []
                        self.maybeNotify(st)
                        done()
                    }
                } else {
                    st.error = "响应解析失败"
                    done()
                }
            }
        }.resume()
    }

    // 按白名单归并状态 + 挑出要展示/提醒的失败 job
    private func applyJobs(_ st: RepoState) {
        guard let wanted = st.cfg.jobs, !wanted.isEmpty else {
            // 未配置白名单：沿用整条流水线状态，失败 job 全列
            st.filteredStatus = nil
            st.failedJobs = st.jobs.filter { $0.status == "failed" }
            return
        }
        st.filteredStatus = aggregateStatus(jobs: st.jobs, wanted: wanted)
        st.failedJobs = st.jobs.filter { $0.status == "failed" && wanted.contains($0.name) }
    }

    private func fetchJobs(_ st: RepoState, pipelineId: Int, base: String, token: String, completion: @escaping () -> Void) {
        let encProject = st.cfg.project.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").inverted) ?? st.cfg.project
        let urlString = "\(base)/api/v4/projects/\(encProject)/pipelines/\(pipelineId)/jobs?per_page=100"
        guard let url = URL(string: urlString) else {
            completion()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                if let data = data,
                   let jobs = try? JSONDecoder().decode([Job].self, from: data) {
                    st.jobs = jobs
                }
                completion()
            }
        }.resume()
    }

    private func fetchPipelineUser(_ st: RepoState, pipelineId: Int, base: String, token: String) {
        let encProject = st.cfg.project.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "/").inverted) ?? st.cfg.project
        let urlString = "\(base)/api/v4/projects/\(encProject)/pipelines/\(pipelineId)"
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                guard let data = data,
                      let detail = try? JSONDecoder().decode(PipelineDetail.self, from: data) else { return }
                st.pipelineUser = detail.user?.name ?? detail.user?.username
            }
        }.resume()
    }

    // MARK: 通知（首次观察到某状态不打扰，之后只在状态变化时提醒）

    private func maybeNotify(_ st: RepoState) {
        guard let status = st.effectiveStatus,
              ["success", "failed", "canceled"].contains(status) else { return }
        let isNew = (st.notifiedStatus != nil) && (st.notifiedStatus != status)
        st.notifiedStatus = status
        guard isNew else { return }

        let name = st.displayName
        let ref = st.cfg.ref
        let sha = String((st.pipeline?.sha ?? "").prefix(8))
        let watched = (st.cfg.jobs?.isEmpty == false) ? "（只看 \(st.cfg.jobs!.joined(separator: "、"))）" : ""
        let content = UNMutableNotificationContent()
        content.sound = .default
        if status == "success" {
            content.title = "✅ \(name) · \(ref) 发布成功"
            content.body = (sha.isEmpty ? "流水线通过" : "流水线通过，提交 \(sha)") + watched
        } else if status == "failed" {
            content.title = "❌ \(name) · \(ref) 流水线失败"
            let jobs = st.failedJobs.prefix(3).map { $0.name }.joined(separator: "、")
            content.body = (jobs.isEmpty ? "提交 \(sha)，点开看详情" : "失败 job：\(jobs)") + watched
        } else {
            content.title = "🚫 \(name) · \(ref) 流水线被取消"
            content.body = "提交 \(sha)"
        }
        if let web = st.pipeline?.webUrl, let url = URL(string: web) {
            content.userInfo = ["url": url.absoluteString]
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: 菜单栏图标
    // 直接把颜色画进图片（isTemplate=false）：contentTintColor 对 NSStatusItem 按钮在部分系统上不生效，
    // 深色菜单栏下会渲染成黑色看不清

    private func dotImage(_ color: NSColor, style: DotStyle) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        let mid = side / 2
        color.set()
        switch style {
        case .filled:
            NSBezierPath(ovalIn: NSRect(x: mid - 5.5, y: mid - 5.5, width: 11, height: 11)).fill()
        case .dashed:
            let ring = NSBezierPath(ovalIn: NSRect(x: mid - 5.5, y: mid - 5.5, width: 11, height: 11))
            ring.lineWidth = 2
            ring.setLineDash([2.2, 2.0], count: 2, phase: 0)
            ring.stroke()
        case .paused:
            let bars = NSBezierPath()
            bars.lineWidth = 2.6
            bars.lineCapStyle = .round
            bars.move(to: NSPoint(x: mid - 2.6, y: mid - 4.5)); bars.line(to: NSPoint(x: mid - 2.6, y: mid + 4.5))
            bars.move(to: NSPoint(x: mid + 2.6, y: mid - 4.5)); bars.line(to: NSPoint(x: mid + 2.6, y: mid + 4.5))
            bars.stroke()
        case .warning:
            let w: CGFloat = 14, h: CGFloat = 12.5
            let x0 = mid - w / 2, y0 = mid - h / 2 - 0.5
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: x0, y: y0))
            triangle.line(to: NSPoint(x: x0 + w, y: y0))
            triangle.line(to: NSPoint(x: mid, y: y0 + h))
            triangle.close()
            triangle.lineWidth = 1.8
            triangle.lineJoinStyle = .round
            triangle.stroke()
            let bar = NSBezierPath()
            bar.lineWidth = 1.8
            bar.lineCapStyle = .round
            bar.move(to: NSPoint(x: mid, y: y0 + 3.6)); bar.line(to: NSPoint(x: mid, y: y0 + 7.0))
            bar.stroke()
            NSBezierPath(ovalIn: NSRect(x: mid - 0.9, y: y0 + 1.2, width: 1.8, height: 1.8)).fill()
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        var color = NSColor.systemGray
        var style = DotStyle.filled
        if config == nil || config!.token.isEmpty {
            color = .systemOrange; style = .warning
        } else if states.contains(where: { $0.effectiveStatus == "failed" }) {
            color = .systemRed; style = .filled
        } else if states.contains(where: { ["running", "pending", "created"].contains($0.effectiveStatus ?? "") }) {
            color = .systemOrange; style = .dashed
        } else if states.contains(where: { $0.error != nil }) {
            color = .systemYellow; style = .warning
        } else if !states.isEmpty && states.allSatisfy({ $0.effectiveStatus == "success" }) {
            color = .systemGreen; style = .filled
        } else {
            color = .systemGray; style = .dashed
        }
        if paused {
            style = .paused
            if states.contains(where: { $0.effectiveStatus == "failed" }) { color = .systemRed }
        }
        button.image = dotImage(color, style: style)
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu: menu)
    }

    private func rebuild(menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        var headerTitle = "GitLab 流水线监控 · 分支最近一次流水线"
        if let latest = states.compactMap({ $0.fetchedAt }).max() {
            headerTitle += "（\(latest.relativeText())刷新）"
        }
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if config == nil {
            let warn = NSMenuItem(title: "⚠️ 读不到配置文件，点此打开", action: #selector(openConfigFile), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        } else if config!.token.isEmpty {
            let warn = NSMenuItem(title: "⚠️ 未配置 token，点此打开配置文件", action: #selector(openConfigFile), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        for st in states {
            var label = "\(statusEmoji(st.effectiveStatus)) \(st.displayName) · \(st.cfg.ref) · \(statusText(st.effectiveStatus))"
            if let timeText = pipelineTimeText(st) { label += " · \(timeText)" }
            var trigger: [String] = []
            if let s = st.pipeline?.source { trigger.append(sourceText(s)) }
            if let u = st.pipelineUser { trigger.append(u) }
            if !trigger.isEmpty { label += " · " + trigger.joined(separator: " ") }
            if let watched = st.cfg.jobs, !watched.isEmpty {
                label += " · 只看" + watched.joined(separator: "/")
            }
            if let err = st.error { label += "（\(err)）" }
            let item = NSMenuItem(title: label, action: #selector(openLink(_:)), keyEquivalent: "")
            item.target = self
            if let web = st.pipeline?.webUrl {
                item.representedObject = URL(string: web)
            }
            item.isEnabled = item.representedObject != nil
            menu.addItem(item)
            for job in st.failedJobs.prefix(5) {
                let jobItem = NSMenuItem(title: "　↳ ❌ \(job.name)", action: #selector(openLink(_:)), keyEquivalent: "")
                jobItem.target = self
                if let web = job.webUrl {
                    jobItem.representedObject = URL(string: web)
                }
                jobItem.isEnabled = jobItem.representedObject != nil
                menu.addItem(jobItem)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "立即刷新", action: #selector(pollNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let pauseItem = NSMenuItem(title: paused ? "恢复轮询" : "暂停轮询", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let test = NSMenuItem(title: "发一条测试通知", action: #selector(sendTestNotification), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let authText: String
        switch notifAuthStatus {
        case .authorized, .provisional, .ephemeral: authText = "已授权 ✅"
        case .denied: authText = "已拒绝 ❌（这样收不到通知）"
        case .notDetermined: authText = "未询问"
        default: authText = "未知"
        }
        let authItem = NSMenuItem(title: "通知权限：\(authText)", action: nil, keyEquivalent: "")
        authItem.isEnabled = false
        menu.addItem(authItem)
        if notifAuthStatus == .notDetermined {
            let prov = NSMenuItem(title: "静默授权（免弹窗，通知先进通知中心）", action: #selector(requestProvisionalAuth), keyEquivalent: "")
            prov.target = self
            menu.addItem(prov)
        }
        let fix = NSMenuItem(title: "打开系统通知设置", action: #selector(openNotificationSettings), keyEquivalent: "")
        fix.target = self
        menu.addItem(fix)

        let openConfig = NSMenuItem(title: "打开配置文件", action: #selector(openConfigFile), keyEquivalent: ",")
        openConfig.target = self
        menu.addItem(openConfig)

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let pathItem = NSMenuItem(title: "配置文件：\(configPath)", action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: 动作

    @objc private func pollNow() { poll() }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfigFile() {
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: configPath) {
            try? AppDelegate.defaultConfigJSON.write(toFile: configPath, atomically: true, encoding: .utf8)
        }
        _ = Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-e", configPath])
    }

    @objc private func sendTestNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.notifAuthStatus = settings.authorizationStatus
                switch settings.authorizationStatus {
                case .denied:
                    self.showDeniedAlert()
                case .notDetermined:
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                        DispatchQueue.main.async {
                            self.notifAuthStatus = granted ? .authorized : .denied
                            if granted {
                                self.postTestNotification()
                            } else {
                                self.showDeniedAlert()
                            }
                        }
                    }
                default:
                    self.postTestNotification()
                }
            }
        }
    }

    private func postTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "✅ 通知链路正常"
        content.body = "GitLab 流水线监控已就绪，状态变化时会在这里提醒你"
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            DispatchQueue.main.async {
                if let error = error {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "通知发送失败"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    private func showDeniedAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "通知权限被拒绝"
        alert.informativeText = "请在 系统设置 → 通知 → GitLabPipelineMonitor 里打开「允许通知」，然后回来再点一次「发一条测试通知」。注意：若开了专注模式/勿扰，横幅会被静音（通知会进右上角通知中心）。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openNotificationSettings()
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notifAuthStatus = settings.authorizationStatus
            }
        }
    }

    @objc private func togglePause() {
        paused.toggle()
        timer?.invalidate()
        timer = nil
        updateIcon()
        if !paused { poll() }
    }

    @objc private func requestProvisionalAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.refreshNotifStatus()
                if granted {
                    self?.postTestNotification()
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "静默授权未成功"
                    alert.informativeText = "系统返回未授权。可在终端执行：sudo tccutil reset UserNotifications io.github.chenyl.gitlab-pipeline-monitor 后重启本应用再试。"
                    alert.runModal()
                }
            }
        }
    }

    @objc private func openNotificationSettings() {
        // macOS 13+ 系统设置的现代锚点；老锚点 com.apple.preference.notifications 在部分版本打不开
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSLog("切换开机自启失败: \(error)")
            }
        }
    }

    private func isLoginItemEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    // MARK: 通知代理

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(macOS 12.0, *) {
            completionHandler([.banner, .list])
        } else {
            completionHandler([.alert])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
