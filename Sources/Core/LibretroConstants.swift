//
//  LibretroConstants.swift
//  EarthboundWrapper
//
//  The handful of libretro constants the frontend needs, restated in Swift so
//  that no libretro header ever reaches the Clang importer.
//
//  These are not free-floating magic numbers: EBCoreGlue.c static-asserts every
//  value below against the pinned core revision. If libretro renumbers a command
//  or a joypad id, the C file stops compiling rather than the app misbehaving at
//  runtime. Update both in the same commit.
//

import Foundation

enum Libretro {
    /// `RETRO_API_VERSION` — guards against loading a core that speaks a
    /// different frontend ABI than the one glued in here.
    static let apiVersion: UInt32 = 1

    /// `RETRO_ENVIRONMENT_EXPERIMENTAL` — high bit that some commands set.
    static let environmentExperimental: UInt32 = 0x10000

    /// Commands the core asks the frontend to perform.
    enum Command {
        static let getOverscan: UInt32 = 2
        static let getCanDupe: UInt32 = 3
        static let setMessage: UInt32 = 6
        static let shutdown: UInt32 = 7
        static let setPerformanceLevel: UInt32 = 8
        static let getSystemDirectory: UInt32 = 9
        static let setPixelFormat: UInt32 = 10
        static let setInputDescriptors: UInt32 = 11
        static let getVariable: UInt32 = 15
        static let setVariables: UInt32 = 16
        static let getVariableUpdate: UInt32 = 17
        static let setSupportNoGame: UInt32 = 18
        static let getLogInterface: UInt32 = 27
        /// Shares its number with `GET_CORE_ASSETS_DIRECTORY`; both name a
        /// read-only folder we hand the core.
        static let getContentDirectory: UInt32 = 30
        static let getSaveDirectory: UInt32 = 31
        static let setSystemAVInfo: UInt32 = 32
        static let setGeometry: UInt32 = 37
        static let getLanguage: UInt32 = 39
        static let getAudioVideoEnable: UInt32 = 47 | environmentExperimental
        static let getFastForwarding: UInt32 = 49 | environmentExperimental
        static let getTargetRefreshRate: UInt32 = 50 | environmentExperimental
        static let getInputBitmasks: UInt32 = 51 | environmentExperimental
        static let getCoreOptionsVersion: UInt32 = 52
        static let setCoreOptions: UInt32 = 53
        static let setCoreOptionsIntl: UInt32 = 54
        static let setCoreOptionsV2: UInt32 = 67
        static let setCoreOptionsV2Intl: UInt32 = 68
        /// Which revision of the message API the core should use when it wants to
        /// put text on screen. 1 means "the extended struct", which is all we
        /// advertise; we do not implement message display itself.
        static let getMessageInterfaceVersion: UInt32 = 59
    }

    /// `RETRO_DEVICE_*` — input device classes.
    enum Device {
        static let none: UInt32 = 0
        static let joypad: UInt32 = 1
        /// `RETRO_DEVICE_ID_JOYPAD_MASK` — pseudo-id asking for all 16 bits at
        /// once. Only meaningful once the frontend advertises bitmask support.
        static let joypadMask: UInt32 = 256
    }

    /// `RETRO_MEMORY_*` — regions reachable through `retro_get_memory_data`.
    enum Memory {
        static let saveRAM: UInt32 = 0
        static let rtc: UInt32 = 1
        static let systemRAM: UInt32 = 2
        static let videoRAM: UInt32 = 3
    }

    /// `RETRO_PIXEL_FORMAT_*` — how the core hands us framebuffers.
    enum PixelFormat: UInt32 {
        case zeroRGB1555 = 0
        case xrgb8888 = 1
        case rgb565 = 2
    }

    static let regionNTSC: Int32 = 0
    static let regionPAL: Int32 = 1
    static let languageEnglish: UInt32 = 0
}

/// A single virtual button, mapped to its libretro joypad bit.
enum JoypadButton: UInt32, CaseIterable, Identifiable, Sendable {
    case b = 0
    case y = 1
    case select = 2
    case start = 3
    case up = 4
    case down = 5
    case left = 6
    case right = 7
    case a = 8
    case x = 9
    case l = 10
    case r = 11

    var id: UInt32 { rawValue }

    /// The 16-bit joypad mask with only this button set.
    var bit: UInt32 { 1 << rawValue }

    var label: String {
        switch self {
        case .b: return "B"
        case .y: return "Y"
        case .select: return "Select"
        case .start: return "Start"
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        case .a: return "A"
        case .x: return "X"
        case .l: return "L"
        case .r: return "R"
        }
    }
}

extension UInt32 {
    /// Builds a joypad mask from a direction, so the stick can express
    /// diagonals as two simultaneous bits — which is what the SNES actually
    /// does, and what EarthBound expects when you walk into a corner.
    static func joypadMask(from direction: StickDirection) -> UInt32 {
        var mask: UInt32 = 0
        if direction.contains(.up) { mask |= JoypadButton.up.bit }
        if direction.contains(.down) { mask |= JoypadButton.down.bit }
        if direction.contains(.left) { mask |= JoypadButton.left.bit }
        if direction.contains(.right) { mask |= JoypadButton.right.bit }
        return mask
    }
}

/// A snapped 8-way direction, optionally empty.
struct StickDirection: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let up = StickDirection(rawValue: 1 << 0)
    static let down = StickDirection(rawValue: 1 << 1)
    static let left = StickDirection(rawValue: 1 << 2)
    static let right = StickDirection(rawValue: 1 << 3)
    static let none: StickDirection = []

    static let upLeft: StickDirection = [.up, .left]
    static let upRight: StickDirection = [.up, .right]
    static let downLeft: StickDirection = [.down, .left]
    static let downRight: StickDirection = [.down, .right]

    /// Clockwise from up, matching the tick marks drawn on the stick well.
    static let allEight: [StickDirection] = [
        .up, .upRight, .right, .downRight, .down, .downLeft, .left, .upLeft,
    ]

    /// Which radial slot this direction occupies, or nil for the dead zone.
    var slotIndex: Int? { Self.allEight.firstIndex(of: self) }

    /// The eight slots in the order produced by `DirectionSnapping.slotIndex`,
    /// i.e. counter-clockwise on screen starting from due left.
    ///
    /// Screen coordinates put y downward, so these read as: left, up-left, up,
    /// up-right, right, down-right, down, down-left. Deriving them from an index
    /// instead of comparing angles keeps the snap exact at the boundaries, where
    /// floating-point comparisons between two neighbouring 45° sectors would
    /// otherwise flicker.
    static let slotsByIndex: [StickDirection] = [
        .left, .upLeft, .up, .upRight, .right, .downRight, .down, .downLeft,
    ]

    /// Unit vector for drawing, in screen coordinates (y grows downward).
    var unitVector: CGPoint {
        let diagonal = 0.7071067811865476
        var x: CGFloat = 0
        var y: CGFloat = 0
        if contains(.left) { x -= 1 }
        if contains(.right) { x += 1 }
        if contains(.up) { y -= 1 }
        if contains(.down) { y += 1 }
        if x != 0 && y != 0 { x *= diagonal; y *= diagonal }
        return CGPoint(x: x, y: y)
    }
}

/// Turning a finger's position into a snapped direction.
///
/// Split out from the control so the behaviour can be reasoned about on its own —
/// this is the piece that decides whether walking north-east into a corner works,
/// and it is worth being able to test it without a screen.
enum DirectionSnapping {
    /// The eight-way snap. Returns `.none` when the touch is inside the dead zone.
    ///
    /// - Parameters:
    ///   - offset: finger position relative to the stick's origin, in points.
    ///   - deadZone: radius inside which no direction is reported.
    ///   - diagonals: when false, only the four cardinals are ever produced, which
    ///     some players prefer for grid-based movement.
    static func direction(for offset: CGPoint,
                          deadZone: CGFloat,
                          diagonals: Bool = true) -> StickDirection {
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard distance > deadZone else { return .none }
        return direction(forAngle: atan2(offset.y, offset.x), diagonals: diagonals)
    }

    /// - Parameter angle: radians, screen convention (0 is right, positive is
    ///   downward).
    static func direction(forAngle angle: Double, diagonals: Bool = true) -> StickDirection {
        let sector = Double.pi / (diagonals ? 4 : 2)
        // Shift by half a sector so rounding lands on the nearest slot rather than
        // the one below it, then wrap into 0..<count.
        let rawIndex = (angle + Double.pi) / sector
        let count = diagonals ? 8 : 4
        var index = Int(rawIndex.rounded()) % count
        if index < 0 { index += count }
        if diagonals {
            return StickDirection.slotsByIndex[index]
        }
        // The same table's cardinal entries, in the same rotational order.
        return [.left, .up, .right, .down][index]
    }
}
