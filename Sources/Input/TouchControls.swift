//
//  TouchControls.swift
//  EarthboundWrapper
//
//  The on-screen controls, built around two opinions:
//
//  1. A direction pad is the wrong control for a thumb. It asks you to find a
//     small target, then hold it. A stick you can plant anywhere does not: you
//     touch the left side of the screen wherever it is comfortable, and the
//     engine works out the direction. The nub follows your finger exactly, so the
//     control never feels like it is fighting you, while the direction it reports
//     is snapped to one of eight sectors. That mismatch is deliberate — free
//     motion under the finger, discrete input to the game — and a haptic tick on
//     every change is what communicates it.
//
//  2. UIKit, not SwiftUI gestures, owns the touches. SwiftUI's gesture system
//     arbitrates between views, which on a gamepad means holding B and pressing A
//     can cancel one another. A single responder view with
//     `isMultipleTouchEnabled = true` gets every touch and routes it here, so
//     chords just work. The drawing still happens in SwiftUI, over the top.
//

import SwiftUI
import UIKit

// MARK: - Layout

/// Where every control sits for one screen size.
///
/// Computed rather than hard-coded so the same controls work on a mini and a Max,
/// and so the ergonomics can be tuned in one place.
///
/// The safe-area insets are usually all zero here, because the overlay is laid out
/// inside the safe area rather than ignoring it — the game picture runs edge to
/// edge underneath, but the controls keep clear of the notch. They are still taken
/// as parameters so that moving the overlay outside the safe area is a one-line
/// change rather than a layout rewrite.
struct ControlLayout {
    struct ButtonSlot {
        let button: JoypadButton
        let center: CGPoint
        let radius: CGFloat
    }

    let size: CGSize
    /// Region that accepts a stick touch. Everything in the left portion of the
    /// screen, because there is no reason to make the player aim.
    let stickZone: CGRect
    /// Where the stick's well is drawn when nobody is touching it, as a hint.
    let stickRestCenter: CGPoint
    let stickWellRadius: CGFloat
    let stickNubRadius: CGFloat
    /// Radius inside which a touch reports no direction at all.
    let stickDeadZone: CGFloat

    let faceButtons: [ButtonSlot]
    let shoulders: [ButtonSlot]

    init(size: CGSize, safeArea: EdgeInsets, scale: CGFloat = 1) {
        self.size = size

        // One number from the player scales the whole control surface. No default fits
        // every hand, and a thumb that cannot cover two adjacent buttons is a worse
        // problem than a picture that is slightly smaller.
        let scale = min(max(scale, 0.8), 1.4)

        // --- Stick -------------------------------------------------------
        let wellRadius = min(max(size.height * 0.19, 54), 84) * scale
        stickWellRadius = wellRadius
        stickNubRadius = wellRadius * 0.44
        // 30% of the well. Large enough that resting a thumb does not walk you
        // into a wall, small enough that a deliberate nudge registers.
        stickDeadZone = wellRadius * 0.30
        stickZone = CGRect(x: 0, y: 0, width: size.width * 0.46, height: size.height)
        stickRestCenter = CGPoint(x: size.width * 0.16, y: size.height * 0.70)

        // --- Face buttons -------------------------------------------------
        // SNES physical layout: X on top, Y on the left, A on the right, B on the
        // bottom. Preserving it matters more than ergonomics here, because muscle
        // memory from the real controller is the whole point.
        // Placed from the two edges rather than by a multiplier on the button size, so
        // that what is being chosen is how far the cluster sits from the corner. A
        // diamond's half-extent is `radius + spread`, and both margins are small: the
        // cluster belongs in the corner, over the part of a 2D RPG's picture that
        // nothing important ever occupies.
        // The margins are measured from the base size rather than the scaled one, so
        // that scaling the buttons up grows the cluster inward instead of pushing it off
        // the screen.
        let baseRadius = min(max(size.height * 0.0745, 27), 40)
        let buttonRadius = baseRadius * scale
        // 1.65 rather than 2. Four circles that merely touched would make the cluster
        // half again as wide, and width is the dimension that covers the game. Not
        // tighter than this either: the circles overlap by about a sixth of a button,
        // which is as much as they can overlap before one press starts landing on its
        // neighbour.
        let spread = buttonRadius * 1.65
        let clusterExtent = buttonRadius + spread
        let trailingMargin = max(baseRadius * 0.5, 14)
        let bottomMargin = max(baseRadius * 0.6, 16)
        let clusterCenter = CGPoint(
            x: size.width - safeArea.trailing - trailingMargin - clusterExtent,
            y: size.height - safeArea.bottom - bottomMargin - clusterExtent)
        faceButtons = [
            ButtonSlot(button: .x, center: CGPoint(x: clusterCenter.x, y: clusterCenter.y - spread),
                       radius: buttonRadius),
            ButtonSlot(button: .y, center: CGPoint(x: clusterCenter.x - spread, y: clusterCenter.y),
                       radius: buttonRadius),
            ButtonSlot(button: .a, center: CGPoint(x: clusterCenter.x + spread, y: clusterCenter.y),
                       radius: buttonRadius),
            ButtonSlot(button: .b, center: CGPoint(x: clusterCenter.x, y: clusterCenter.y + spread),
                       radius: buttonRadius),
        ]

        // --- Shoulders ----------------------------------------------------
        // Stacked vertically in the margin to the right of the picture, directly above
        // the face cluster.
        //
        // That column is the one strip of screen with nothing else in it: an
        // aspect-correct picture is letterboxed on exactly those two sides, and the face
        // cluster occupies the bottom of the right-hand one. Stacked here, L and R cover
        // no game pixels at all, and the thumb reaches them by moving up the column it is
        // already resting in rather than crossing the lettered bubble.
        //
        // L is the lower of the two because it is the one that earns its place -- in
        // EarthBound it is a second A -- and the lower position is the shorter reach. R
        // rings a bicycle bell.
        let shoulderRadius = buttonRadius * 1.3
        // What `drawPill` actually draws, which is taller than `shoulderRadius * 1.15`
        // only by accident of the same formula being used for width.
        let pillHeight = shoulderRadius * 1.15
        let clusterTop = clusterCenter.y - clusterExtent
        let topLimit = safeArea.top + pillHeight * 0.5 + 6

        let lowerY = clusterTop - shoulderRadius * 0.4 - pillHeight * 0.5
        // The gap closes before either pill is allowed off the top of the screen, so a
        // large Control size tightens the stack instead of losing R off the edge.
        let room = max(lowerY - pillHeight - topLimit, 0)
        let gap = min(pillHeight * 0.35, room)
        let upperY = lowerY - pillHeight - gap

        shoulders = [
            ButtonSlot(button: .l,
                       center: CGPoint(x: clusterCenter.x, y: lowerY),
                       radius: shoulderRadius),
            ButtonSlot(button: .r,
                       center: CGPoint(x: clusterCenter.x, y: upperY),
                       radius: shoulderRadius),
        ]
    }

    var allButtonSlots: [ButtonSlot] { faceButtons + shoulders }

    /// Extra radius beyond a button that still counts as a hold, so a slightly
    /// sloppy thumb does not drop the press.
    private static let holdSlop: CGFloat = 12

    func slot(at point: CGPoint) -> ButtonSlot? {
        // Shoulders and system buttons are drawn as pills but hit-tested as
        // circles; on a target this small the difference is not worth the code.
        //
        // The nearest match rather than the first. Neighbours in the face cluster
        // overlap deliberately, so "first wins" would hand a press aimed at one button
        // to whichever happened to appear earlier in the array. Scoring by how far past
        // a button's own edge the touch landed, rather than by distance to its centre,
        // is what keeps the pills and the circles comparable.
        var best: ButtonSlot?
        var bestOvershoot = CGFloat.greatestFiniteMagnitude
        for slot in allButtonSlots {
            let dx = point.x - slot.center.x
            let dy = point.y - slot.center.y
            let overshoot = (dx * dx + dy * dy).squareRoot() - slot.radius
            guard overshoot <= Self.holdSlop, overshoot < bestOvershoot else { continue }
            bestOvershoot = overshoot
            best = slot
        }
        return best
    }
}

// MARK: - Model

@MainActor
@Observable
final class TouchControlsModel {
    var layout: ControlLayout
    /// Where the stick was planted for the current touch. Nil when idle.
    private(set) var stickOrigin: CGPoint?
    /// Where the finger is now, which is where the nub is drawn.
    private(set) var stickCurrent: CGPoint?
    /// Snapped direction, or `.none` inside the dead zone.
    private(set) var stickDirection: StickDirection = .none

    /// How far the nub can visually travel from the well's centre.
    private var stickTravel: CGFloat { layout.stickWellRadius }

    private let gamepad: GamepadState
    private var stickTouch: ObjectIdentifier?
    private var buttonTouches: [ObjectIdentifier: JoypadButton] = [:]

    /// Whether diagonal directions are produced. Off gives a strict four-way
    /// stick, which some players prefer for tile-based movement.
    var allowsDiagonals = true

    /// Scales the whole control surface. Setting it rebuilds the layout, so the slider
    /// in Settings is live rather than a change that waits for a restart.
    var scale: CGFloat = 1 {
        didSet { rebuildLayout() }
    }

    private var lastSize: CGSize = .zero
    private var lastSafeArea = EdgeInsets()

    init(gamepad: GamepadState, size: CGSize, safeArea: EdgeInsets, scale: CGFloat = 1) {
        self.gamepad = gamepad
        lastSize = size
        lastSafeArea = safeArea
        // `layout` before `scale`: assigning to a property with an observer during
        // initialization does not call it today, but ordering it this way means the
        // layout exists either way.
        layout = ControlLayout(size: size, safeArea: safeArea, scale: scale)
        self.scale = scale
    }

    func updateLayout(size: CGSize, safeArea: EdgeInsets) {
        guard size != lastSize || safeArea != lastSafeArea else { return }
        lastSize = size
        lastSafeArea = safeArea
        rebuildLayout()
    }

    private func rebuildLayout() {
        guard lastSize != .zero else { return }
        layout = ControlLayout(size: lastSize, safeArea: lastSafeArea, scale: scale)
    }

    // MARK: - Touch routing

    func began(_ identifier: ObjectIdentifier, at point: CGPoint) {
        // Buttons win over the stick. They are small, deliberately placed, and sit
        // on top of the stick's generous region, so hit-testing them first is what
        // stops a shoulder press from also planting the stick.
        if let slot = layout.slot(at: point) {
            buttonTouches[identifier] = slot.button
            gamepad.press(slot.button)
            return
        }

        if stickTouch == nil, layout.stickZone.contains(point) {
            stickTouch = identifier
            stickOrigin = point
            stickCurrent = point
            stickDirection = .none
        }
    }

    func moved(_ identifier: ObjectIdentifier, to point: CGPoint) {
        if identifier == stickTouch {
            stickCurrent = point
            updateStickDirection()
            return
        }

        // A button that has been dragged well clear should release: on a controller
        // you can slide your thumb off a d-pad and the press stops, and the same
        // expectation applies here.
        if let button = buttonTouches[identifier],
           let slot = layout.allButtonSlots.first(where: { $0.button == button }) {
            let dx = point.x - slot.center.x
            let dy = point.y - slot.center.y
            if (dx * dx + dy * dy).squareRoot() > slot.radius + 28 {
                buttonTouches.removeValue(forKey: identifier)
                gamepad.release(button)
            }
        }
    }

    func ended(_ identifier: ObjectIdentifier) {
        if identifier == stickTouch {
            stickTouch = nil
            stickOrigin = nil
            stickCurrent = nil
            stickDirection = .none
            gamepad.setStickDirection(.none)
            return
        }
        if let button = buttonTouches.removeValue(forKey: identifier) {
            gamepad.release(button)
        }
    }

    /// Everything up. Called when the view disappears or the scene changes.
    func cancelAll() {
        stickTouch = nil
        stickOrigin = nil
        stickCurrent = nil
        stickDirection = .none
        buttonTouches.removeAll()
        gamepad.releaseAll()
    }

    // MARK: - Stick maths

    private func updateStickDirection() {
        guard let origin = stickOrigin, let current = stickCurrent else { return }
        let offset = CGPoint(x: current.x - origin.x, y: current.y - origin.y)
        let direction = DirectionSnapping.direction(for: offset,
                                                   deadZone: layout.stickDeadZone,
                                                   diagonals: allowsDiagonals)
        guard direction != stickDirection else { return }
        stickDirection = direction
        gamepad.setStickDirection(direction)
    }

    /// Clamped position for drawing the nub: it stops at the well's edge, so a
    /// finger that travels past it does not leave the nub behind on the glass.
    var stickNubPosition: CGPoint? {
        guard let origin = stickOrigin, let current = stickCurrent else { return nil }
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > stickTravel else { return current }
        let scale = stickTravel / distance
        return CGPoint(x: origin.x + dx * scale, y: origin.y + dy * scale)
    }
}

// MARK: - Multi-touch capture

/// A transparent view that hands every touch straight to the model.
///
/// This exists because SwiftUI's gestures are arbitrated rather than delivered:
/// with one `DragGesture` per button, two fingers landing at once is a conflict to
/// be resolved, not two simultaneous presses. A UIKit responder view with
/// `isMultipleTouchEnabled` receives all of them, which is simply the correct
/// model for a gamepad.
struct MultiTouchCapture: UIViewRepresentable {
    let onBegan: (ObjectIdentifier, CGPoint) -> Void
    let onMoved: (ObjectIdentifier, CGPoint) -> Void
    let onEnded: (ObjectIdentifier) -> Void

    func makeUIView(context: Context) -> TouchCaptureView {
        let view = TouchCaptureView()
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ view: TouchCaptureView, context: Context) {
        view.onBegan = onBegan
        view.onMoved = onMoved
        view.onEnded = onEnded
    }

    final class TouchCaptureView: UIView {
        var onBegan: ((ObjectIdentifier, CGPoint) -> Void)?
        var onMoved: ((ObjectIdentifier, CGPoint) -> Void)?
        var onEnded: ((ObjectIdentifier) -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Without this a UIView only ever receives the first touch, which would
            // make simultaneous presses impossible.
            isMultipleTouchEnabled = true
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                onBegan?(ObjectIdentifier(touch), touch.location(in: self))
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                onMoved?(ObjectIdentifier(touch), touch.location(in: self))
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                onEnded?(ObjectIdentifier(touch))
            }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Routed to the same handler as `ended`, because a cancelled touch that
            // never releases its button is a stuck button.
            for touch in touches {
                onEnded?(ObjectIdentifier(touch))
            }
        }
    }
}

// MARK: - Rendering

/// The controls as drawn, over the game.
struct TouchControlsOverlay: View {
    let model: TouchControlsModel
    let gamepad: GamepadState
    /// Invoked for the chrome buttons that are not fed to the emulator.
    let onMenu: () -> Void

    var body: some View {
        // Deliberately *inside* the safe area. The game image runs edge to edge
        // behind this, but the controls keep out of the notch and the home
        // indicator, and the stick's generous region means nothing is lost by it.
        GeometryReader { proxy in
            let safeArea = proxy.safeAreaInsets
            ZStack {
                // Bottom of the stack: takes every touch that a control does not
                // claim. Nothing above it needs hit testing except the chrome
                // button, which sits on top and gets its own taps first.
                MultiTouchCapture(
                    onBegan: { identifier, point in
                        model.began(identifier, at: point)
                    },
                    onMoved: { identifier, point in
                        model.moved(identifier, to: point)
                    },
                    onEnded: { identifier in
                        model.ended(identifier)
                    })

                Canvas { context, _ in
                    draw(in: &context)
                }
                .allowsHitTesting(false)

                // Chrome, not a controller input: it pauses the game, so it behaves
                // like a button and not like the stick underneath it.
                Button(action: onMenu) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 12)
                .padding(.top, 8)
            }
            .onAppear {
                model.updateLayout(size: proxy.size, safeArea: safeArea)
            }
            .onChange(of: proxy.size) { _, newSize in
                model.updateLayout(size: newSize, safeArea: safeArea)
            }
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        drawStick(in: &context)
        for slot in model.layout.shoulders { drawPill(slot, in: &context, isHeld: gamepad.isHeld(slot.button)) }
        drawFaceCluster(in: &context)
    }

    /// The four face buttons as one cluster.
    ///
    /// The circles overlap on purpose, and four separately filled translucent shapes
    /// composite where they meet: the lens between two neighbours comes out brighter
    /// than either of them, which is what made the cluster read as a smudge rather than
    /// as four buttons. Filling all four ellipses as a single path fixes it, because one
    /// fill of overlapping subpaths fills each area once.
    ///
    /// The rim uses the same trick — a slightly larger union in the rim colour, with the
    /// interior drawn on top — because stroking each circle individually would draw its
    /// arcs straight across its neighbours.
    private func drawFaceCluster(in context: inout GraphicsContext) {
        let slots = model.layout.faceButtons
        guard !slots.isEmpty else { return }
        let anyHeld = slots.contains { gamepad.isHeld($0.button) }

        var rim = Path()
        var interior = Path()
        for slot in slots {
            rim.addEllipse(in: circleRect(at: slot.center, radius: slot.radius + 1.5))
            interior.addEllipse(in: circleRect(at: slot.center, radius: slot.radius))
        }

        context.fill(rim, with: .color(.white.opacity(anyHeld ? 0.44 : 0.17)))
        context.fill(interior, with: .color(.white.opacity(anyHeld ? 0.30 : 0.10)))

        // The held button is drawn on top, so a press reads clearly even when the
        // cluster is otherwise nearly transparent over a bright scene.
        for slot in slots where gamepad.isHeld(slot.button) {
            let circle = Path(ellipseIn: circleRect(at: slot.center, radius: slot.radius))
            context.fill(circle, with: .color(.white.opacity(0.45)))
            context.stroke(circle, with: .color(.white.opacity(0.95)), lineWidth: 1.5)
        }

        for slot in slots {
            let isHeld = gamepad.isHeld(slot.button)
            context.draw(
                Text(slot.button.label)
                    .font(.system(size: slot.radius * 0.78, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(isHeld ? 1 : 0.62)),
                at: slot.center)
        }
    }

    private func circleRect(at center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius,
               width: radius * 2, height: radius * 2)
    }

    private func drawStick(in context: inout GraphicsContext) {
        let layout = model.layout
        let origin = model.stickOrigin ?? layout.stickRestCenter
        let isActive = model.stickOrigin != nil
        let wellRadius = layout.stickWellRadius

        // The well. Dimmed to a hint when idle so it does not compete with the
        // game, fully drawn once a finger is in it.
        let wellOpacity = isActive ? 0.30 : 0.10
        let wellRect = CGRect(x: origin.x - wellRadius, y: origin.y - wellRadius,
                              width: wellRadius * 2, height: wellRadius * 2)
        context.fill(Path(ellipseIn: wellRect), with: .color(.white.opacity(wellOpacity)))
        context.stroke(Path(ellipseIn: wellRect),
                       with: .color(.white.opacity(isActive ? 0.55 : 0.22)),
                       lineWidth: 1.5)

        // Direction ticks. These are the whole reason the stick feels like it has
        // detents: you can see which way it snapped, and feel it too.
        let tickStart = wellRadius * 0.72
        let tickLength = wellRadius * 0.20
        for (index, direction) in StickDirection.slotsByIndex.enumerated() {
            let vector = direction.unitVector
            let isLit = model.stickDirection == direction || lightsCardinal(index)
            let opacity: Double = isLit ? 0.95 : 0.20
            let width: CGFloat = isLit ? 3.5 : 1.5
            var path = Path()
            path.move(to: CGPoint(x: origin.x + vector.x * tickStart,
                                  y: origin.y + vector.y * tickStart))
            path.addLine(to: CGPoint(x: origin.x + vector.x * (tickStart + tickLength),
                                     y: origin.y + vector.y * (tickStart + tickLength)))
            context.stroke(path, with: .color(.white.opacity(opacity)),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }

        guard let nub = model.stickNubPosition, isActive else { return }

        // A line from well to nub, so the direction reads even with the eye off it.
        var lever = Path()
        lever.move(to: origin)
        lever.addLine(to: nub)
        context.stroke(lever, with: .color(.white.opacity(0.25)), lineWidth: 1)

        let nubRadius = layout.stickNubRadius
        let nubRect = CGRect(x: nub.x - nubRadius, y: nub.y - nubRadius,
                             width: nubRadius * 2, height: nubRadius * 2)
        context.fill(Path(ellipseIn: nubRect), with: .color(.white.opacity(0.55)))
        context.stroke(Path(ellipseIn: nubRect), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }

    /// Whether the tick at `index` should light up as part of the current diagonal.
    ///
    /// A diagonal lights the two cardinals it is made of, so the feedback matches
    /// the two bits the SNES actually receives. Even indices in `slotsByIndex` are
    /// the cardinals, and each diagonal sits between exactly two of them.
    private func lightsCardinal(_ index: Int) -> Bool {
        guard let litIndex = model.stickDirection.slotIndex, litIndex % 2 == 1 else {
            return false
        }
        return abs(litIndex - index) == 1
    }

    private func drawPill(_ slot: ControlLayout.ButtonSlot, in context: inout GraphicsContext,
                          isHeld: Bool) {
        let width = slot.radius * 2
        let height = slot.radius * 1.15
        let rect = CGRect(x: slot.center.x - width / 2, y: slot.center.y - height / 2,
                          width: width, height: height)
        let shape = Path(roundedRect: rect, cornerRadius: height / 2)
        context.fill(shape, with: .color(.white.opacity(isHeld ? 0.55 : 0.13)))
        context.stroke(shape, with: .color(.white.opacity(isHeld ? 0.95 : 0.26)), lineWidth: 1.5)
        context.draw(
            Text(slot.button.label)
                .font(.system(size: height * 0.44, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isHeld ? 1 : 0.68)),
            at: slot.center)
    }
}
