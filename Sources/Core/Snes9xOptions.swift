//
//  Snes9xOptions.swift
//  EarthboundWrapper
//
//  The snes9x core's option vocabulary, for the pinned revision in
//  ThirdParty/libretro/CORE_REVISION.
//
//  Why the whole table instead of only the interesting options: the core reads
//  options with `if (environ_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var))` and then
//  `strcmp`s `var.value` *without* a null check. Answering "true" while leaving
//  `value` null crashes inside the core, so the frontend must always be able to
//  produce a real string for any key the core asks about. Anything not listed
//  here is answered with "false", which the core handles on every call site.
//
//  Transcribed from libretro/libretro_core_options.h at the pinned revision. If
//  the core is re-pinned, re-extract this table; a missing key is a crash, not a
//  cosmetic bug.
//

import Foundation

/// One core option: its key, the value the core ships with, and every value it
/// will accept.
struct CoreOptionDescriptor: Sendable, Hashable {
    let key: String
    let defaultValue: String
    let values: [String]

    /// Human-readable label derived from the key, so the table above stays a
    /// verbatim copy of the core's list with no prose to keep in sync.
    var label: String {
        let trimmed = key.hasPrefix("snes9x_") ? String(key.dropFirst("snes9x_".count)) : key
        let words = trimmed.split(separator: "_").map { part -> String in
            // Keep digits attached: "mode7" reads better than "mode 7" here.
            part.prefix(1).uppercased() + part.dropFirst()
        }
        return words.joined(separator: " ")
    }
}

enum Snes9xOptions {
    /// Every option the core can ask about, with the core's own default.
    static let all: [CoreOptionDescriptor] = [
        CoreOptionDescriptor(key: "snes9x_region", defaultValue: "auto",
                             values: ["auto", "ntsc", "pal"]),
        CoreOptionDescriptor(key: "snes9x_aspect", defaultValue: "4:3",
                             values: ["4:3", "4:3 scaled", "uncorrected", "auto", "ntsc", "pal"]),
        CoreOptionDescriptor(key: "snes9x_overscan", defaultValue: "enabled",
                             values: ["enabled", "12_pixels", "16_pixels", "auto", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_mode7_hires", defaultValue: "disabled",
                             values: ["disabled", "2x", "4x", "2x_hv", "4x_hv"]),
        CoreOptionDescriptor(key: "snes9x_mode7_hires_bilinear", defaultValue: "disabled",
                             values: ["disabled", "stable", "smooth"]),
        CoreOptionDescriptor(key: "snes9x_hires_blend", defaultValue: "disabled",
                             values: ["disabled", "merge", "blur"]),
        CoreOptionDescriptor(key: "snes9x_blargg", defaultValue: "disabled",
                             values: ["disabled", "monochrome", "rf", "composite", "s-video", "rgb"]),
        CoreOptionDescriptor(key: "snes9x_audio_interpolation", defaultValue: "gaussian",
                             values: ["gaussian", "cubic", "sinc", "none", "linear"]),
        CoreOptionDescriptor(key: "snes9x_up_down_allowed", defaultValue: "disabled",
                             values: ["disabled", "enabled"]),
        CoreOptionDescriptor(key: "snes9x_overclock_superfx", defaultValue: "100%",
                             values: ["50%", "60%", "70%", "80%", "90%", "100%",
                                      "150%", "200%", "250%", "300%", "350%",
                                      "400%", "450%", "500%"]),
        CoreOptionDescriptor(key: "snes9x_superfx_timing", defaultValue: "compat",
                             values: ["compat", "hardware"]),
        CoreOptionDescriptor(key: "snes9x_overclock_cycles", defaultValue: "disabled",
                             values: ["disabled", "light", "compatible", "max"]),
        CoreOptionDescriptor(key: "snes9x_reduce_sprite_flicker", defaultValue: "disabled",
                             values: ["disabled", "enabled"]),
        CoreOptionDescriptor(key: "snes9x_randomize_memory", defaultValue: "disabled",
                             values: ["disabled", "enabled"]),
        CoreOptionDescriptor(key: "snes9x_block_invalid_vram_access", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_echo_buffer_hack", defaultValue: "disabled",
                             values: ["disabled", "enabled"]),
        CoreOptionDescriptor(key: "snes9x_show_lightgun_settings", defaultValue: "disabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_lightgun_mode", defaultValue: "Lightgun",
                             values: ["Lightgun", "Touchscreen"]),
        CoreOptionDescriptor(key: "snes9x_superscope_reverse_buttons", defaultValue: "disabled",
                             values: ["disabled", "enabled"]),
        CoreOptionDescriptor(key: "snes9x_superscope_crosshair", defaultValue: "2",
                             values: (0...16).map(String.init)),
        CoreOptionDescriptor(key: "snes9x_superscope_color", defaultValue: "White",
                             values: ["White", "White (blend)", "Red", "Red (blend)",
                                      "Orange", "Orange (blend)", "Yellow", "Yellow (blend)",
                                      "Green", "Green (blend)", "Cyan", "Cyan (blend)",
                                      "Sky", "Sky (blend)", "Blue", "Blue (blend)",
                                      "Violet", "Violet (blend)", "Pink", "Pink (blend)",
                                      "Purple", "Purple (blend)", "Black", "Black (blend)",
                                      "25% Grey", "25% Grey (blend)", "50% Grey",
                                      "50% Grey (blend)", "75% Grey", "75% Grey (blend)"]),
        CoreOptionDescriptor(key: "snes9x_justifier1_crosshair", defaultValue: "4",
                             values: (0...16).map(String.init)),
        CoreOptionDescriptor(key: "snes9x_justifier1_color", defaultValue: "Blue",
                             values: ["Blue", "Blue (blend)", "Violet", "Violet (blend)",
                                      "Pink", "Pink (blend)", "Purple", "Purple (blend)",
                                      "Black", "Black (blend)", "25% Grey", "25% Grey (blend)",
                                      "50% Grey", "50% Grey (blend)", "75% Grey",
                                      "75% Grey (blend)", "White", "White (blend)",
                                      "Red", "Red (blend)", "Orange", "Orange (blend)",
                                      "Yellow", "Yellow (blend)", "Green", "Green (blend)",
                                      "Cyan", "Cyan (blend)", "Sky", "Sky (blend)"]),
        CoreOptionDescriptor(key: "snes9x_justifier2_crosshair", defaultValue: "4",
                             values: (0...16).map(String.init)),
        CoreOptionDescriptor(key: "snes9x_justifier2_color", defaultValue: "Pink",
                             values: ["Pink", "Pink (blend)", "Purple", "Purple (blend)",
                                      "Black", "Black (blend)", "25% Grey", "25% Grey (blend)",
                                      "50% Grey", "50% Grey (blend)", "75% Grey",
                                      "75% Grey (blend)", "White", "White (blend)",
                                      "Red", "Red (blend)", "Orange", "Orange (blend)",
                                      "Yellow", "Yellow (blend)", "Green", "Green (blend)",
                                      "Cyan", "Cyan (blend)", "Sky", "Sky (blend)",
                                      "Blue", "Blue (blend)", "Violet", "Violet (blend)"]),
        CoreOptionDescriptor(key: "snes9x_rifle_crosshair", defaultValue: "2",
                             values: (0...16).map(String.init)),
        CoreOptionDescriptor(key: "snes9x_rifle_color", defaultValue: "White",
                             values: ["White", "White (blend)", "Red", "Red (blend)",
                                      "Orange", "Orange (blend)", "Yellow", "Yellow (blend)",
                                      "Green", "Green (blend)", "Cyan", "Cyan (blend)",
                                      "Sky", "Sky (blend)", "Blue", "Blue (blend)",
                                      "Violet", "Violet (blend)", "Pink", "Pink (blend)",
                                      "Purple", "Purple (blend)", "Black", "Black (blend)",
                                      "25% Grey", "25% Grey (blend)", "50% Grey",
                                      "50% Grey (blend)", "75% Grey", "75% Grey (blend)"]),
        CoreOptionDescriptor(key: "snes9x_msu1_enhanced_audio", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_show_advanced_av_settings", defaultValue: "disabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_layer_1", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_layer_2", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_layer_3", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_layer_4", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_layer_5", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_gfx_transp", defaultValue: "enabled",
                             values: ["enabled", "disabled"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_1", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_2", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_3", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_4", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_5", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_6", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_7", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
        CoreOptionDescriptor(key: "snes9x_sndchan_volume_8", defaultValue: "100",
                             values: ["0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100"]),
    ]

    private static let byKey: [String: CoreOptionDescriptor] = {
        Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })
    }()

    /// The core's own default, or nil for a key we do not know about.
    static func descriptor(for key: String) -> CoreOptionDescriptor? { byKey[key] }
}

/// The subset worth putting in front of a human, grouped so the Settings screen
/// stays navigable. Everything else remains reachable through the full table.
enum CoreOptionCatalog {
    struct Group: Identifiable, Sendable {
        let id: String
        let title: String
        let caption: String
        let keys: [String]
    }

    static let groups: [Group] = [
        Group(
            id: "timing",
            title: "Timing & Smoothness",
            caption: "What makes a SNES game feel responsive or sluggish on a phone.",
            keys: ["snes9x_overclock_cycles",
                   "snes9x_reduce_sprite_flicker",
                   "snes9x_randomize_memory",
                   "snes9x_echo_buffer_hack"]),
        Group(
            id: "audio",
            title: "Audio",
            caption: "The Gaussian filter is the original hardware's warmth; the others trade it for clarity.",
            keys: ["snes9x_audio_interpolation",
                   "snes9x_msu1_enhanced_audio"]),
        Group(
            id: "video",
            title: "Video",
            caption: "CRT-era presentation. Blargg's filter is the composite-video look.",
            keys: ["snes9x_blargg",
                   "snes9x_hires_blend",
                   "snes9x_mode7_hires",
                   "snes9x_mode7_hires_bilinear",
                   "snes9x_aspect",
                   "snes9x_overscan"]),
        Group(
            id: "input",
            title: "Input",
            caption: nil,
            keys: ["snes9x_up_down_allowed"]),
        Group(
            id: "compat",
            title: "Compatibility",
            caption: "Leave these alone unless a specific game misbehaves.",
            keys: ["snes9x_region",
                   "snes9x_block_invalid_vram_access"]),
    ]

    /// Keys offered as loose toggles in the Settings screen, in order.
    static var curatedKeys: [String] { groups.flatMap(\.keys) }

    /// Options snes9x reads once, when a game loads, and never again. Changing one
    /// of these while a game is running has no effect until it is reloaded, so the
    /// Settings screen marks them and offers a restart.
    static let reloadRequired: Set<String> = [
        "snes9x_region",
        "snes9x_aspect",
        "snes9x_overscan",
        "snes9x_mode7_hires",
        "snes9x_mode7_hires_bilinear",
        "snes9x_overclock_superfx",
        "snes9x_superfx_timing",
        "snes9x_show_advanced_av_settings",
    ]
}
