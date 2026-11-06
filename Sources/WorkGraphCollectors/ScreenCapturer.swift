import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 연속 녹화가 아니라 필요한 순간의 스틸 한 장 (SCScreenshotManager). 메뉴바의 보라색 녹화 표시가 뜨지 않는다.
public struct ScreenCapturer: Sendable {
    public init() {}

    public func capture(snapshot: ContextSnapshot, excluding privacy: PrivacyFilter, maxWidth: Int = 1600) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), let frame = snapshot.windowFrame,
              !privacy.isExcluded(bundle: snapshot.appBundle), !privacy.isPrivateWindow(title: snapshot.windowTitle) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let infos = content.windows.map { WindowInfo(pid: $0.owningApplication?.processID ?? 0, title: $0.title, frame: $0.frame) }
            // 창을 하나로 특정하지 못하면 전체 화면으로 대체하지 않는다.
            guard let index = Self.pick(infos, pid: snapshot.pid, title: snapshot.windowTitle, frame: frame) else { return nil }
            let window = content.windows[index]
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let scale = min(1.0, Double(maxWidth) / max(frame.width, 1))
            config.width = max(2, Int(frame.width * scale) / 2 * 2)
            config.height = max(2, Int(frame.height * scale) / 2 * 2)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil
        }
    }

    struct WindowInfo: Equatable {
        var pid: pid_t
        var title: String?
        var frame: CGRect
    }

    /// 찍을 창: 같은 프로그램의 같은 위치·크기 창 중 제목이 같은 것, 없으면 접근성 제목이 "캡처 쪽 제목 - …" 인 것 중 가장 길게 맞는 것.
    /// Chrome 은 접근성 제목에만 " - Chrome - 프로필" 을 붙인다. 최대화한 창 여러 개는 위치·크기가 같아 제목으로 가린다. 하나로 정해지지 않으면 nil
    static func pick(_ windows: [WindowInfo], pid: pid_t, title: String?, frame: CGRect) -> Int? {
        let candidates = windows.indices.filter { windows[$0].pid == pid && windows[$0].frame == frame }
        let exact = candidates.filter { windows[$0].title == title }
        if !exact.isEmpty { return exact.count == 1 ? exact[0] : nil }
        guard let title else { return nil }
        let prefixed = candidates.compactMap { index -> (Int, Int)? in
            guard let own = windows[index].title, !own.isEmpty, title.hasPrefix(own + " - ") else { return nil }
            return (index, own.count)
        }
        guard let longest = prefixed.map(\.1).max() else { return nil }
        let best = prefixed.filter { $0.1 == longest }
        return best.count == 1 ? best[0].0 : nil
    }

    @discardableResult
    public func saveJPEG(_ image: CGImage, to url: URL, quality: Double = 0.6) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// 9x8 회색조 차이 해시. 두 해시의 해밍 거리가 작으면 화면이 거의 안 바뀐 것이다.
    public static func differenceHash(_ image: CGImage) -> UInt64 {
        let width = 9, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hash: UInt64 = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                hash <<= 1
                if pixels[y * width + x] > pixels[y * width + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    public static func isSimilar(_ a: UInt64, _ b: UInt64, maxDistance: Int = 4) -> Bool {
        (a ^ b).nonzeroBitCount <= maxDistance
    }
}
