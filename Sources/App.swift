import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, AVSpeechSynthesizerDelegate {
    private let defaults = UserDefaults.standard
    private let speaker = AVSpeechSynthesizer()
    private let readerQueue = DispatchQueue(label: "local.wordspeaker.selection", qos: .userInitiated)
    private var statusItem: NSStatusItem!
    private var autoMenuItem: NSMenuItem!
    private var permissionMenuItem: NSMenuItem!
    private var lastMenuItem: NSMenuItem!
    private var window: NSWindow!
    private var sampleView: NSTextView!
    private var permissionLabel: NSTextField!
    private var lastLabel: NSTextField!
    private var autoSwitch: NSButton!
    private var accentControl: NSSegmentedControl!
    private var voiceControl: NSPopUpButton!
    private var availableVoices: [AVSpeechSynthesisVoice] = []
    private var speedControl: NSSlider!
    private var timer: Timer?
    private var dragMonitor: Any?
    private var lastExternalDrag: TimeInterval = -.infinity
    private var gate = SelectionGate()
    private var localGate = SelectionGate()
    private var reading = false
    private var generation = 0
    private var lastPID: pid_t = 0
    private var lastText = ""
    private var trusted = false
    private var speechDidStart = false
    private var startedVoiceIdentifier: String?
    private var pollCount = 0
    private var autoEnabled: Bool { defaults.bool(forKey: "autoEnabled") }
    private var language: String { defaults.string(forKey: "language") ?? "en-US" }
    private var speed: Float { defaults.float(forKey: "speed") }
    private var smokeTest: Bool { CommandLine.arguments.contains("--ui-smoke-test") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["autoEnabled": true, "language": "en-US", "speed": 0.46])
        speaker.delegate = self
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusMenu()
        setupWindow()
        refreshPermission()
        timer = Timer(timeInterval: 0.30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Default mode pauses this timer while AppKit tracks a local drag.
        RunLoop.main.add(timer!, forMode: .default)
        if !smokeTest {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event.type == .leftMouseDragged {
                        self.lastExternalDrag = ProcessInfo.processInfo.systemUptime
                        self.gate.interrupt()
                        self.generation += 1
                    } else {
                        self.lastExternalDrag = -.infinity
                    }
                }
            }
        }
        if !smokeTest { showWindow() }

        if smokeTest {
            let choice = voiceControl.item(at: 1)
            let expectedVoice = choice?.representedObject as? String
            voiceControl.select(choice)
            // Exercise native controls -> timer -> selection gate -> speech in
            // an offscreen window so live desktop input cannot alter the test.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                window.makeFirstResponder(sampleView)
                sampleView.setSelectedRange(NSRange(location: 0, length: 7))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [self] in
                let passed = lastText == "project" && speechDidStart && expectedVoice != nil && startedVoiceIdentifier == expectedVoice
                print(passed ? "UI_SMOKE_PASS: selected project -> speech started with chosen voice \(expectedVoice!)" : "UI_SMOKE_FAIL: text=\(lastText), speechStarted=\(speechDidStart), expectedVoice=\(expectedVoice ?? "none"), actualVoice=\(startedVoiceIdentifier ?? "none"), polls=\(pollCount)")
                fflush(stdout)
                speaker.stopSpeaking(at: .immediate)
                exit(passed ? 0 : 1)
            }
        }
    }

    private func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出划词即听", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", Selector(("undo:")), "z"), ("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func menuItem(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func setupStatusMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "划词即听")
        statusItem.button?.toolTip = "划词即听 · 选中英文，自动发音"
        let menu = NSMenu()
        menu.addItem(menuItem("划词即听", nil))
        lastMenuItem = menuItem("等待选中英文…", nil)
        menu.addItem(lastMenuItem)
        menu.addItem(.separator())
        autoMenuItem = menuItem("自动朗读选中的英文", #selector(toggleAutomatic))
        menu.addItem(autoMenuItem)
        menu.addItem(menuItem("再读一遍", #selector(repeatLast)))
        menu.addItem(menuItem("朗读剪贴板（先按 ⌘C）", #selector(readClipboard)))
        menu.addItem(menuItem("停止朗读", #selector(stopSpeech)))
        menu.addItem(.separator())
        permissionMenuItem = menuItem("开启辅助功能权限…", #selector(openAccessibility))
        menu.addItem(permissionMenuItem)
        menu.addItem(menuItem("设置与试读…", #selector(showWindow)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出划词即听", #selector(quit)))
        statusItem.menu = menu
    }

    private func label(_ title: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: title)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func setupWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "划词即听 · 声音版"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let content = window.contentView!
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 17
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22)
        ])
        stack.addArrangedSubview(label("选中一个词，听见它。", size: 27, weight: .semibold))
        stack.addArrangedSubview(label("在支持的浏览器、PDF、文档中选中英文，松手后自动发音。\n关闭这个窗口后，小工具仍在顶部菜单栏运行。", color: .secondaryLabelColor))

        permissionLabel = label("检查辅助功能权限…", weight: .medium)
        stack.addArrangedSubview(row([permissionLabel, button("打开权限设置", #selector(openAccessibility))]))

        autoSwitch = NSButton(checkboxWithTitle: "自动朗读选中的英文", target: self, action: #selector(toggleAutomatic))
        autoSwitch.state = autoEnabled ? .on : .off
        stack.addArrangedSubview(autoSwitch)

        accentControl = NSSegmentedControl(labels: ["美音", "英音"], trackingMode: .selectOne, target: self, action: #selector(changeAccent))
        accentControl.selectedSegment = language == "en-GB" ? 1 : 0
        speedControl = NSSlider(value: Double(speed), minValue: 0.30, maxValue: 0.58, target: self, action: #selector(changeSpeed))
        speedControl.widthAnchor.constraint(equalToConstant: 155).isActive = true
        stack.addArrangedSubview(row([label("口音"), accentControl, label("语速"), label("慢", color: .secondaryLabelColor), speedControl, label("快", color: .secondaryLabelColor)], spacing: 10))

        voiceControl = NSPopUpButton(frame: .zero, pullsDown: false)
        voiceControl.setAccessibilityLabel("英语声音")
        voiceControl.target = self
        voiceControl.action = #selector(changeVoice)
        stack.addArrangedSubview(row([label("声音"), voiceControl, button("刷新列表", #selector(refreshVoices))]))
        stack.addArrangedSubview(label("更多声音：在系统设置的「无障碍 → 阅读与朗读」中下载。", size: 11, color: .secondaryLabelColor))
        refreshVoices()

        stack.addArrangedSubview(label("现在试试：双击下方的 project", size: 14, weight: .semibold))
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sampleView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 96))
        sampleView.isRichText = false
        sampleView.isEditable = true
        sampleView.isSelectable = true
        sampleView.font = .systemFont(ofSize: 21)
        sampleView.textContainerInset = NSSize(width: 14, height: 14)
        sampleView.isHorizontallyResizable = false
        sampleView.autoresizingMask = [.width]
        sampleView.textContainer?.widthTracksTextView = true
        sampleView.string = "project   language   beautiful   experience\nYou can also type a word here."
        scroll.documentView = sampleView
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor), scroll.heightAnchor.constraint(equalToConstant: 104)])

        lastLabel = label("等待选中英文…", size: 14, color: .secondaryLabelColor)
        lastLabel.maximumNumberOfLines = 2
        stack.addArrangedSubview(lastLabel)
        stack.addArrangedSubview(row([button("试听声音", #selector(playExample)), button("再读一遍", #selector(repeatLast)), button("停止", #selector(stopSpeech))]))
        let footnote = label("所有文字均交给本机系统语音朗读，本程序不联网、不保存划词历史。\n若某个应用无法划词取词：选中文字按 ⌘C，再点菜单栏的“朗读剪贴板”。", size: 11, color: .secondaryLabelColor)
        stack.addArrangedSubview(footnote)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        updateAutomaticUI()
    }

    private func refreshPermission() {
        let value = AXIsProcessTrusted()
        if value != trusted { gate.reset(); generation += 1 }
        trusted = value
        permissionLabel.stringValue = value ? "● 全局划词已就绪" : "● 全局划词需要辅助功能权限"
        permissionLabel.textColor = value ? .systemGreen : .systemOrange
        permissionMenuItem.title = value ? "辅助功能权限已开启 ✓" : "开启辅助功能权限…"
    }

    private func poll() {
        pollCount += 1
        refreshPermission()
        guard autoEnabled else { return }
        pollLocalSelection()
        guard let front = NSWorkspace.shared.frontmostApplication else { return }
        let pid = front.processIdentifier
        if lastPID != pid { gate.reset(); generation += 1; lastPID = pid }

        if pid == ProcessInfo.processInfo.processIdentifier { return }
        guard trusted, !reading, !recentExternalDrag else { return }
        reading = true
        let ticket = generation
        readerQueue.async { [weak self] in
            let result = AccessibilityReader.read(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.generation == ticket, self.autoEnabled, AXIsProcessTrusted(),
                      !self.recentExternalDrag,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                switch result {
                case .selection(let selection): self.consume(selection)
                case .empty: self.consume(nil)
                case .unavailable: self.gate.interrupt()
                }
            }
        }
    }

    private var recentExternalDrag: Bool {
        // A missed mouse-up or another pressed button must never block polling.
        ProcessInfo.processInfo.systemUptime - lastExternalDrag < 0.45
    }

    private func consume(_ selection: Selection?) {
        if let text = gate.update(selection) { speak(text) }
    }

    private func pollLocalSelection() {
        // Own-window text never needs AX permission or foreground activation.
        // Use a separate gate so switching other apps cannot re-trigger it.
        let range = sampleView.selectedRange()
        guard window.isVisible || smokeTest, range.length > 0,
              NSMaxRange(range) <= (sampleView.string as NSString).length else {
            _ = localGate.update(nil)
            return
        }
        let text = (sampleView.string as NSString).substring(with: range)
        if let ready = localGate.update(Selection.english(text, identity: "local:\(range.location):\(range.length)")) {
            speak(ready)
        }
    }

    private var voicePreferenceKey: String { "voiceIdentifier.\(language)" }

    @objc private func refreshVoices() {
        availableVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            guard voice.language == language else { return false }
            if #available(macOS 14.0, *) {
                return !voice.voiceTraits.contains(.isNoveltyVoice) && !voice.voiceTraits.contains(.isPersonalVoice)
            }
            return true
        }.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        voiceControl.removeAllItems()
        voiceControl.addItem(withTitle: "自动（优先高质量）")
        for voice in availableVoices {
            let quality = voice.quality == .premium ? "优质" : voice.quality == .enhanced ? "增强" : "标准"
            let label = "\(voice.name) · \(quality)"
            var title = label
            var suffix = 2
            while voiceControl.item(withTitle: title) != nil {
                title = "\(label) (\(suffix))"
                suffix += 1
            }
            voiceControl.addItem(withTitle: title)
            voiceControl.lastItem?.representedObject = voice.identifier
        }
        let saved = defaults.string(forKey: voicePreferenceKey)
        voiceControl.select(voiceControl.itemArray.first { ($0.representedObject as? String) == saved } ?? voiceControl.item(at: 0))
    }

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        if let identifier = voiceControl.selectedItem?.representedObject as? String,
           let voice = availableVoices.first(where: { $0.identifier == identifier }) { return voice }
        if let best = availableVoices.first, best.quality != .default { return best }
        let preferredName = language == "en-GB" ? "Daniel" : "Samantha"
        return availableVoices.first(where: { $0.name == preferredName })
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func speak(_ text: String) {
        guard let voice = preferredVoice() else {
            lastLabel.stringValue = "未找到英语语音，请在系统设置的「无障碍 → 阅读与朗读」中下载。"
            return
        }
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = speed
        speaker.speak(utterance)
        lastText = text
        lastLabel.stringValue = "最近朗读：\(text)"
        lastLabel.textColor = .labelColor
        lastMenuItem.title = "最近：\(text.prefix(32))\(text.count > 32 ? "…" : "")"
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identifier = utterance.voice?.identifier
        DispatchQueue.main.async { [weak self] in
            self?.speechDidStart = true
            self?.startedVoiceIdentifier = identifier
        }
    }

    @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibility() {
        // Called only from an explicit user click; never change system settings.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateAutomaticUI() {
        autoSwitch.state = autoEnabled ? .on : .off
        autoMenuItem.state = autoEnabled ? .on : .off
        statusItem.button?.appearsDisabled = !autoEnabled
    }

    @objc private func toggleAutomatic() {
        defaults.set(!autoEnabled, forKey: "autoEnabled")
        generation += 1
        gate.reset()
        localGate.reset()
        if !autoEnabled { speaker.stopSpeaking(at: .immediate) }
        updateAutomaticUI()
    }

    @objc private func changeAccent() {
        defaults.set(accentControl.selectedSegment == 1 ? "en-GB" : "en-US", forKey: "language")
        refreshVoices()
    }
    @objc private func changeVoice() {
        defaults.set(voiceControl.selectedItem?.representedObject as? String, forKey: voicePreferenceKey)
    }
    @objc private func changeSpeed() { defaults.set(speedControl.floatValue, forKey: "speed") }
    @objc private func playExample() { speak("This is a short preview of the voice. Let's work on a new project together.") }
    @objc private func repeatLast() { if !lastText.isEmpty { speak(lastText) } }
    @objc private func stopSpeech() { speaker.stopSpeaking(at: .immediate) }

    @objc private func readClipboard() {
        if let raw = NSPasteboard.general.string(forType: .string),
           let selection = Selection.english(raw, identity: "clipboard") {
            speak(selection.text)
        } else {
            lastLabel.stringValue = "请先复制英文单词或短句（最多 160 字符、20 个词）。"
            showWindow()
        }
    }

    @objc private func quit() {
        timer?.invalidate()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        speaker.stopSpeaking(at: .immediate)
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowDidBecomeKey(_ notification: Notification) { refreshVoices() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}
