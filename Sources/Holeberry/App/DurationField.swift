import AppKit

/// A duration entry field mimicking the macOS Clock app's Timer tab:
/// clickable h/min/s segments with unit captions, keyboard-adjustable.
/// Designed for use as an NSAlert.accessoryView.
final class DurationField: NSView {
  // MARK: - Public API

  /// The currently selected duration in seconds.
  var duration: TimeInterval {
    get { TimeInterval(values[0] * 3600 + values[1] * 60 + values[2]) }
    set {
      let total = max(0, Int(newValue))
      values = [total / 3600, (total / 60) % 60, total % 60]
    }
  }

  /// Called whenever the user changes any segment.
  var onChange: ((TimeInterval) -> Void)?

  /// Called when the user presses Return to confirm. When set, it replaces
  /// the default "stop modal as confirmed" behavior so the host can
  /// validate the duration first (e.g. reject duplicates with a wiggle).
  var onConfirm: (() -> Void)?

  // MARK: - Constants

  private static let digitFontSize: CGFloat = 32
  static let unit: [(label: String, range: ClosedRange<Int>)] = [
    ("h", 0...23),
    ("min", 0...59),
    ("s", 0...59)
  ]

  // MARK: - Private state

  private var values: [Int] = [0, 15, 0] {
    didSet {
      for i in segments.indices { segments[i].value = values[i] }
      onChange?(duration)
    }
  }

  private var activeIndex = 1 {
    didSet {
      for i in segments.indices {
        segments[i].isActive = (i == activeIndex)
      }
    }
  }

  private var segments: [SegmentView] = []
  private var typedDigits = ""
  private var lastKeyTime = Date.distantPast

  // MARK: - Init

  init(initialDuration: TimeInterval = 5 * 60) {
    super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
    buildUI()
    duration = initialDuration
    activeIndex = 1  // start on minutes
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    guard super.becomeFirstResponder() else { return false }
    // Re-activate the default segment so the highlight is drawn reliably
    // when the field gains first responder status.
    activeIndex = 1
    return true
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // The accessory view is added to the alert's window hierarchy just
    // before runModal.  This is the earliest safe moment to become first
    // responder — calling makeFirstResponder earlier (in init or in
    // runDurationPicker) would fail because the view has no window yet.
    if window != nil {
      window?.makeFirstResponder(self)
    }
  }

  // MARK: - UI Building

  private func buildUI() {
    let digitFont = NSFont.monospacedDigitSystemFont(ofSize: Self.digitFontSize, weight: .regular)
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 0
    row.alignment = .lastBaseline

    for i in Self.unit.indices {
      let column = makeColumn(for: i, font: digitFont)
      row.addArrangedSubview(column)

      if i < Self.unit.count - 1 {
        let colon = NSTextField(labelWithString: ":")
        colon.font = digitFont
        colon.textColor = .labelColor
        colon.alignment = .center
        colon.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(colon)
      }
    }

    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
      row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
    ])
  }

  private func makeColumn(for index: Int, font: NSFont) -> NSStackView {
    let segment = SegmentView(
      index: index,
      value: values[index],
      font: font
    ) { [weak self] in
      guard let self else { return }
      window?.makeFirstResponder(self)
      activeIndex = index
    }
    segments.append(segment)

    let caption = NSTextField(labelWithString: Self.unit[index].label)
    caption.font = .systemFont(ofSize: 11, weight: .medium)
    caption.textColor = .secondaryLabelColor
    caption.alignment = .center

    let col = NSStackView(views: [caption, segment])
    col.orientation = .vertical
    col.spacing = 2
    col.alignment = .centerX
    return col
  }

  // MARK: - Keyboard

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36:  // Return — confirm
      if let onConfirm {
        onConfirm()
      } else {
        NSApp.stopModal(withCode: .alertFirstButtonReturn)
      }
    case 53:  // Escape — cancel
      NSApp.stopModal(withCode: .alertSecondButtonReturn)
    case 123: moveActive(by: -1)  // ←
    case 124: moveActive(by: 1)  // →
    case 125: adjust(by: -1)  // ↓
    case 126: adjust(by: 1)  // ↑
    default:
      if let chars = event.charactersIgnoringModifiers,
        let digit = Int(chars),
        (0...9).contains(digit)
      {
        typeDigit(digit)
      } else {
        super.keyDown(with: event)  // Tab → buttons, etc.
      }
    }
  }

  private func moveActive(by delta: Int) {
    let maxIndex = Self.unit.count - 1
    activeIndex = Swift.min(Swift.max(activeIndex + delta, 0), maxIndex)
    typedDigits = ""
  }

  private func adjust(by delta: Int) {
    let range = Self.unit[activeIndex].range
    var newValue = values[activeIndex] + delta
    if newValue > range.upperBound { newValue = range.lowerBound }
    if newValue < range.lowerBound { newValue = range.upperBound }
    values[activeIndex] = newValue
  }

  private func typeDigit(_ digit: Int) {
    let now = Date()
    if now.timeIntervalSince(lastKeyTime) > 1.2 { typedDigits = "" }
    lastKeyTime = now

    typedDigits.append(String(digit))
    if typedDigits.count > 2 { typedDigits = String(typedDigits.suffix(2)) }

    let range = Self.unit[activeIndex].range
    let typedValue = Int(typedDigits) ?? digit
    values[activeIndex] = min(typedValue, range.upperBound)

    if typedDigits.count == 2 || typedValue * 10 > range.upperBound {
      typedDigits = ""
      moveActive(by: 1)
    }
  }

  // MARK: - Accessibility

  override func accessibilityChildren() -> [Any]? { segments }
  override func accessibilityRole() -> NSAccessibility.Role? { .group }
  override func accessibilityLabel() -> String? { "Duration" }
  override func accessibilityValue() -> Any? {
    let hours = values[0]
    let minutes = values[1]
    let seconds = values[2]
    var parts: [String] = []
    if hours > 0 { parts.append("\(hours) hours") }
    if minutes > 0 { parts.append("\(minutes) minutes") }
    if seconds > 0 || parts.isEmpty { parts.append("\(seconds) seconds") }
    return parts.joined(separator: " ")
  }
}

// MARK: - Segment View

/// A single clickable, highlightable digit segment (e.g. the "15" in 00:15:00).
private final class SegmentView: NSView {
  let index: Int

  var value: Int {
    didSet {
      textField.stringValue = String(format: "%02d", value)
      setAccessibilityValue(String(value))
    }
  }

  var isActive = false {
    didSet { needsDisplay = true }
  }

  private let textField = NSTextField(labelWithString: "00")
  private let onSelect: () -> Void

  init(index: Int, value: Int, font: NSFont, onSelect: @escaping () -> Void) {
    self.index = index
    self.value = value
    self.onSelect = onSelect
    super.init(frame: .zero)

    textField.font = font
    textField.textColor = .labelColor
    textField.alignment = .center
    textField.stringValue = String(format: "%02d", value)
    textField.isEnabled = false  // prevent text editing; we own input

    addSubview(textField)
    textField.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      textField.topAnchor.constraint(equalTo: topAnchor),
      textField.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])

    // Accessibility
    setAccessibilityElement(true)
    setAccessibilityRole(.staticText)
    setAccessibilityLabel(DurationField.unit[index].label)
    setAccessibilityValue(String(value))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var firstBaselineOffsetFromTop: CGFloat {
    textField.firstBaselineOffsetFromTop
  }

  override func draw(_ dirtyRect: NSRect) {
    guard isActive else { return }
    let highlightPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
    NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
    highlightPath.fill()
  }

  override func mouseDown(with event: NSEvent) {
    onSelect()
  }
}
