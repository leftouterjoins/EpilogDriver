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

    /// Custom material settings the operator has worked out, kept alongside
    /// the built-in starting points.
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

    /// Built-in presets first, then the operator's own.
    var allMaterials: [MaterialPreset] {
        MaterialPreset.builtIn + materials
    }
}
