import AppKit
import SwiftUI

// Absolute deadlines include time spent asleep; pausing stores remaining seconds.
struct Countdown {
    var duration: TimeInterval = 1500
    var remaining: TimeInterval = 1500
    var deadline: Date?
    var running: Bool { deadline != nil }
    mutating func set(_ seconds: TimeInterval) {
        duration = max(1, seconds); remaining = duration; deadline = nil
    }
    mutating func start(at now: Date) {
        guard deadline == nil else { return }
        if remaining <= 0 { remaining = duration }
        deadline = now.addingTimeInterval(remaining)
    }
    mutating func tick(at now: Date) {
        if let end = deadline { remaining = end.timeIntervalSince(now) }
    }
    mutating func pause(at now: Date) { tick(at: now); deadline = nil }
    mutating func reset() { remaining = duration; deadline = nil }
    mutating func add(_ seconds: TimeInterval, at now: Date) {
        tick(at: now)
        let next = max(0, remaining) + seconds
        duration = max(duration, next); remaining = next
        if running { deadline = now.addingTimeInterval(next) }
    }
}

enum TimerMode: String, CaseIterable { case duration, until }

// A task handed over from ぽいっと by a bartimer://start link.
struct TaskRequest: Equatable {
    let id: String
    let title: String
    let minutes: Double
}

// bartimer://start?min=45&task=t123&title=経費精算
func parseStartURL(_ url: URL) -> TaskRequest? {
    guard url.scheme?.lowercased() == "bartimer", url.host?.lowercased() == "start",
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    guard let minText = value("min"), let minutes = Double(minText), minutes > 0, minutes < 6000,
          let id = value("task"), !id.isEmpty, id.count <= 64,
          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
    let title = String((value("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    return TaskRequest(id: id, title: title, minutes: minutes)
}

// Commands from the page's buttons while a task is being timed:
// bartimer://finish?task=t123 (checked off), bartimer://pause?task=t123, bartimer://resume?task=t123.
enum TaskCommand: String { case finish, pause, resume, cancel }
func parseTaskCommand(_ text: String) -> (TaskCommand, String)? {
    for command in [TaskCommand.finish, .pause, .resume, .cancel] where text.hasPrefix("bartimer://\(command.rawValue)?") {
        return parseCommandID(text, host: command.rawValue).map { (command, $0) }
    }
    return nil
}
func parseFinishText(_ text: String) -> String? { parseCommandID(text, host: "finish") }
private func parseCommandID(_ text: String, host: String) -> String? {
    guard let link = text.split(whereSeparator: { $0.isWhitespace }).first,
          let url = URL(string: String(link)), url.scheme?.lowercased() == "bartimer", url.host?.lowercased() == host,
          let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "task" })?.value,
          !id.isEmpty, id.count <= 64,
          id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
    return id
}

// The same link copied as text (from ぽいっと's ▶ 計る), possibly with words around it.
func parseStartText(_ text: String) -> TaskRequest? {
    guard let range = text.range(of: "bartimer://start?", options: .caseInsensitive) else { return nil }
    let link = text[range.lowerBound...].prefix { !$0.isWhitespace }
    return URL(string: String(link)).flatMap(parseStartURL)
}

// Time actually spent on a task: counts while running (overrun included), not while paused.
struct WorkLog {
    var worked: TimeInterval = 0
    var since: Date?
    mutating func resume(at now: Date) { if since == nil { since = now } }
    mutating func pause(at now: Date) {
        if let start = since { worked += max(0, now.timeIntervalSince(start)); since = nil }
    }
    func elapsed(at now: Date) -> TimeInterval { worked + (since.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
}

func actualMinutes(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / 60).rounded())) }

// Pasted into the ぽいっと page; the page reads the first part, people read the rest.
func actualPayload(task: TaskRequest, minutes: Int) -> String {
    "poipoi:actual?task=\(task.id)&min=\(minutes) （\(task.title.isEmpty ? "タスク" : task.title) / 実績\(minutes)分）"
}

func nextTarget(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    return calendar.nextDate(after: now,
        matching: DateComponents(hour: hour, minute: minute, second: 0),
        matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
}

final class TimerModel: ObservableObject {
    // clock and now change every tick. They do not publish on each change:
    // tick() notifies SwiftUI only when what is drawn changes (about once a
    // second), and not at all while the window is hidden. Re-rendering 10
    // times a second made SwiftUI/AppKit layout cost grow over hours until
    // the app used a full CPU core.
    var clock = Countdown() { willSet { if !inTick { objectWillChange.send() } } }
    private var inTick = false
    private var lastDrawn = ""
    var panelVisible = false { didSet { if panelVisible && !oldValue { objectWillChange.send() } } }
    @Published var mode: TimerMode = .duration
    @Published var hourText = String(Calendar.current.component(.hour, from: Date().addingTimeInterval(1800)))
    @Published var targetMinuteText = String(Calendar.current.component(.minute, from: Date().addingTimeInterval(1800)))
    @Published var activeTarget: Date?
    var now = Date()
    func candidate(at date: Date) -> Date? {
        guard let hour = Int(hourText.trimmingCharacters(in: .whitespaces)),
              let minute = Int(targetMinuteText.trimmingCharacters(in: .whitespaces)) else { return nil }
        return nextTarget(hour: hour, minute: minute, after: date)
    }
    var targetLabel: String {
        guard let target = activeTarget ?? candidate(at: now) else { return "時刻は00:00〜23:59" }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        let day = Calendar.current.isDate(target, inSameDayAs: now) ? "今日" : Calendar.current.isDateInTomorrow(target) ? "翌日" : "別日"
        return "\(day) \(formatter.string(from: target)) まで"
    }
    // Task from ぽいっと, if one is being timed.
    @Published var task: TaskRequest?
    @Published var taskFinished = false
    @Published var copied = false
    var work = WorkLog()
    var workedSeconds: Int { Int(work.elapsed(at: now)) }
    var workedText: String { String(format: "%d:%02d", workedSeconds / 60, workedSeconds % 60) }
    // In a task the overrun keeps counting, so the main button pauses even after time is up.
    var showsPause: Bool { task != nil ? (clock.running && !taskFinished) : (clock.running && !expired) }

    func startTask(_ request: TaskRequest) {
        let date = Date()
        mode = .duration; activeTarget = nil; error = ""
        task = request; taskFinished = false; copied = false; work = WorkLog()
        let seconds = max(60, (request.minutes * 60).rounded())
        clock.set(seconds)
        minuteText = String(Int(seconds) / 60); secondText = String(Int(seconds) % 60)
        didRing = false
        clock.start(at: date); work.resume(at: date)
    }
    func finishTask() {
        guard task != nil, !taskFinished else { return }
        let date = Date()
        work.pause(at: date); clock.pause(at: date)
        taskFinished = true
        copyActual()
    }
    // Checked off on the page: stop counting but leave the clipboard alone.
    // "もう一度コピー" still copies the exact time (pauses excluded) if wanted.
    func endTaskFromPage(id: String) -> Bool {
        guard task?.id == id, !taskFinished else { return false }
        let date = Date()
        work.pause(at: date); clock.pause(at: date)
        taskFinished = true
        return true
    }
    // Stopped on the page (計測をやめる, or moved off Bar Timer): drop the task without copying.
    func cancelTask(id: String) -> Bool {
        guard task?.id == id else { return false }
        reset()
        return true
    }
    // Pause / resume from the page. Only acts when the state differs, so a repeated copy is harmless.
    func setTaskRunning(_ running: Bool, id: String) -> Bool {
        guard task?.id == id, !taskFinished, clock.running != running else { return false }
        toggle()
        return true
    }
    func copyActual() {
        guard let task else { return }
        let text = actualPayload(task: task, minutes: actualMinutes(work.elapsed(at: Date())))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    var actionLabel: String {
        if task != nil { return taskFinished ? "完了済み" : clock.running ? "一時停止" : "再開" }
        if clock.running && !expired { return mode == .until ? "停止" : "一時停止" }
        return expired ? "再スタート" : "スタート"
    }
    func changeMode() { clock.reset(); activeTarget = nil; didRing = false; error = ""; _ = apply() }

    @Published var minuteText = "25"
    @Published var secondText = "0"
    @Published var error = ""
    @Published var compact = false
    @Published var sound = true
    private var timer: Timer?
    private var didRing = false
    var onResize: ((Bool) -> Void)?
    var expired: Bool { clock.remaining <= 0 }
    var fraction: Double { min(1, max(0, clock.remaining / clock.duration)) }
    var timeText: String {
        if mode == .until && !clock.running && candidate(at: now) == nil { return "--:--" }
        let seconds = Int(expired ? floor(-clock.remaining) : ceil(clock.remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    var status: String {
        if task != nil {
            if taskFinished { return "完了 · 実績 \(actualMinutes(work.elapsed(at: now)))分" }
            if expired { return "見積もり超過 · 作業 \(workedText)" }
            return clock.running ? "作業中 · \(workedText)" : "一時停止中 · \(workedText)"
        }
        if expired { return "時間です · 超過" }
        if mode == .until { return targetLabel }
        if clock.running { return "残り時間" }
        return clock.remaining < clock.duration ? "一時停止中" : "準備できました"
    }
    init() {
        let saved = UserDefaults.standard.double(forKey: "duration")
        if saved >= 1 && saved <= 359999 {
            clock.set(saved)
            minuteText = String(Int(saved) / 60); secondText = String(Int(saved) % 60)
        }
        if UserDefaults.standard.object(forKey: "sound") != nil {
            sound = UserDefaults.standard.bool(forKey: "sound")
        }
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    // What the window shows; a change here is the only reason to re-render.
    var drawnState: String { "\(timeText)|\(status)|\(Int(fraction * 200))|\(clock.running)|\(task?.id ?? "")|\(taskFinished)|\(copied)" }
    func tick() {
        inTick = true
        now = Date()
        if mode == .until && !clock.running, let target = candidate(at: now) {
            clock.set(target.timeIntervalSince(now))
        }
        if clock.running {
            clock.tick(at: now)
            if expired && !didRing {
                didRing = true
                if sound { NSSound(named: NSSound.Name("Glass"))?.play() }
            }
        }
        inTick = false
        let drawn = drawnState
        if drawn != lastDrawn {
            lastDrawn = drawn
            if panelVisible { objectWillChange.send() }
        }
    }
    @discardableResult func apply() -> Bool {
        if mode == .until {
            let date = Date()
            guard let target = candidate(at: date) else { error = "時は0〜23、分は0〜59で入力"; return false }
            clock.set(target.timeIntervalSince(date)); activeTarget = nil
            didRing = false; error = ""; return true
        }
        guard let minutes = Int(minuteText.trimmingCharacters(in: .whitespaces)),
              let seconds = Int(secondText.trimmingCharacters(in: .whitespaces)),
              (0...5999).contains(minutes), (0...59).contains(seconds),
              minutes * 60 + seconds > 0 else {
            error = "分は0〜5999、秒は0〜59（合計1秒以上）"; return false
        }
        clock.set(Double(minutes * 60 + seconds)); didRing = false; error = ""
        UserDefaults.standard.set(clock.duration, forKey: "duration")
        return true
    }
    func preset(_ minutes: Int) { minuteText = String(minutes); secondText = "0"; _ = apply() }
    func toggle() {
        if task != nil {
            guard !taskFinished else { return }
            let date = Date()
            if clock.running { clock.pause(at: date); work.pause(at: date) }
            else {
                // Resuming after the estimate ran out continues the overrun instead of starting over.
                if clock.remaining <= 0 { clock.deadline = date.addingTimeInterval(clock.remaining) }
                else { clock.start(at: date) }
                work.resume(at: date)
            }
            return
        }
        if mode == .until {
            if clock.running && !expired { reset(); return }
            let date = Date()
            guard let target = candidate(at: date) else { error = "時は0〜23、分は0〜59で入力"; return }
            clock.set(target.timeIntervalSince(date)); clock.deadline = target
            activeTarget = target; didRing = false; error = ""; return
        }
        if clock.running && !expired { clock.pause(at: Date()) }
        else {
            if expired { clock.reset(); didRing = false }
            // First start uses the visible input, even without pressing Set.
            if clock.remaining == clock.duration && !compact { guard apply() else { return } }
            clock.start(at: Date())
        }
    }
    // In a task this cancels it: nothing is copied.
    func reset() {
        if task != nil { task = nil; taskFinished = false; copied = false; work = WorkLog() }
        clock.reset(); activeTarget = nil; didRing = false
    }
    func add(_ seconds: Double) {
        if mode == .until {
            guard clock.running else { return }
            clock.add(seconds, at: Date()); activeTarget = clock.deadline; didRing = false; return
        }
        clock.add(seconds, at: Date()); didRing = false
        minuteText = String(Int(ceil(clock.duration)) / 60)
        secondText = String(Int(ceil(clock.duration)) % 60)
    }
    func resize() { compact.toggle(); onResize?(compact) }
}

struct TimerView: View {
    @ObservedObject var model: TimerModel
    private var tint: Color { model.expired ? Color(red: 1, green: 0.43, blue: 0.36) : Color(red: 0.4, green: 0.86, blue: 0.73) }
    var body: some View {
        VStack(alignment: .leading, spacing: model.compact ? 10 : 16) {
            HStack(alignment: .center) {
                if !model.compact {
                    VStack(alignment: .leading, spacing: 4) {
                        if let task = model.task {
                            Text(task.title.isEmpty ? "タスク" : task.title)
                                .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        } else {
                            Text("BAR TIMER").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2)
                        }
                        Text(model.status).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                    }
                } else if let task = model.task {
                    Text(task.title.isEmpty ? "タスク" : task.title)
                        .font(.system(size: 11)).foregroundColor(tint).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(model.expired ? "超過" : "残り").font(.system(size: 11)).foregroundColor(tint)
                }
                Spacer(minLength: 4)
                Text((model.expired ? "+" : "") + model.timeText)
                    .font(.system(size: model.compact ? 24 : 36, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundColor(tint)
                    .accessibilityLabel("\(model.status) \(model.timeText)")
                Button(action: model.resize) { Image(systemName: model.compact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left") }
                    .buttonStyle(.plain).padding(7).help(model.compact ? "設定を表示" : "細く表示")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.09))
                    RoundedRectangle(cornerRadius: 5).fill(tint)
                        .frame(width: geo.size.width * (model.expired ? 1 : model.fraction))
                    HStack(spacing: 0) {
                        ForEach(0..<10) { _ in
                            Spacer(minLength: 0)
                            Rectangle().fill(Color.black.opacity(0.20)).frame(width: 1)
                        }
                    }.padding(.horizontal, 1)
                }
            }.frame(height: model.compact ? 12 : 24)
                .accessibilityLabel("残り \(Int(model.fraction * 100)) パーセント")
            if !model.compact, let task = model.task {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("見積もり \(Int(task.minutes.rounded()))分")
                        Spacer()
                        Text("作業 \(model.workedText)").monospacedDigit()
                    }.font(.system(size: 12)).foregroundColor(.secondary)
                    if model.taskFinished {
                        HStack(spacing: 8) {
                            Text(model.copied ? "実績をコピーしました。ぽいっとのページで ⌘V を押すと記録されます" : "ページで完了にしました。一時停止を除いた実績で入れ直すときは、コピーしてページで ⌘V")
                                .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(model.copied ? "もう一度コピー" : "コピー") { model.copyActual() }.controlSize(.small)
                        }
                    } else {
                        Text("終わったら「完了」を押すと、実績（一時停止中を除いた時間）がコピーされます")
                            .font(.system(size: 10)).foregroundColor(.secondary)
                    }
                }
            } else if !model.compact {
                // Plain SwiftUI buttons instead of a segmented Picker: on macOS 26
                // the AppKit-backed segmented control got slower on every
                // re-render, eventually using a full CPU core.
                HStack(spacing: 2) {
                    ForEach([(TimerMode.duration, "時間で指定"), (TimerMode.until, "終了時刻で指定")], id: \.0) { item in
                        let selected = model.mode == item.0
                        Button {
                            guard !selected else { return }
                            model.mode = item.0; model.changeMode()
                        } label: {
                            Text(item.1).font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(selected ? 0.18 : 0)))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                    .disabled(model.clock.running).opacity(model.clock.running ? 0.5 : 1)
                    .accessibilityLabel("指定方法")
                if model.mode == .duration {
                    HStack(spacing: 6) {
                        TextField("分", text: $model.minuteText).frame(width: 54).accessibilityLabel("設定する分")
                        Text("分").foregroundColor(.secondary)
                        TextField("秒", text: $model.secondText).frame(width: 42).accessibilityLabel("設定する秒")
                        Text("秒").foregroundColor(.secondary)
                        Spacer()
                        Button("設定") { model.apply() }
                    }.textFieldStyle(.roundedBorder).disabled(model.clock.running)
                    HStack(spacing: 6) {
                        ForEach([5, 10, 15, 25, 45, 60], id: \.self) { minutes in
                            Button("\(minutes)分") { model.preset(minutes) }.disabled(model.clock.running)
                        }
                    }.controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        TextField("時", text: $model.hourText).frame(width: 48).accessibilityLabel("終了時刻の時・24時間表記")
                        Text(":")
                        TextField("分", text: $model.targetMinuteText).frame(width: 48).accessibilityLabel("終了時刻の分")
                        Text("まで").foregroundColor(.secondary)
                        Spacer()
                        Text("24時間表記").font(.system(size: 11)).foregroundColor(.secondary)
                    }.textFieldStyle(.roundedBorder).disabled(model.clock.running)
                    Text(model.targetLabel + " · Macの現地時刻")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text(model.error.isEmpty ? (model.mode == .until ? "時刻指定は停止すると解除されます" : "時間を入力してスタート") : model.error)
                    .font(.system(size: 10)).foregroundColor(model.error.isEmpty ? .secondary : .orange)
            }
            HStack(spacing: 10) {
                Button(action: model.toggle) {
                    Label(model.actionLabel, systemImage: model.showsPause ? (model.mode == .until ? "stop.fill" : "pause.fill") : (model.taskFinished ? "checkmark" : "play.fill"))
                        .font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.borderedProminent).tint(tint).foregroundColor(.black).disabled(model.taskFinished)
                Button(action: model.reset) { Image(systemName: model.task != nil ? "xmark" : "arrow.counterclockwise") }
                    .help(model.task != nil ? "タスクの計測をやめる（実績はコピーしない）" : "設定時間に戻す")
                if model.task != nil {
                    if model.taskFinished {
                        if model.compact { Button("コピー") { model.copyActual() }.controlSize(.small) }
                    } else {
                        Button("完了") { model.finishTask() }.controlSize(.small).help("計測を止めて実績をコピー")
                    }
                }
                Spacer(minLength: 0)
                Button("+1分") { model.add(60) }.controlSize(.small).disabled(model.mode == .until && !model.clock.running)
                if !model.compact {
                    Button("+5分") { model.add(300) }.controlSize(.small).disabled(model.mode == .until && !model.clock.running)
                    Button {
                        model.sound.toggle(); UserDefaults.standard.set(model.sound, forKey: "sound")
                    } label: { Image(systemName: model.sound ? "speaker.wave.2" : "speaker.slash") }
                    .buttonStyle(.plain).help(model.sound ? "終了音をオフ" : "終了音をオン")
                }
            }
        }
        .padding(model.compact ? 14 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.075, green: 0.09, blue: 0.12))
        .foregroundColor(.white).preferredColorScheme(.dark)
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel!
    var statusItem: NSStatusItem!
    let model = TimerModel()
    var menuTimer: Timer?
    static let showRequest = Notification.Name("local.bartimer.show-panel")
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: ask the running copy to show its window, then quit.
        // The menu bar item may be hidden (e.g. behind the notch), so a second
        // launch must still give the user a visible way in.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(Self.showRequest, object: id, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil); return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showCompactPanel),
            name: Self.showRequest, object: Bundle.main.bundleIdentifier, suspensionBehavior: .deliverImmediately)
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 350),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Bar Timer · 常に最前面"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TimerView(model: model))
        panel.center()
        panel.setFrameAutosaveName("BarTimerWindow")
        model.onResize = { [weak self] compact in
            guard let panel = self?.panel else { return }
            let top = panel.frame.maxY
            panel.setContentSize(NSSize(width: compact ? 330 : 390, height: compact ? 125 : 350))
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "時間・終了時刻を設定…", action: #selector(showPanel), keyEquivalent: "")
        show.target = self
        let toggle = menu.addItem(withTitle: "スタート / 一時停止 / 停止", action: #selector(toggleTimer), keyEquivalent: "")
        toggle.target = self
        let paste = menu.addItem(withTitle: "コピーしたタスクを計る", action: #selector(startCopiedTask), keyEquivalent: "")
        paste.target = self
        let auto = menu.addItem(withTitle: "Chrome でコピーしたタスクを自動で計る", action: #selector(toggleAutoStart(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = autoStartCopied ? .on : .off
        let finish = menu.addItem(withTitle: "タスクを完了して実績をコピー", action: #selector(finishTask), keyEquivalent: "")
        finish.target = self
        let hide = menu.addItem(withTitle: "小窓を隠す（計測は継続）", action: #selector(hidePanel), keyEquivalent: "")
        hide.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Bar Timerを終了", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        updateMenuBar()
        menuTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.updateMenuBar(); self?.checkCopiedTask() }
        RunLoop.main.add(menuTimer!, forMode: .common)
        // Show the window on launch: the menu bar item alone can be invisible
        // when the menu bar is crowded or the item sits behind the notch.
        // Use the slim layout so it stays out of the way; settings open from the menu.
        showCompactPanel()
        if let request = pendingTask { pendingTask = nil; startTask(request) }
    }
    // bartimer://start links from ぽいっと. A link that arrives while
    // launching waits until the window exists.
    private var pendingTask: TaskRequest?
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = parseStartURL(url) else { continue }
            if panel == nil { pendingTask = request } else { startTask(request) }
        }
    }
    func startTask(_ request: TaskRequest) {
        model.startTask(request)
        updateMenuBar()
        showCompactPanel()
    }
    // Auto start: when ぽいっと's ▶ 計る copies a bartimer://start link in Chrome.
    // Only a new copy that Chrome marked with its source page is read; other copies
    // (other apps, Bar Timer's own) are never read. The text is dropped unless it is a start link.
    private static let autoKey = "autoStartCopiedTask"
    private static let chromeSource = NSPasteboard.PasteboardType("org.chromium.source-url")
    private var autoStartCopied: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey) }
    }
    private var seenPasteboardChange = NSPasteboard.general.changeCount
    func checkCopiedTask() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != seenPasteboardChange else { return }
        seenPasteboardChange = pasteboard.changeCount
        guard autoStartCopied else { return }
        if #available(macOS 15.4, *), pasteboard.accessBehavior == .alwaysDeny { return }
        guard let types = pasteboard.types, types.contains(.string), types.contains(Self.chromeSource),
              let text = pasteboard.string(forType: .string) else { return }
        if let (command, id) = parseTaskCommand(text) {
            let changed: Bool
            switch command {
            case .finish: changed = model.endTaskFromPage(id: id)
            case .pause: changed = model.setTaskRunning(false, id: id)
            case .resume: changed = model.setTaskRunning(true, id: id)
            case .cancel: changed = model.cancelTask(id: id)
            }
            if changed { updateMenuBar() }
            return
        }
        guard text.hasPrefix("bartimer://start?"), let request = parseStartText(text) else { return }
        startTask(request)
    }
    @objc func toggleAutoStart(_ sender: NSMenuItem) {
        autoStartCopied.toggle()
        sender.state = autoStartCopied ? .on : .off
        seenPasteboardChange = NSPasteboard.general.changeCount
    }
    // Manual start: reads the clipboard only when chosen from the menu.
    @objc func startCopiedTask() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let request = parseStartText(text) else { NSSound.beep(); showCompactPanel(); return }
        startTask(request)
    }
    @objc func finishTask() {
        guard model.task != nil else { showPanel(); return }
        model.finishTask(); updateMenuBar()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showCompactPanel(); return false
    }
    static let barWidth: CGFloat = 45 // menu bar progress bar length (pt)
    private var lastMenuBar = ""
    func updateMenuBar() {
        let barWidth = Self.barWidth
        let fraction = model.expired ? 1.0 : model.fraction
        let key = "\(model.timeText)|\(model.status)|\(model.expired)|\(Int(fraction * barWidth * 2))"
        guard key != lastMenuBar else { return }
        lastMenuBar = key
        let color = model.expired ? NSColor.systemRed : NSColor.systemMint
        let image = NSImage(size: NSSize(width: barWidth, height: 14), flipped: false) { rect in
            let track = NSRect(x: 0, y: 3, width: barWidth, height: 8)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            if fraction > 0 {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: 3, width: barWidth * fraction, height: 8), xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.image = image
        statusItem.button?.title = " " + (model.expired ? "+" : "") + model.timeText
        statusItem.button?.toolTip = "Bar Timer · " + (model.task.map { ($0.title.isEmpty ? "タスク" : $0.title) + " · " } ?? "") + model.status + " · クリックして設定"
        statusItem.button?.setAccessibilityLabel("Bar Timer " + model.status + " " + model.timeText)
    }
    @objc func showPanel() {
        guard let panel else { return }
        if model.compact { model.resize() }
        model.panelVisible = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    // Slim timer only. Does not take focus away from the app being used.
    @objc func showCompactPanel() {
        guard let panel else { return }
        if !model.compact { model.resize() }
        model.panelVisible = true
        panel.orderFrontRegardless()
    }
    @objc func hidePanel() { model.panelVisible = false; panel.orderOut(nil) }
    @objc func toggleTimer() { model.toggle(); updateMenuBar(); if !model.error.isEmpty { showPanel() } }
    @objc func quitApp() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hidePanel(); return false }
}

func selfTest() {
    let now = Date(timeIntervalSince1970: 1000)
    var c = Countdown()
    c.set(120); c.start(at: now); c.tick(at: now.addingTimeInterval(30))
    precondition(c.remaining == 90)
    c.pause(at: now.addingTimeInterval(40)); c.tick(at: now.addingTimeInterval(100))
    precondition(c.remaining == 80 && !c.running)
    c.start(at: now.addingTimeInterval(100)); c.tick(at: now.addingTimeInterval(200))
    precondition(c.remaining == -20)
    c.add(60, at: now.addingTimeInterval(200)); precondition(c.remaining == 60)
    c.tick(at: now.addingTimeInterval(210)); precondition(c.remaining == 50)
    c.reset(); precondition(c.remaining == 120 && !c.running)
    c.set(3600); c.start(at: now); c.tick(at: now.addingTimeInterval(7200))
    precondition(c.remaining == -3600) // Simulated sleep / delayed callback.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
    let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9, minute: 30))!
    let today = nextTarget(hour: 10, minute: 0, after: morning, calendar: calendar)!
    precondition(today.timeIntervalSince(morning) == 1800)
    let tomorrow = nextTarget(hour: 9, minute: 0, after: morning, calendar: calendar)!
    precondition(tomorrow.timeIntervalSince(morning) == 23.5 * 3600)
    precondition(nextTarget(hour: 9, minute: 30, after: morning, calendar: calendar)!.timeIntervalSince(morning) == 86400)
    precondition(nextTarget(hour: 24, minute: 0, after: morning, calendar: calendar) == nil)
    precondition(nextTarget(hour: 12, minute: 60, after: morning, calendar: calendar) == nil)
    c.set(today.timeIntervalSince(morning)); c.deadline = today
    c.tick(at: today.addingTimeInterval(15)); precondition(c.remaining == -15)

    // Links from ぽいっと
    let good = parseStartURL(URL(string: "bartimer://start?min=45&task=t1a_b-2&title=%E7%B5%8C%E8%B2%BB%E7%B2%BE%E7%AE%97")!)
    precondition(good == TaskRequest(id: "t1a_b-2", title: "経費精算", minutes: 45))
    precondition(parseStartURL(URL(string: "bartimer://start?min=0&task=t1")!) == nil)
    precondition(parseStartURL(URL(string: "bartimer://start?min=10")!) == nil)
    precondition(parseStartURL(URL(string: "bartimer://start?min=10&task=a%20b")!) == nil)
    precondition(parseStartURL(URL(string: "bartimer://stop?min=10&task=t1")!) == nil)
    precondition(parseStartURL(URL(string: "https://start?min=10&task=t1")!) == nil)

    // Work time: paused time is excluded, overrun is included.
    var w = WorkLog()
    w.resume(at: now); w.pause(at: now.addingTimeInterval(600))
    w.pause(at: now.addingTimeInterval(700))
    w.resume(at: now.addingTimeInterval(900))
    precondition(w.elapsed(at: now.addingTimeInterval(1500)) == 1200)
    precondition(actualMinutes(1200) == 20 && actualMinutes(10) == 1 && actualMinutes(89) == 1 && actualMinutes(91) == 2)
    precondition(actualPayload(task: good!, minutes: 43).hasPrefix("poipoi:actual?task=t1a_b-2&min=43 "))
    precondition(parseStartText("Bar Timer: bartimer://start?min=20&task=t9&title=x\n")?.id == "t9")
    precondition(parseStartText("bartimer://start?min=20&task=t9 （ごはん / 20分）")?.minutes == 20)
    precondition(parseStartText("poipoi:actual?task=t9&min=3") == nil)
    precondition(parseFinishText("bartimer://finish?task=t9_a-1 （ごはん）") == "t9_a-1")
    precondition(parseFinishText("bartimer://finish?task=a%20b") == nil)
    precondition(parseFinishText("bartimer://start?min=5&task=t9") == nil)
    precondition(parseStartText("bartimer://finish?task=t9") == nil)
    precondition(parseTaskCommand("bartimer://pause?task=t9")! == (.pause, "t9"))
    precondition(parseTaskCommand("bartimer://resume?task=t9 （x）")! == (.resume, "t9"))
    precondition(parseTaskCommand("bartimer://start?min=5&task=t9") == nil)
    precondition(parseTaskCommand("bartimer://pause?task=") == nil)
    precondition(parseTaskCommand("bartimer://cancel?task=t9")! == (.cancel, "t9"))
    print("Countdown, target-time, link and work-time tests passed")
}
if CommandLine.arguments.contains("--self-test") {
    selfTest()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
