/*
 * ImageCacheTests.swift - The cache must not evict what you just asked for
 *
 * This is the bug that made Split into Parts unusable. The preview cache held
 * a fixed twenty-four images; splitting a sheet into forty parts meant every
 * frame evicted images it was about to need and re-rendered them, so the canvas
 * did forty full renders per frame and the app beachballed.
 */

import XCTest
import CoreGraphics
@testable import EpilogKit

final class ImageCacheTests: XCTestCase {

    /// Roughly `side * side * 4` bytes.
    private func image(side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    func testHitsDoNotRerender() {
        let cache = ImageCache<Int>(budgetBytes: 10 << 20)
        var renders = 0

        for _ in 0..<5 {
            _ = cache.image(for: 1) { renders += 1; return image(side: 32) }
        }
        XCTAssertEqual(renders, 1)
    }

    /// The case that broke: more items than a naive limit would hold, all of
    /// them wanted on every frame.
    func testEveryItemSurvivesWhenTheyAllFit() {
        let cache = ImageCache<Int>(budgetBytes: 64 << 20)
        var renders = 0

        // Forty previews of a split sheet, drawn frame after frame.
        for _ in 0..<10 {
            for item in 0..<40 {
                _ = cache.image(for: item) { renders += 1; return self.image(side: 128) }
            }
        }
        XCTAssertEqual(renders, 40, "each item should be rendered exactly once")
        XCTAssertEqual(cache.count, 40)
    }

    /// Over budget, the least recently used goes - not the newest.
    func testEvictionTakesTheLeastRecentlyUsed() {
        // Each image is 256 x 256 x 4 = 256 KB; the budget holds about four.
        let cache = ImageCache<Int>(budgetBytes: 1 << 20)
        for item in 0..<4 { _ = cache.image(for: item) { self.image(side: 256) } }

        // Touch 0 so it is no longer the oldest, then push the budget over.
        var renders = 0
        _ = cache.image(for: 0) { renders += 1; return self.image(side: 256) }
        XCTAssertEqual(renders, 0, "0 was still cached")

        _ = cache.image(for: 99) { self.image(side: 256) }

        // 1 was the least recently used, so it is the one that went.
        renders = 0
        _ = cache.image(for: 1) { renders += 1; return self.image(side: 256) }
        XCTAssertEqual(renders, 1, "the least recently used entry should have gone")

        renders = 0
        _ = cache.image(for: 0) { renders += 1; return self.image(side: 256) }
        XCTAssertEqual(renders, 0, "the recently used entry should have stayed")
    }

    /// A single image larger than the whole budget must still be returned and
    /// still be there next frame. Evicting it would guarantee a re-render every
    /// frame, which is worse than being over budget.
    func testAnOversizedImageIsKept() {
        let cache = ImageCache<Int>(budgetBytes: 1024)
        var renders = 0
        for _ in 0..<3 {
            _ = cache.image(for: 1) { renders += 1; return self.image(side: 256) }
        }
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(cache.count, 1)
    }

    func testBudgetIsActuallyEnforced() {
        let budget = 1 << 20
        let cache = ImageCache<Int>(budgetBytes: budget)
        for item in 0..<50 { _ = cache.image(for: item) { self.image(side: 256) } }

        XCTAssertLessThanOrEqual(cache.byteCount, budget + (256 * 256 * 4),
                                 "at most one entry's worth over, being the newest")
        XCTAssertGreaterThan(cache.count, 1)
    }

    func testFailedRendersAreNotCached() {
        let cache = ImageCache<Int>(budgetBytes: 1 << 20)
        var attempts = 0
        for _ in 0..<3 {
            _ = cache.image(for: 1) { attempts += 1; return nil }
        }
        XCTAssertEqual(attempts, 3, "nothing was produced, so nothing was remembered")
        XCTAssertEqual(cache.count, 0)
    }

    func testRemoveAllClears() {
        let cache = ImageCache<Int>(budgetBytes: 1 << 20)
        _ = cache.image(for: 1) { self.image(side: 64) }
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
    }
}
