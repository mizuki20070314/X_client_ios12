import UIKit
import ImageIO

/// Loads, downsamples and caches remote images. Completions run on the main queue; a cancelled
/// request never completes.
final class ImageLoader {
    static let shared = ImageLoader()

    /// Guards `flights` and the order of "join" versus "finish". Serial on purpose.
    private let stateQueue = DispatchQueue(label: "xrelay.image.state")
    /// Decoding is CPU-bound and independent per image, so several may run at once.
    private let decodeQueue = DispatchQueue(label: "xrelay.image.decode", attributes: .concurrent)
    private let urlCache: URLCache
    private let session: URLSession
    private let memory = NSCache<NSString, UIImage>()
    /// Downloads in progress, by cache key. Only touched on `stateQueue`.
    private var flights: [String: Flight] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        let cache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                             diskCapacity: 150 * 1024 * 1024,
                             diskPath: "xrelay-images")
        urlCache = cache
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        memory.totalCostLimit = 24 * 1024 * 1024
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let loader = self else { return }
            loader.memory.removeAllObjects()
        }
    }

    /// Loads, downsampled to at most `maxPixel` on the longer side (0 means 1024), and caches it.
    /// Returns nil when the answer is already known; the completion still runs on the main queue.
    @discardableResult
    func load(_ url: URL, maxPixel: CGFloat, completion: @escaping (UIImage?) -> Void) -> ImageRequest? {
        let limit = ImageLoader.pixelLimit(maxPixel)
        let key = ImageLoader.cacheKey(url, limit)
        if let image = memory.object(forKey: NSString(string: key)) {
            DispatchQueue.main.async {
                completion(image)
            }
            return nil
        }
        if CoreEnvironment.isDemo && url.scheme != "demo" {
            // Demo runs (the CI screenshots) must never depend on the network.
            DispatchQueue.main.async {
                completion(nil)
            }
            return nil
        }
        let request = ImageRequest(key: key, url: url, limit: limit,
                                   scale: UIScreen.main.scale, completion: completion)
        stateQueue.async {
            self.attach(request)
        }
        return request
    }

    /// The decoded image if it is already in memory. Never starts a download.
    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = ImageLoader.cacheKey(url, ImageLoader.pixelLimit(maxPixel))
        return memory.object(forKey: NSString(string: key))
    }

    /// Empties the memory cache and the disk cache of downloaded responses.
    func clearCaches() {
        memory.removeAllObjects()
        urlCache.removeAllCachedResponses()
    }

    /// Bytes used on disk by downloaded responses.
    var diskUsage: Int {
        return urlCache.currentDiskUsage
    }

    // MARK: - Private

    private static func pixelLimit(_ maxPixel: CGFloat) -> Int {
        // 0 (or anything unusable) means the default; the upper bound keeps decoding sane.
        if maxPixel.isNaN || maxPixel < 1 {
            return 1024
        }
        return Int(min(maxPixel, 8192).rounded())
    }

    private static func cacheKey(_ url: URL, _ limit: Int) -> String {
        return url.absoluteString + "|" + String(limit)
    }

    /// Runs on `stateQueue`: joins a download that is already running, or starts one.
    private func attach(_ request: ImageRequest) {
        // A download may have finished between the caller's cache check and this point.
        if let image = memory.object(forKey: NSString(string: request.key)) {
            DispatchQueue.main.async {
                request.deliver(image)
            }
            return
        }
        if let flight = flights[request.key] {
            flight.requests.append(request)
            return
        }
        let flight = Flight(key: request.key)
        flight.requests.append(request)
        flights[request.key] = flight

        let url = request.url
        let limit = request.limit
        let scale = request.scale
        if url.scheme == "demo" {
            decodeQueue.async {
                let image = DemoImages.image(for: url, maxPixel: CGFloat(limit))
                self.finish(flight, image: image)
            }
            return
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.cachePolicy = .returnCacheDataElseLoad
        urlRequest.timeoutInterval = 30
        let task = session.dataTask(with: urlRequest) { data, response, error in
            // Runs on the session's own queue.
            guard error == nil, let data = data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                self.finish(flight, image: nil)
                return
            }
            self.decodeQueue.async {
                self.finish(flight, image: ImageLoader.decode(data, maxPixel: limit, scale: scale))
            }
        }
        flight.task = task
        task.resume()
    }

    /// Caches the image and hands it to every request still in the flight. Callable from any thread.
    private func finish(_ flight: Flight, image: UIImage?) {
        stateQueue.async {
            if let image = image {
                let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
                self.memory.setObject(image, forKey: NSString(string: flight.key), cost: cost)
            }
            if self.flights[flight.key] === flight {
                self.flights[flight.key] = nil
            }
            let waiting = flight.requests
            DispatchQueue.main.async {
                for request in waiting {
                    request.deliver(image)
                }
            }
        }
    }

    /// Called by `ImageRequest.cancel()`. Stops the download once no request waits for it.
    fileprivate func withdraw(_ request: ImageRequest) {
        stateQueue.async {
            guard let flight = self.flights[request.key] else { return }
            flight.requests.removeAll { $0 === request }
            if flight.requests.isEmpty {
                flight.task?.cancel()
                self.flights[request.key] = nil
            }
        }
    }

    /// Decodes at most `maxPixel` along the longer side, applying the EXIF orientation.
    private static func decode(_ data: Data, maxPixel: Int, scale: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}

/// A download (or demo render) shared by every request for the same key.
private final class Flight {
    let key: String
    var requests: [ImageRequest] = []
    var task: URLSessionDataTask?

    init(key: String) {
        self.key = key
    }
}

/// One caller's pending load. `cancel()` withdraws only this caller and may be called from any thread.
final class ImageRequest {
    fileprivate let key: String
    fileprivate let url: URL
    fileprivate let limit: Int
    fileprivate let scale: CGFloat
    private let completion: (UIImage?) -> Void
    private let lock = NSLock()
    private var cancelled = false

    fileprivate init(key: String, url: URL, limit: Int, scale: CGFloat,
                     completion: @escaping (UIImage?) -> Void) {
        self.key = key
        self.url = url
        self.limit = limit
        self.scale = scale
        self.completion = completion
    }

    /// Runs on the main queue. A request cancelled before this point gets nothing.
    fileprivate func deliver(_ image: UIImage?) {
        if !isCancelled {
            completion(image)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        ImageLoader.shared.withdraw(self)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
