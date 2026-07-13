import AppKit
import Carbon
import ApplicationServices

struct SurfaceContext: Codable, Equatable {
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String

    var displayName: String {
        windowTitle.isEmpty ? appName : "\(appName) · \(windowTitle)"
    }

    func matches(_ other: SurfaceContext) -> Bool {
        guard bundleIdentifier == other.bundleIdentifier else { return false }
        if windowTitle.isEmpty || other.windowTitle.isEmpty { return true }
        return windowTitle == other.windowTitle
    }
}

enum AnnotationKind: String, Codable {
    case task
    case note
}

struct Annotation: Codable, Identifiable {
    let id: UUID
    var text: String
    var completed: Bool
    let context: SurfaceContext
    let createdAt: Date
    var completedAt: Date?
    var screenX: Double
    var screenY: Double
    var kind: AnnotationKind?

    var resolvedKind: AnnotationKind { kind ?? .task }
}

struct CodablePoint: Codable {
    let x: Double
    let y: Double

    var nsPoint: NSPoint { NSPoint(x: x, y: y) }
}

struct ScreenDrawing: Codable, Identifiable {
    let id: UUID
    let context: SurfaceContext
    let createdAt: Date
    let start: CodablePoint
    let end: CodablePoint
    let color: String
    let lineWidth: Double
}

struct ChronicleEvent: Codable {
    let schema: String
    let timestamp: Date
    let eventType: String
    let annotation: Annotation
}

struct DrawingChronicleEvent: Codable {
    let schema: String
    let timestamp: Date
    let eventType: String
    let drawing: ScreenDrawing
}

@MainActor
final class AnnotationStore {
    static let shared = AnnotationStore()
    private(set) var annotations: [Annotation] = []
    private(set) var drawings: [ScreenDrawing] = []

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Screenotate", isDirectory: true)
    }

    var annotationsURL: URL { directoryURL.appendingPathComponent("annotations.json") }
    var drawingsURL: URL { directoryURL.appendingPathComponent("drawings.json") }
    var eventsURL: URL { directoryURL.appendingPathComponent("chronicle-events.jsonl") }

    private init() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: annotationsURL),
           let decoded = try? decoder.decode([Annotation].self, from: data) {
            annotations = decoded
        }
        if let drawingData = try? Data(contentsOf: drawingsURL),
           let decodedDrawings = try? decoder.decode([ScreenDrawing].self, from: drawingData) {
            drawings = decodedDrawings
        }
    }

    func add(
        text: String,
        context: SurfaceContext,
        point: NSPoint,
        kind: AnnotationKind = .task,
        eventType: String = "annotation.created"
    ) {
        let annotation = Annotation(
            id: UUID(), text: text, completed: false, context: context,
            createdAt: Date(), completedAt: nil,
            screenX: point.x, screenY: point.y, kind: kind
        )
        annotations.append(annotation)
        persist(eventType: eventType, annotation: annotation)
    }

    func addBatch(
        texts: [String],
        context: SurfaceContext,
        point: NSPoint,
        eventType: String = "annotation.imported"
    ) {
        for (offset, text) in texts.enumerated() {
            let column = offset / 6
            let row = offset % 6
            let rowPoint = NSPoint(
                x: point.x + Double(column * 324),
                y: point.y - Double(row * 104)
            )
            add(text: text, context: context, point: rowPoint, eventType: eventType)
        }
    }

    func toggle(id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].completed.toggle()
        annotations[index].completedAt = annotations[index].completed ? Date() : nil
        persist(eventType: annotations[index].completed ? "annotation.completed" : "annotation.reopened", annotation: annotations[index])
    }

    func remove(id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let annotation = annotations.remove(at: index)
        persist(eventType: "annotation.deleted", annotation: annotation)
    }

    func addDrawing(start: NSPoint, end: NSPoint, context: SurfaceContext) {
        let drawing = ScreenDrawing(
            id: UUID(), context: context, createdAt: Date(),
            start: CodablePoint(x: start.x, y: start.y),
            end: CodablePoint(x: end.x, y: end.y),
            color: "systemYellow", lineWidth: 7
        )
        drawings.append(drawing)
        persistDrawings(eventType: "drawing.created", drawing: drawing)
    }

    func removeDrawing(id: UUID) {
        guard let index = drawings.firstIndex(where: { $0.id == id }) else { return }
        let drawing = drawings.remove(at: index)
        persistDrawings(eventType: "drawing.deleted", drawing: drawing)
    }

    func removeDrawings(matching context: SurfaceContext) {
        let matching = drawings.filter { $0.context.matches(context) }
        for drawing in matching { removeDrawing(id: drawing.id) }
    }

    private func persist(eventType: String, annotation: Annotation) {
        if let data = try? encoder.encode(annotations) {
            try? data.write(to: annotationsURL, options: .atomic)
        }

        let event = ChronicleEvent(schema: "screenotate.chronicle.v1", timestamp: Date(), eventType: eventType, annotation: annotation)
        guard let eventData = try? encoder.encode(event) else { return }
        var compact = Data(eventData.filter { $0 != 10 })
        compact.append(10)
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: compact)
        } else if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: compact)
        }
    }

    private func persistDrawings(eventType: String, drawing: ScreenDrawing) {
        if let data = try? encoder.encode(drawings) {
            try? data.write(to: drawingsURL, options: .atomic)
        }
        let event = DrawingChronicleEvent(
            schema: "screenotate.chronicle.v1", timestamp: Date(),
            eventType: eventType, drawing: drawing
        )
        guard let eventData = try? encoder.encode(event) else { return }
        var compact = Data(eventData.filter { $0 != 10 })
        compact.append(10)
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: compact)
        } else if let handle = try? FileHandle(forWritingTo: eventsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: compact)
        }
    }
}

struct ChecklistCandidate: Hashable {
    let text: String
    let likelyTask: Bool
}

@MainActor
enum AccessibilityChecklistReader {
    static func isTrusted(prompt: Bool) -> Bool {
        if !prompt { return AXIsProcessTrusted() }
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func candidates(processIdentifier: pid_t) -> [ChecklistCandidate] {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            application, kAXFocusedWindowAttribute as CFString, &focusedValue
        )
        let root = focusedResult == .success && focusedValue != nil
            ? unsafeDowncast(focusedValue!, to: AXUIElement.self)
            : application

        var collected: [ChecklistCandidate] = []
        var visited = 0
        walk(root, depth: 0, visited: &visited, collected: &collected)

        var seen = Set<String>()
        return collected.filter { candidate in
            let key = candidate.text.lowercased()
            guard seen.insert(key).inserted else { return false }
            return true
        }.sorted {
            if $0.likelyTask != $1.likelyTask { return $0.likelyTask && !$1.likelyTask }
            return false
        }.prefix(80).map { $0 }
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        collected: inout [ChecklistCandidate]
    ) {
        guard depth <= 14, visited < 2_000 else { return }
        visited += 1

        let role = stringAttribute(element, kAXRoleAttribute) ?? ""
        let values = [
            stringAttribute(element, kAXValueAttribute),
            stringAttribute(element, kAXTitleAttribute),
            stringAttribute(element, kAXDescriptionAttribute)
        ].compactMap { $0 }

        for value in values {
            for rawLine in value.components(separatedBy: .newlines) {
                let line = cleaned(rawLine)
                guard line.count >= 3, line.count <= 220 else { continue }
                let likely = role == (kAXCheckBoxRole as String) || looksLikeTask(line)
                collected.append(ChecklistCandidate(text: stripTaskPrefix(line), likelyTask: likely))
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, visited: &visited, collected: &collected)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    private static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    private static func looksLikeTask(_ text: String) -> Bool {
        let lower = text.lowercased()
        let prefixes = ["[ ]", "[x]", "- [ ]", "- [x]", "☐", "☑", "○", "◉", "todo:", "task:"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        guard let first = lower.first, first.isNumber, let dot = lower.firstIndex(of: ".") else { return false }
        return lower.distance(from: lower.startIndex, to: dot) <= 3
    }

    private static func stripTaskPrefix(_ text: String) -> String {
        var result = text
        let prefixes = ["- [ ]", "- [x]", "[ ]", "[x]", "☐", "☑", "○", "◉", "•"]
        for prefix in prefixes where result.lowercased().hasPrefix(prefix.lowercased()) {
            result.removeFirst(prefix.count)
            break
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class AnnotationPanel: NSPanel {
    let annotationID: UUID
    private let toggleButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    var onToggle: (() -> Void)?
    var onDelete: (() -> Void)?

    init(annotation: Annotation) {
        annotationID = annotation.id
        let origin = NSPoint(x: annotation.screenX, y: annotation.screenY)
        let isNote = annotation.resolvedKind == .note
        let panelSize = NSSize(width: isNote ? 330 : 310, height: isNote ? 170 : 94)
        super.init(contentRect: NSRect(origin: origin, size: panelSize),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true

        let blur = NSVisualEffectView(frame: contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 13
        blur.layer?.masksToBounds = true
        contentView?.addSubview(blur)

        if !isNote {
            toggleButton.target = self
            toggleButton.action = #selector(toggle)
            toggleButton.state = annotation.completed ? .on : .off
            toggleButton.frame = NSRect(x: 14, y: 36, width: 24, height: 30)
            blur.addSubview(toggleButton)
        }

        label.stringValue = annotation.text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = isNote ? .byWordWrapping : .byTruncatingTail
        label.maximumNumberOfLines = isNote ? 6 : 1
        label.frame = isNote
            ? NSRect(x: 18, y: 42, width: 294, height: 104)
            : NSRect(x: 42, y: 42, width: 250, height: 22)
        blur.addSubview(label)

        contextLabel.stringValue = annotation.context.displayName
        contextLabel.font = .systemFont(ofSize: 10, weight: .regular)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.frame = isNote
            ? NSRect(x: 18, y: 18, width: 280, height: 16)
            : NSRect(x: 42, y: 20, width: 250, height: 16)
        blur.addSubview(contextLabel)

        let close = NSButton(title: "×", target: self, action: #selector(deleteAnnotation))
        close.isBordered = false
        close.font = .systemFont(ofSize: 16)
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: panelSize.width - 27, y: panelSize.height - 28, width: 20, height: 20)
        blur.addSubview(close)
    }

    @objc private func toggle() { onToggle?() }
    @objc private func deleteAnnotation() { onDelete?() }
}

@MainActor
final class CapturePanel: NSPanel, NSTextFieldDelegate {
    private let textField = NSTextField()
    private let context: SurfaceContext
    var onSave: ((String, SurfaceContext, NSPoint) -> Void)?

    init(context: SurfaceContext, point: NSPoint) {
        self.context = context
        super.init(contentRect: NSRect(origin: point, size: NSSize(width: 360, height: 132)),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        title = "New resume marker"
        titleVisibility = .hidden
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .windowBackgroundColor

        let heading = NSTextField(labelWithString: "What should you remember here?")
        heading.font = .systemFont(ofSize: 14, weight: .semibold)
        heading.frame = NSRect(x: 18, y: 91, width: 320, height: 20)
        contentView?.addSubview(heading)

        let surface = NSTextField(labelWithString: context.displayName)
        surface.font = .systemFont(ofSize: 10)
        surface.textColor = .secondaryLabelColor
        surface.lineBreakMode = .byTruncatingMiddle
        surface.frame = NSRect(x: 18, y: 70, width: 320, height: 16)
        contentView?.addSubview(surface)

        textField.placeholderString = "e.g. Continue with step 3: verify onboarding"
        textField.frame = NSRect(x: 18, y: 30, width: 324, height: 28)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(save)
        contentView?.addSubview(textField)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(textField)
    }

    @objc private func save() {
        let value = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { NSSound.beep(); return }
        onSave?(value, context, frame.origin)
        close()
    }
}

@MainActor
final class StickyCapturePanel: NSPanel {
    private let textView = NSTextView()
    private let context: SurfaceContext
    var onSave: ((String, SurfaceContext, NSPoint) -> Void)?

    init(
        context: SurfaceContext,
        point: NSPoint,
        windowTitle: String = "New sticky note",
        headingText: String = "Leave a note on this surface",
        placeholder: String = "",
        actionTitle: String = "Place sticky note"
    ) {
        self.context = context
        super.init(
            contentRect: NSRect(origin: point, size: NSSize(width: 420, height: 290)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        title = windowTitle
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 340, height: 230)

        let heading = NSTextField(labelWithString: headingText)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let surface = NSTextField(labelWithString: context.displayName)
        surface.font = .systemFont(ofSize: 11)
        surface.textColor = .secondaryLabelColor
        surface.lineBreakMode = .byTruncatingMiddle
        surface.translatesAutoresizingMaskIntoConstraints = false

        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: placeholder)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.isHidden = placeholder.isEmpty
        hint.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: actionTitle, target: self, action: #selector(saveNote))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        save.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView else { return }
        [heading, surface, hint, scroll, save].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            heading.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            surface.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            surface.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            hint.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: save.topAnchor, constant: -12),
            save.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            save.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        makeFirstResponder(textView)
    }

    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func saveNote() {
        let value = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { NSSound.beep(); return }
        onSave?(value, context, frame.origin)
        close()
    }
}

@MainActor
final class ChecklistImportPanel: NSPanel {
    private var candidateButtons: [NSButton] = []
    private var likelyButtons: [NSButton] = []
    var onImport: (([String]) -> Void)?

    init(context: SurfaceContext, candidates: [ChecklistCandidate], point: NSPoint) {
        super.init(
            contentRect: NSRect(origin: point, size: NSSize(width: 520, height: 500)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        title = "Adopt visible checklist"
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 420, height: 320)

        let heading = NSTextField(labelWithString: "Choose items to turn into resume markers")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let surface = NSTextField(labelWithString: context.displayName)
        surface.font = .systemFont(ofSize: 11)
        surface.textColor = .secondaryLabelColor
        surface.lineBreakMode = .byTruncatingMiddle
        surface.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Likely tasks are selected automatically. Screenotate reads the visible accessibility tree locally.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        for candidate in candidates {
            let button = NSButton(checkboxWithTitle: candidate.text, target: nil, action: nil)
            button.state = candidate.likelyTask ? .on : .off
            button.font = .systemFont(ofSize: 12)
            button.lineBreakMode = .byTruncatingTail
            button.toolTip = candidate.text
            button.widthAnchor.constraint(lessThanOrEqualToConstant: 455).isActive = true
            candidateButtons.append(button)
            if candidate.likelyTask { likelyButtons.append(button) }
            stack.addArrangedSubview(button)
        }

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(greaterThanOrEqualToConstant: 470)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let selectTasks = NSButton(title: "Select likely tasks", target: self, action: #selector(selectLikely))
        selectTasks.bezelStyle = .inline
        selectTasks.translatesAutoresizingMaskIntoConstraints = false

        let importButton = NSButton(title: "Create markers", target: self, action: #selector(importSelected))
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView else { return }
        [heading, surface, hint, scroll, selectTasks, importButton].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            surface.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            surface.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            surface.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            hint.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 6),
            hint.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: importButton.topAnchor, constant: -14),
            selectTasks.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            selectTasks.centerYAnchor.constraint(equalTo: importButton.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            importButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
    }

    @objc private func selectLikely() {
        for button in candidateButtons { button.state = likelyButtons.contains(button) ? .on : .off }
    }

    @objc private func importSelected() {
        let texts = candidateButtons.filter { $0.state == .on }.map(\.title)
        guard !texts.isEmpty else { NSSound.beep(); return }
        onImport?(texts)
        close()
    }
}

@MainActor
final class DrawingDisplayView: NSView {
    private let drawing: ScreenDrawing

    init(frame: NSRect, drawing: ScreenDrawing) {
        self.drawing = drawing
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.systemYellow.withAlphaComponent(0.78).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 12, yRadius: 12)
        path.lineWidth = drawing.lineWidth
        path.stroke()
    }
}

@MainActor
final class DrawingDisplayPanel: NSPanel {
    let drawingID: UUID

    init(drawing: ScreenDrawing) {
        drawingID = drawing.id
        let minX = min(drawing.start.x, drawing.end.x) - 12
        let minY = min(drawing.start.y, drawing.end.y) - 12
        let width = abs(drawing.end.x - drawing.start.x) + 24
        let height = abs(drawing.end.y - drawing.start.y) + 24
        let rect = NSRect(x: minX, y: minY, width: max(width, 30), height: max(height, 30))
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        contentView = DrawingDisplayView(frame: NSRect(origin: .zero, size: rect.size), drawing: drawing)
    }
}

@MainActor
final class DrawingCaptureView: NSView {
    var onFinish: ((NSPoint, NSPoint) -> Void)?
    private var startPoint: NSPoint?
    private var endPoint: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        endPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        endPoint = convert(event.locationInWindow, from: nil)
        guard let startPoint, let endPoint,
              abs(endPoint.x - startPoint.x) > 8,
              abs(endPoint.y - startPoint.y) > 8 else {
            NSSound.beep()
            return
        }
        onFinish?(startPoint, endPoint)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.08).setFill()
        dirtyRect.fill()

        let instruction = "Drag around anything to highlight it · Escape to cancel"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.72)
        ]
        let size = instruction.size(withAttributes: attributes)
        instruction.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 28),
            withAttributes: attributes
        )

        guard let startPoint, let endPoint else { return }
        NSColor.systemYellow.withAlphaComponent(0.88).setStroke()
        let rect = NSRect(
            x: min(startPoint.x, endPoint.x), y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x), height: abs(endPoint.y - startPoint.y)
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        path.lineWidth = 7
        path.stroke()
    }
}

@MainActor
final class DrawingCapturePanel: NSPanel {
    var onFinish: ((NSPoint, NSPoint) -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let drawingView = DrawingCaptureView(frame: NSRect(origin: .zero, size: screen.frame.size))
        drawingView.autoresizingMask = [.width, .height]
        drawingView.onFinish = { [weak self] start, end in self?.onFinish?(start, end) }
        contentView = drawingView
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var panels: [UUID: AnnotationPanel] = [:]
    private var drawingPanels: [UUID: DrawingDisplayPanel] = [:]
    private var capturePanel: CapturePanel?
    private var stickyCapturePanel: StickyCapturePanel?
    private var importPanel: ChecklistImportPanel?
    private var drawingCapturePanel: DrawingCapturePanel?
    private var lastExternalContext = SurfaceContext(bundleIdentifier: "", appName: "Desktop", windowTitle: "")
    private var lastExternalPID: pid_t = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupHotKey()
        refreshContextAndPanels()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshContextAndPanels() }
        }
        if CommandLine.arguments.contains("--demo-import") {
            let demo = [
                ChecklistCandidate(text: "Inspect the current Cursor plan", likelyTask: true),
                ChecklistCandidate(text: "Implement the selected step", likelyTask: true),
                ChecklistCandidate(text: "Verify the result before continuing", likelyTask: true),
                ChecklistCandidate(text: "Unrelated visible interface label", likelyTask: false)
            ]
            presentChecklistImport(context: lastExternalContext, candidates: demo)
        }
        if CommandLine.arguments.contains("--demo-drawing"), let screen = NSScreen.main {
            let context = currentExternalContext()
            let frame = screen.visibleFrame
            AnnotationStore.shared.addDrawing(
                start: NSPoint(x: frame.midX - 150, y: frame.midY - 70),
                end: NSPoint(x: frame.midX + 150, y: frame.midY + 70),
                context: context
            )
            refreshContextAndPanels()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.scheme == "screenotate" && $0.host == "new" }) {
            beginCapture()
        }
        if urls.contains(where: { $0.scheme == "screenotate" && $0.host == "import" }) {
            beginChecklistImport()
        }
        if urls.contains(where: { $0.scheme == "screenotate" && $0.host == "note" }) {
            beginStickyNote()
        }
        if urls.contains(where: { $0.scheme == "screenotate" && $0.host == "checklist" }) {
            beginManualChecklist()
        }
        if urls.contains(where: { $0.scheme == "screenotate" && $0.host == "draw" }) {
            beginDrawing()
        }
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "checkmark.bubble", accessibilityDescription: "Screenotate")
        let menu = NSMenu()
        let sticky = menu.addItem(withTitle: "New sticky note…", action: #selector(beginStickyNote), keyEquivalent: "")
        sticky.target = self
        let checklist = menu.addItem(withTitle: "New checklist…", action: #selector(beginManualChecklist), keyEquivalent: "")
        checklist.target = self
        let add = menu.addItem(withTitle: "Add resume marker…", action: #selector(beginCapture), keyEquivalent: "")
        add.target = self
        let adopt = menu.addItem(withTitle: "Adopt visible checklist…", action: #selector(beginChecklistImport), keyEquivalent: "")
        adopt.target = self
        menu.addItem(.separator())
        let draw = menu.addItem(withTitle: "Draw highlight around something…", action: #selector(beginDrawing), keyEquivalent: "")
        draw.target = self
        let clear = menu.addItem(withTitle: "Clear drawings on this surface…", action: #selector(clearCurrentDrawings), keyEquivalent: "")
        clear.target = self
        menu.addItem(.separator())
        let location = NSMenuItem(title: "Open data folder", action: #selector(openDataFolder), keyEquivalent: "")
        location.target = self
        menu.addItem(location)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Screenotate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func setupHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x53434E4F), id: 1) // SCNO
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(controlKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("Screenotate could not register Control-Option-A (OSStatus %d)", status)
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.beginCapture() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
    }

    private func currentExternalApplication() -> NSRunningApplication? {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalPID = app.processIdentifier
            return app
        }
        guard lastExternalPID != 0 else { return nil }
        return NSRunningApplication(processIdentifier: lastExternalPID)
    }

    private func currentExternalContext() -> SurfaceContext {
        guard let app = currentExternalApplication() else { return lastExternalContext }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let title = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier &&
            ($0[kCGWindowLayer as String] as? Int) == 0
        })?[kCGWindowName as String] as? String ?? ""
        return SurfaceContext(bundleIdentifier: app.bundleIdentifier ?? app.localizedName ?? "unknown",
                              appName: app.localizedName ?? "Unknown App", windowTitle: title)
    }

    private func refreshContextAndPanels() {
        let context = currentExternalContext()
        if !context.bundleIdentifier.isEmpty { lastExternalContext = context }
        let store = AnnotationStore.shared
        let visibleIDs = Set(store.annotations.filter { !$0.completed && $0.context.matches(context) }.map(\.id))

        for annotation in store.annotations where visibleIDs.contains(annotation.id) {
            if panels[annotation.id] == nil {
                let panel = AnnotationPanel(annotation: annotation)
                panel.onToggle = { [weak self] in
                    AnnotationStore.shared.toggle(id: annotation.id)
                    self?.refreshContextAndPanels()
                }
                panel.onDelete = { [weak self] in
                    AnnotationStore.shared.remove(id: annotation.id)
                    self?.panels.removeValue(forKey: annotation.id)?.close()
                }
                panels[annotation.id] = panel
            }
            panels[annotation.id]?.orderFrontRegardless()
        }
        for (id, panel) in panels where !visibleIDs.contains(id) { panel.orderOut(nil) }

        let visibleDrawingIDs = Set(store.drawings.filter { $0.context.matches(context) }.map(\.id))
        for drawing in store.drawings where visibleDrawingIDs.contains(drawing.id) {
            if drawingPanels[drawing.id] == nil {
                drawingPanels[drawing.id] = DrawingDisplayPanel(drawing: drawing)
            }
            drawingPanels[drawing.id]?.orderFrontRegardless()
        }
        for (id, panel) in drawingPanels where !visibleDrawingIDs.contains(id) { panel.orderOut(nil) }
    }

    @objc func beginCapture() {
        let context = currentExternalContext()
        let mouse = NSEvent.mouseLocation
        let point = NSPoint(x: mouse.x - 180, y: mouse.y - 66)
        let panel = CapturePanel(context: context, point: point)
        panel.onSave = { [weak self] text, context, point in
            AnnotationStore.shared.add(text: text, context: context, point: point)
            self?.capturePanel = nil
            self?.refreshContextAndPanels()
        }
        capturePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func beginStickyNote() {
        let context = currentExternalContext()
        let mouse = NSEvent.mouseLocation
        let point = NSPoint(x: mouse.x - 210, y: mouse.y - 145)
        let panel = StickyCapturePanel(context: context, point: point)
        panel.onSave = { [weak self] text, context, point in
            AnnotationStore.shared.add(text: text, context: context, point: point, kind: .note)
            self?.stickyCapturePanel = nil
            self?.refreshContextAndPanels()
        }
        stickyCapturePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func beginManualChecklist() {
        let context = currentExternalContext()
        let mouse = NSEvent.mouseLocation
        let point = NSPoint(x: mouse.x - 210, y: mouse.y - 145)
        let panel = StickyCapturePanel(
            context: context,
            point: point,
            windowTitle: "New checklist",
            headingText: "One checklist item per line",
            placeholder: "Draft the change\nRun the test\nReview the result",
            actionTitle: "Place checklist"
        )
        panel.onSave = { [weak self] text, context, _ in
            let prefixes = ["- [ ]", "- [x]", "[ ]", "[x]", "☐", "☑", "•", "-"]
            let items = text.components(separatedBy: .newlines).compactMap { raw -> String? in
                var item = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in prefixes where item.lowercased().hasPrefix(prefix.lowercased()) {
                    item.removeFirst(prefix.count)
                    item = item.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
                return item.isEmpty ? nil : item
            }
            guard !items.isEmpty else { return }
            let markerPoint = NSPoint(x: mouse.x - 155, y: mouse.y - 47)
            AnnotationStore.shared.addBatch(
                texts: items, context: context, point: markerPoint,
                eventType: "annotation.created"
            )
            self?.stickyCapturePanel = nil
            self?.refreshContextAndPanels()
        }
        stickyCapturePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func beginDrawing() {
        let context = currentExternalContext()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let panel = DrawingCapturePanel(screen: screen)
        panel.onFinish = { [weak self, weak panel] localStart, localEnd in
            let origin = screen.frame.origin
            let start = NSPoint(x: localStart.x + origin.x, y: localStart.y + origin.y)
            let end = NSPoint(x: localEnd.x + origin.x, y: localEnd.y + origin.y)
            AnnotationStore.shared.addDrawing(start: start, end: end, context: context)
            panel?.close()
            self?.drawingCapturePanel = nil
            self?.refreshContextAndPanels()
        }
        drawingCapturePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func clearCurrentDrawings() {
        let context = currentExternalContext()
        let count = AnnotationStore.shared.drawings.filter { $0.context.matches(context) }.count
        guard count > 0 else {
            showAlert(title: "No drawings here", message: "This surface has no Screenotate drawings to clear.")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear \(count) drawing\(count == 1 ? "" : "s")?"
        alert.informativeText = "This removes Screenotate highlights attached to \(context.displayName)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear drawings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let ids = AnnotationStore.shared.drawings.filter { $0.context.matches(context) }.map(\.id)
        AnnotationStore.shared.removeDrawings(matching: context)
        for id in ids { drawingPanels.removeValue(forKey: id)?.close() }
    }

    @objc func beginChecklistImport() {
        guard let sourceApp = currentExternalApplication() else {
            showAlert(title: "No source surface found", message: "Switch to the app containing your checklist, then try again.")
            return
        }
        let context = currentExternalContext()

        guard AccessibilityChecklistReader.isTrusted(prompt: true) else {
            showAlert(
                title: "Allow Accessibility to adopt checklists",
                message: "Screenotate needs macOS Accessibility permission to read visible task text from another app. Enable Screenotate in System Settings → Privacy & Security → Accessibility, then choose Adopt visible checklist again. Nothing is uploaded."
            )
            return
        }

        let candidates = AccessibilityChecklistReader.candidates(processIdentifier: sourceApp.processIdentifier)
        guard !candidates.isEmpty else {
            showAlert(
                title: "No visible text found",
                message: "Keep the checklist expanded and visible, then try again. Some apps may need their own accessibility support enabled."
            )
            return
        }

        presentChecklistImport(context: context, candidates: candidates)
    }

    private func presentChecklistImport(context: SurfaceContext, candidates: [ChecklistCandidate]) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1000, height: 700)
        let point = NSPoint(x: screen.midX - 260, y: screen.midY - 250)
        let panel = ChecklistImportPanel(context: context, candidates: candidates, point: point)
        panel.onImport = { [weak self] texts in
            let mouse = NSEvent.mouseLocation
            let markerPoint = NSPoint(x: mouse.x - 155, y: mouse.y - 47)
            AnnotationStore.shared.addBatch(texts: texts, context: context, point: markerPoint)
            self?.importPanel = nil
            self?.refreshContextAndPanels()
        }
        importPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(AnnotationStore.shared.annotationsURL.deletingLastPathComponent())
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
  
