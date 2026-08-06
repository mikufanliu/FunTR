// WallpaperSource.swift — screensaver backdrops, built-in plus the user's own.
//
// Built-ins live base64-embedded in `RoomAsset`. On top of those, anything dropped in
// ~/.mactr/wallpapers/ shows up automatically — same "watch a dot-directory" idea as
// PinService, so no restart and no import step.
//
// Memory is the constraint that shapes this. A 1920x480 image is ~3.7MB decoded, so a
// folder with thirty wallpapers in it must not become 110MB resident. User images are
// therefore decoded on demand and only the most recent one is kept; the built-ins are
// already resident inside RoomAsset and are not duplicated here.

import CoreGraphics
import Foundation
import ImageIO

final class WallpaperSource: @unchecked Sendable {

    private let fm = FileManager.default
    private let lock = NSLock()

    /// User files, sorted by name so the picker order is stable and predictable.
    private var userPaths: [String] = []
    private var lastDirMTime: Date?
    private var lastScan: Date?

    /// Exactly one decoded user image is held at a time — see the note above.
    private var cachedPath: String?
    private var cachedImage: CGImage?

    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]

    /// ~/.mactr/wallpapers — drop images here.
    static var directory: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.mactr/wallpapers"
    }

    /// Create the folder so there is somewhere obvious to put files (used by Settings).
    @discardableResult
    static func ensureDirectory() -> String {
        let dir = directory
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Scanning

    /// Re-list the directory when it changes. Directory mtime moves on add/remove, so
    /// the common case is one stat(). Rate-limited because a rename inside the folder
    /// does not always bump the mtime.
    func refresh() {
        let dir = WallpaperSource.directory
        let now = Date()
        var attrsChanged = true
        if let attrs = try? fm.attributesOfItem(atPath: dir),
           let mtime = attrs[.modificationDate] as? Date {
            attrsChanged = (mtime != lastDirMTime)
            if attrsChanged { lastDirMTime = mtime }
        } else {
            // No directory: forget any files we had listed.
            if !userPaths.isEmpty {
                lock.lock(); userPaths = []; cachedPath = nil; cachedImage = nil; lock.unlock()
            }
            return
        }
        if !attrsChanged, let last = lastScan, now.timeIntervalSince(last) < 30 { return }
        lastScan = now

        let found = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { WallpaperSource.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { dir + "/" + $0 }

        lock.lock()
        let changed = found != userPaths
        userPaths = found
        if changed, let c = cachedPath, !found.contains(c) {
            cachedPath = nil; cachedImage = nil
        }
        lock.unlock()
        if changed { log("[Wallpaper] \(found.count) user image(s) in \(dir)") }
    }

    // MARK: - Access

    /// Built-ins first, then user files.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return RoomAsset.count + userPaths.count
    }

    /// Display name: the built-in's label, or the user file's name without extension.
    func name(at index: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        if index < RoomAsset.count {
            return index < RoomAsset.names.count ? RoomAsset.names[index] : "内置 \(index + 1)"
        }
        let i = index - RoomAsset.count
        guard i < userPaths.count else { return "?" }
        return ((userPaths[i] as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The image, decoding a user file if needed. Only the returned user image stays
    /// cached, so rotating through a large folder holds one at a time.
    func image(at index: Int) -> CGImage? {
        lock.lock()
        if index < RoomAsset.count {
            lock.unlock()
            return index < RoomAsset.images.count ? RoomAsset.images[index] : nil
        }
        let i = index - RoomAsset.count
        guard i < userPaths.count else { lock.unlock(); return nil }
        let path = userPaths[i]
        if path == cachedPath, let img = cachedImage { lock.unlock(); return img }
        lock.unlock()

        // Decode outside the lock — this is milliseconds of work on the render thread.
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            logProblem("[Wallpaper] 无法解码 \(path)")
            return nil
        }
        lock.lock(); cachedPath = path; cachedImage = img; lock.unlock()
        log("[Wallpaper] Decoded \((path as NSString).lastPathComponent)")
        return img
    }
}
