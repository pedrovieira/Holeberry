import AppKit

/// Custom menu bar status item view that draws a capsule with a countdown progress ring,
/// a shield icon, and monospaced time text.
final class StatusItemButton: NSView {
  // MARK: - Constants

  private enum Layout {
    static let iconSize: CGFloat = 16
    static let horizontalPadding: CGFloat = 8
    static let iconTextGap: CGFloat = 8
    static let height: CGFloat = 22
    static let borderWidth: CGFloat = 1.5
    static let fontPointSize: CGFloat = 12
  }

  // MARK: - State

  private var remainingSeconds: TimeInterval = 0
  private var totalDuration: TimeInterval?
  private var formattedTime: String = ""
  private var isUrgent: Bool { progressFraction <= 0.15 && !isIndefinite }
  private var isIndefinite: Bool { totalDuration == nil || (totalDuration ?? 0) <= 0 }
  private var progressFraction: CGFloat {
    guard let total = totalDuration, total > 0 else { return 0 }
    return CGFloat(max(0, min(1, remainingSeconds / total)))
  }

  // MARK: - Layers

  private let inactiveBorderLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillColor = NSColor.clear.cgColor
    layer.strokeColor = NSColor.separatorColor.cgColor
    layer.lineWidth = Layout.borderWidth
    layer.lineCap = .round
    return layer
  }()

  private let progressArcLayer: CAShapeLayer = {
    let layer = CAShapeLayer()
    layer.fillColor = NSColor.clear.cgColor
    layer.lineWidth = Layout.borderWidth
    layer.lineCap = .round
    layer.strokeStart = 0
    layer.strokeEnd = 0
    return layer
  }()

  // MARK: - Font

  private let timeFont: NSFont = {
    .monospacedDigitSystemFont(ofSize: Layout.fontPointSize, weight: .regular)
  }()

  // MARK: - Computed layout

  private var iconRect: NSRect {
    let y = (bounds.height - Layout.iconSize) / 2
    return NSRect(x: Layout.horizontalPadding, y: y, width: Layout.iconSize, height: Layout.iconSize)
  }

  private var currentTextWidth: CGFloat {
    let text = formattedTime as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: timeFont]
    return text.size(withAttributes: attrs).width
  }

  private var textRect: NSRect {
    let text = formattedTime as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: timeFont]
    let size = text.size(withAttributes: attrs)
    let x = Layout.horizontalPadding + Layout.iconSize + Layout.iconTextGap
    let y = (bounds.height - size.height) / 2
    return NSRect(x: x, y: y, width: ceil(size.width), height: size.height)
  }

  // MARK: - Click callback

  /// Called when the user clicks the status item. The owning controller
  /// sets this to handle menu presentation.
  var onClick: (() -> Void)?

  /// The preferred pill width for the current text. The owning controller
  /// reads this to resize the status item smoothly.
  var preferredWidth: CGFloat {
    let textW = ceil(currentTextWidth)
    return Layout.horizontalPadding + Layout.iconSize + Layout.iconTextGap + textW + Layout.horizontalPadding
  }

  // MARK: - Init

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    guard let layer else { return }
    layer.addSublayer(inactiveBorderLayer)
    layer.addSublayer(progressArcLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    inactiveBorderLayer.strokeColor = NSColor.separatorColor.cgColor
    needsDisplay = true
  }

  // MARK: - Mouse

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  // MARK: - Sizing

  override var intrinsicContentSize: NSSize {
    NSSize(width: preferredWidth, height: Layout.height)
  }

  // MARK: - Layout

  override func layout() {
    super.layout()
    updateBorderPaths()
  }

  private func updateBorderPaths() {
    let inset = Layout.borderWidth / 2
    let rect = bounds.insetBy(dx: inset, dy: inset)
    let path = capsulePath(in: rect)
    inactiveBorderLayer.path = path
    progressArcLayer.path = path
  }

  // MARK: - Capsule Path

  /// Creates a capsule (fully rounded rect) CGPath starting at the top-center
  /// and proceeding clockwise. This allows `strokeEnd` to reveal the arc
  /// clockwise from 12 o'clock.
  private func capsulePath(in rect: NSRect) -> CGPath {
    let radius = rect.height * 0.4
    let path = CGMutablePath()

    let minX = rect.minX
    let midX = rect.midX
    let maxX = rect.maxX
    let minY = rect.minY
    let maxY = rect.maxY

    // Start at top center (maxY = top in AppKit coordinates)
    path.move(to: CGPoint(x: midX, y: maxY))

    // Right along top edge → top-right arc center
    path.addLine(to: CGPoint(x: maxX - radius, y: maxY))

    // Top-right quarter circle (clockwise: upward → rightward)
    path.addArc(
      center: CGPoint(x: maxX - radius, y: maxY - radius),
      radius: radius,
      startAngle: .pi / 2,
      endAngle: 0,
      clockwise: true
    )

    // Bottom-right quarter circle (clockwise: rightward → downward)
    path.addArc(
      center: CGPoint(x: maxX - radius, y: minY + radius),
      radius: radius,
      startAngle: 0,
      endAngle: -.pi / 2,
      clockwise: true
    )

    // Left along bottom edge
    path.addLine(to: CGPoint(x: minX + radius, y: minY))

    // Bottom-left quarter circle (clockwise: downward → leftward)
    path.addArc(
      center: CGPoint(x: minX + radius, y: minY + radius),
      radius: radius,
      startAngle: -.pi / 2,
      endAngle: -.pi,
      clockwise: true
    )

    // Top-left quarter circle (clockwise: leftward → upward)
    path.addArc(
      center: CGPoint(x: minX + radius, y: maxY - radius),
      radius: radius,
      startAngle: .pi,
      endAngle: .pi / 2,
      clockwise: true
    )

    // Left half of top edge → back to top center
    path.addLine(to: CGPoint(x: midX, y: maxY))
    path.closeSubpath()

    return path
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawIcon()
    drawTimeText()
  }

  private func drawIcon() {
    guard let image = NSImage(systemSymbolName: "shield.slash.fill", accessibilityDescription: nil) else { return }

    let config = NSImage.SymbolConfiguration(hierarchicalColor: .labelColor)
    guard let tintedImage = image.withSymbolConfiguration(config) else { return }
    tintedImage.draw(in: iconRect)
  }

  private func drawTimeText() {
    let textColor: NSColor = isUrgent ? .systemRed : .labelColor
    let attrs: [NSAttributedString.Key: Any] = [
      .font: timeFont,
      .foregroundColor: textColor
    ]
    (formattedTime as NSString).draw(in: textRect, withAttributes: attrs)
  }

  // MARK: - Public API

  /// Updates the view state. Call this whenever remainingSeconds or totalDuration changes.
  func update(remainingSeconds: TimeInterval, totalDuration: TimeInterval?, formattedTime: String) {
    self.remainingSeconds = remainingSeconds
    self.totalDuration = totalDuration
    self.formattedTime = formattedTime

    // Update the progress arc layer
    if isIndefinite {
      progressArcLayer.strokeEnd = 0
    } else {
      progressArcLayer.strokeEnd = progressFraction
    }
    progressArcLayer.strokeColor = isUrgent ? NSColor.systemRed.cgColor : NSColor.labelColor.cgColor

    // Redraw text/icon (color may have changed)
    needsDisplay = true
  }
}
