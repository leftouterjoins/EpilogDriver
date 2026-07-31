/*
 * LaserLayer.swift - What happens to each colour in the artwork
 *
 * The whole point of the application. A document arrives as coloured geometry;
 * a layer says what the laser does with one of those colours. The CUPS driver
 * hardcoded this ("cyan means cut"), which is fine right up until it is wrong,
 * and then there is nothing the operator can do about it.
 */

import Foundation

/// What the laser does with a layer.
public enum LayerOperation: String, Codable, CaseIterable, Identifiable {
    /// Burn the artwork as a bitmap, sweeping back and forth.
    case engrave = "Engrave"
    /// Follow the outline at cutting power.
    case cut = "Cut"
    /// Follow the outline at low power, to mark a fold or a guide line.
    case score = "Score"
    /// Ignore this colour entirely - neither engraved nor cut.
    case skip = "Skip"

    public var id: String { rawValue }

    /// Whether this operation produces vector motion rather than a raster pass.
    public var isVector: Bool { self == .cut || self == .score }

    public var symbolName: String {
        switch self {
        case .engrave: return "square.grid.3x3.fill"
        case .cut:     return "scissors"
        case .score:   return "pencil.line"
        case .skip:    return "eye.slash"
        }
    }
}

/// How an engraved layer's artwork is turned into laser power.
public enum EngraveRendering: String, Codable, CaseIterable, Identifiable {
    /// Keep the artwork's own tone: a photograph stays a photograph, a grey
    /// stays grey. What you see on screen is what burns.
    case shaded = "Shaded"
    /// Burn the shape at full darkness regardless of its colour. What you want
    /// for artwork drawn in a colour that happens to be light - a yellow logo
    /// is not meant to engrave faintly, it is meant to engrave.
    case solid = "Solid"

    public var id: String { rawValue }
}

/// Which part of the artwork a layer governs.
public enum LayerTarget: Hashable, Codable {
    /// Paths painted in this colour.
    case color(RGBColor)
    /// Everything a path cannot describe: text, photographs, gradients.
    /// Present only for sources that have such content.
    case background

    public var color: RGBColor? {
        if case .color(let c) = self { return c }
        return nil
    }
}

/// One colour's worth of instructions.
public struct LaserLayer: Identifiable, Codable, Equatable {
    public var id: UUID
    public var target: LayerTarget

    /// Shown in the layer list. Defaults to the colour, but a person naming a
    /// layer "score lines" will find it far faster than "#00FFFF".
    public var name: String

    public var operation: LayerOperation

    public var power: Int          // 0-100 %
    public var speed: Int          // 1-100 %
    public var frequency: Int      // 1-5000 Hz, vector only
    public var passes: Int         // repeat the whole layer this many times

    /// Engrave only: whether to keep the artwork's tone or burn it solid.
    public var rendering: EngraveRendering

    /// Engrave only: how continuous tone becomes dots.
    public var dither: DitherMode

    /// Drawn in the preview. Turning this off declutters a busy document
    /// without changing what the laser does.
    public var visible: Bool

    /// Included in the job. This is the one that changes the outcome.
    public var enabled: Bool

    public init(id: UUID = UUID(), target: LayerTarget, name: String,
                operation: LayerOperation,
                power: Int, speed: Int, frequency: Int = 500, passes: Int = 1,
                rendering: EngraveRendering = .shaded, dither: DitherMode = .none,
                visible: Bool = true, enabled: Bool = true) {
        self.id = id
        self.target = target
        self.name = name
        self.operation = operation
        self.power = power
        self.speed = speed
        self.frequency = frequency
        self.passes = passes
        self.rendering = rendering
        self.dither = dither
        self.visible = visible
        self.enabled = enabled
    }

    /// The colour to draw this layer in. Background content has no colour of
    /// its own, so it shows as a neutral grey.
    public var swatch: RGBColor {
        target.color ?? RGBColor(r: 0.45, g: 0.45, b: 0.48)
    }

    /// Whether this layer contributes anything to the job.
    public var contributes: Bool {
        enabled && operation != .skip && power > 0 && passes > 0
    }

    // MARK: - Defaults

    /// Choose sensible settings for a colour that has just appeared.
    ///
    /// The defaults encode the convention this whole project grew out of: the
    /// six saturated colours mark cuts, everything else is artwork to engrave.
    /// A person can change any of it, but opening a file marked up the usual
    /// way should produce the usual result without touching anything.
    public static func makeDefault(for target: LayerTarget,
                                   material: MaterialPreset?,
                                   index: Int) -> LaserLayer {
        let cut = material.map { (p: $0.cutPower, s: $0.cutSpeed,
                                  f: $0.cutFrequency, n: $0.cutPasses) }
                  ?? (p: 100, s: 15, f: 500, n: 1)
        let engrave = material.map { (p: $0.engravePower, s: $0.engraveSpeed, d: $0.engraveDither) }
                      ?? (p: 60, s: 100, d: DitherMode.none)

        switch target {
        case .background:
            return LaserLayer(target: .background, name: "Text & images",
                              operation: .engrave,
                              power: engrave.p, speed: engrave.s,
                              rendering: .shaded, dither: engrave.d)

        case .color(let color):
            let (r, g, b) = color.bytes
            let cutColor = CutColor(r: r, g: g, b: b)

            if let cc = cutColor {
                // A saturated colour: the marking convention for a cut.
                return LaserLayer(target: target, name: cc.displayName.capitalized + " cut",
                                  operation: .cut,
                                  power: cut.p, speed: cut.s,
                                  frequency: cut.f, passes: cut.n)
            }

            // Everything else engraves. Near-white artwork would engrave as
            // almost nothing if its own tone were kept, which is never what
            // someone means by putting it in the file, so it burns solid.
            let veryLight = color.luma > 0.75
            return LaserLayer(target: target,
                              name: "Engrave \(index + 1)",
                              operation: .engrave,
                              power: engrave.p, speed: engrave.s,
                              rendering: veryLight ? .solid : .shaded,
                              dither: engrave.d)
        }
    }
}

extension CutColor {
    /// Human name, for layer titles.
    public var displayName: String {
        switch self {
        case .red:     return "red"
        case .green:   return "green"
        case .blue:    return "blue"
        case .cyan:    return "cyan"
        case .yellow:  return "yellow"
        case .magenta: return "magenta"
        }
    }
}
