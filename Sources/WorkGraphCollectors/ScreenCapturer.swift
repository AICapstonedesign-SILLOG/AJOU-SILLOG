import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 연속 녹화가 아니라 필요한 순간의 스틸 한 장 (SCScreenshotManager). 메뉴바의 보라색 녹화 표시가 뜨지 않는다.
public struct ScreenCapturer: Sendable {
    public init() {}

    public func capture(snapshot: ContextSnapshot, excluding privacy: PrivacyFilter, maxWidth: Int = 1600) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(), privacy.mayCapture(bundle: snapshot.appBundle, windowTitle: snapshot.windowTitle) else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let window: SCWindow?
            if let frame = snapshot.windowFrame {
                // 접근성으로 읽은 창과 제목·위치가 같은 창 하나
                let matches = content.windows.filter {
                    $0.owningApplication?.processID == snapshot.pid && $0.title == snapshot.windowTitle && $0.frame == frame
                }
                window = matches.count == 1 ? matches.first : nil
            } else {
                // 기기 제어 권한이 없으면 창 정보가 없다. 창 목록에서 그 앱의 맨 앞 창을 창 번호로 찾는다
                window = Self.frontWindowID(pid: snapshot.pid).flatMap { id in content.windows.first { $0.windowID == id } }
            }
            // 창을 하나로 특정하지 못하면 전체 화면으로 대체하지 않는다.
            guard let window else { return nil }
            let frame = window.frame
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

    /// 그 프로세스의 맨 앞 일반 창 번호. 창 목록은 앞에서 뒤 순서다
    static func frontWindowID(pid: pid_t) -> CGWindowID? {
        let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return frontWindowID(in: infos ?? [], pid: pid)
    }

    /// 메뉴·떠 있는 패널(층이 0이 아닌 창), 투명한 창, 아주 작은 창은 건너뛴다
    static func frontWindowID(in infos: [[String: Any]], pid: pid_t) -> CGWindowID? {
        for info in infos {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width >= 100, rect.height >= 60,
                  let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            return number.uint32Value
        }
        return nil
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
