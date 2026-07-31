/*
 * Preferences.swift - The handful of settings that outlive a document
 *
 * Machine, address and resolution belong to the workshop, not to any one job,
 * so a new document should already know about them.
 */

import Foundation
import EpilogKit

struct Preferences: Codable, Equatable {
    var machine: LaserMachine = .zing24
    var resolution: Int = 500

    /// Material settings the operator has worked out.
    ///
    /// There are deliberately none to begin with. A table of power and speed
    /// values is only worth anything if it came off your machine, with your
    /// tube, on your supplier's material - shipping invented numbers under
    /// names like "plywood" would just be a confident way of wasting somebody's
    /// afternoon.
    var materials: [MaterialPreset] = []

    /// Ask before sending. On by default: a laser starting unexpectedly with
    /// the lid open is worth one extra click.
    var confirmBeforeSending = true

    /// Draw the outline before every real job.
    var frameBeforeSending = false

    private static let key = "sh.macinjo.epilogstudio.preferences"

    static func load() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Ordered for display: by name, then by thickness.
    var sortedMaterials: [MaterialPreset] {
        materials.sorted {
            $0.name == $1.name ? $0.thicknessInches < $1.thicknessInches
                               : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
