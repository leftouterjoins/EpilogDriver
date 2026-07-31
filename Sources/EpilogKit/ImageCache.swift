/*
 * ImageCache.swift - Keeping rendered pictures around, within reason
 *
 * Rendering is the expensive part of showing artwork, so results are kept. The
 * only question a cache like this has to get right is what to throw away, and
 * the way to get it wrong is to throw away the thing that was just asked for -
 * then it is rendered again on the very next frame, and the cache has made
 * everything slower than having no cache at all.
 */

import Foundation
import CoreGraphics

/// Least-recently-used image store with a memory budget.
///
/// The budget is in bytes rather than entries because entries are not
/// comparable: a thumbnail and a full page differ by three orders of magnitude.
/// Counting them the same way is how a cache of "24 images" ends up holding
/// either nothing useful or a gigabyte.
public final class ImageCache<Key: Hashable> {
    private var images: [Key: CGImage] = [:]
    private var order: [Key] = []          // least recently used first
    private var bytes = 0
    private let budget: Int

    public init(budgetBytes: Int) {
        self.budget = budgetBytes
    }

    public func image(for key: Key, make: () -> CGImage?) -> CGImage? {
        if let hit = images[key] {
            touch(key)
            return hit
        }
        guard let made = make() else { return nil }
        images[key] = made
        order.append(key)
        bytes += cost(of: made)
        evictIfNeeded()
        return made
    }

    public func removeAll() {
        images.removeAll()
        order.removeAll()
        bytes = 0
    }

    private func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }

    private func evictIfNeeded() {
        // Always keep the most recent one, however big it is: evicting the
        // thing that was just asked for guarantees it is rendered again next
        // frame, which is the thrash this exists to avoid.
        while bytes > budget, order.count > 1 {
            let oldest = order.removeFirst()
            if let dropped = images.removeValue(forKey: oldest) {
                bytes -= cost(of: dropped)
            }
        }
    }

    private func cost(of image: CGImage) -> Int {
        max(1, image.bytesPerRow * image.height)
    }

    /// How much is being held, for tests and for diagnosis.
    public var byteCount: Int { bytes }
    public var count: Int { images.count }
}
