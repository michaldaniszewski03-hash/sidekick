import Accelerate
import CoreMedia
import CoreVideo
import Darwin
import ImageIO
import ReplayKit

/// Screen Mirroring's iPhone side. ReplayKit hands this broadcast extension
/// every frame of the screen, whatever app is open; it sends the tiles that
/// changed to Sidekick on 127.0.0.1:53319, one packet each time the app asks
/// (lib/platform/screen_source.dart, IphoneScreen), and the app passes them
/// on to the Mac or PC watching. Packets are lib/core/mirror.dart's.
///
/// Extensions get about 50 MB, so each picture is converted straight from
/// iOS's video format into one buffer, compared with the last one sent, and
/// written to the socket tile by tile.
class SampleHandler: RPBroadcastSampleHandler {
  private let lock = NSCondition()
  private var latest: CVPixelBuffer?
  private var latestTurns = 0
  private var fresh = false
  private var ending = false
  private var socket: Int32 = -1

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    let fd = Wire.connect(port: 53319)
    guard fd >= 0 else {
      finish("Start Screen Mirroring from Sidekick on your Mac or PC, then try again.")
      return
    }
    let hello: [UInt8] = Array("SKB1".utf8)
    guard hello.withUnsafeBytes({ Wire.write(fd, $0.baseAddress!, $0.count) }) else {
      Darwin.close(fd)
      finish("Open Sidekick, then try again.")
      return
    }
    socket = fd
    let thread = Thread { [weak self] in self?.serve(fd) }
    thread.name = "sidekick-mirror"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
    guard sampleBufferType == .video, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    // Sideways apps arrive upright for the phone; the viewer turns them.
    var turns = 0
    if let raw = CMGetAttachment(
      sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
      let orientation = CGImagePropertyOrientation(rawValue: raw.uint32Value)
    {
      switch orientation {
      case .right, .rightMirrored: turns = 1
      case .down, .downMirrored: turns = 2
      case .left, .leftMirrored: turns = 3
      default: turns = 0
      }
    }
    lock.lock()
    latest = pixels
    latestTurns = turns
    fresh = true
    lock.signal()
    lock.unlock()
  }

  override func broadcastFinished() {
    lock.lock()
    ending = true
    latest = nil
    lock.broadcast()
    lock.unlock()
    if socket >= 0 { Darwin.shutdown(socket, SHUT_RDWR) }
  }

  /// Answers the app's requests until it says stop or goes away.
  private func serve(_ fd: Int32) {
    let frames = Frames()
    var command: UInt8 = 0
    loop: while true {
      if Darwin.read(fd, &command, 1) <= 0 { break }
      switch command {
      case UInt8(ascii: "S"):
        frames.sharp = true
        frames.keyframe = true
      case UInt8(ascii: "F"):
        frames.sharp = false
        frames.keyframe = true
      case UInt8(ascii: "K"):
        frames.keyframe = true
      case UInt8(ascii: "N"):
        let (buffer, turns) = next(force: frames.keyframe)
        if !frames.send(buffer, turns: turns, to: fd) { break loop }
      case UInt8(ascii: "Q"):
        break loop
      default:
        break
      }
    }
    Darwin.close(fd)
    lock.lock()
    let finished = ending
    lock.unlock()
    if !finished { finish("Screen Mirroring has ended.") }
  }

  /// The newest picture if it's new (waiting a moment for one, so a still
  /// screen isn't asked hundreds of times a second), or the last one again
  /// when [force]d (a key frame, a new size).
  private func next(force: Bool) -> (CVPixelBuffer?, Int) {
    lock.lock()
    defer { lock.unlock() }
    if !force {
      let until = Date().addingTimeInterval(0.05)
      while !fresh && !ending {
        if !lock.wait(until: until) { break }
      }
    }
    let buffer = fresh || force ? latest : nil
    fresh = false
    return (buffer, latestTurns)
  }

  private func finish(_ message: String) {
    finishBroadcastWithError(NSError(domain: "Sidekick", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
  }
}

/// The picture: converted to BGRA at the chosen size, compared tile by tile
/// with what was last sent, and written out as packets.
final class Frames {
  static let tile = 64

  /// Every pixel; otherwise half the size each way (4x fewer, still exact).
  var sharp = false
  var keyframe = true

  private var width = 0
  private var height = 0
  private var current: UnsafeMutableRawPointer?
  private var shown: UnsafeMutableRawPointer?
  private var dirty: [Bool] = []
  private var lumaSmall: UnsafeMutableRawPointer?
  private var chromaSmall: UnsafeMutableRawPointer?
  private var smallSize = 0
  private var info = vImage_YpCbCrToARGB()
  private var preparedFull: Bool?
  private let stagingSize = 256 * 1024
  private let staging: UnsafeMutableRawPointer
  private var used = 0

  init() {
    staging = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
  }

  deinit {
    free(current)
    free(shown)
    free(lumaSmall)
    free(chromaSmall)
    staging.deallocate()
  }

  /// One packet: the changes in [buffer] (if any), or every tile for a key
  /// frame. False once the app has gone.
  func send(_ buffer: CVPixelBuffer?, turns: Int, to fd: Int32) -> Bool {
    if let buffer = buffer, convert(buffer) { compare() }
    let tile = Frames.tile
    let tilesX = (width + tile - 1) / tile
    let tilesY = (height + tile - 1) / tile
    let all = keyframe && width > 0
    if all { keyframe = false }
    var count = 0
    var size = 16
    if width > 0 {
      for ty in 0..<tilesY {
        for tx in 0..<tilesX where all || dirty[ty * tilesX + tx] {
          count += 1
          size += 8 + min(tile, width - tx * tile) * min(tile, height - ty * tile) * 4
        }
      }
    }
    var header = [UInt8](repeating: 0, count: 20)
    put32(&header, 0, size)
    header[4] = UInt8(ascii: "S")
    header[5] = UInt8(ascii: "K")
    header[6] = UInt8(ascii: "M")
    header[7] = UInt8(ascii: "1")
    put16(&header, 8, width)
    put16(&header, 10, height)
    put16(&header, 12, 0xFFFF)  // no pointer on a phone
    put16(&header, 14, 0xFFFF)
    put16(&header, 16, count)
    put16(&header, 18, (all ? 1 : 0) | (turns & 3) << 2)
    guard header.withUnsafeBytes({ out($0.baseAddress!, $0.count, fd) }) else { return false }
    if count > 0, let shown = shown {
      let stride = width * 4
      for ty in 0..<tilesY {
        for tx in 0..<tilesX where all || dirty[ty * tilesX + tx] {
          dirty[ty * tilesX + tx] = false
          let x0 = tx * tile, y0 = ty * tile
          let w = min(tile, width - x0), h = min(tile, height - y0)
          var tileHeader = [UInt8](repeating: 0, count: 8)
          put16(&tileHeader, 0, x0)
          put16(&tileHeader, 2, y0)
          put16(&tileHeader, 4, w)
          put16(&tileHeader, 6, h)
          guard tileHeader.withUnsafeBytes({ out($0.baseAddress!, 8, fd) }) else { return false }
          for row in 0..<h {
            guard out(shown + (y0 + row) * stride + x0 * 4, w * 4, fd) else { return false }
          }
        }
      }
    }
    return flush(fd)
  }

  private func put16(_ bytes: inout [UInt8], _ at: Int, _ value: Int) {
    bytes[at] = UInt8(value & 0xFF)
    bytes[at + 1] = UInt8((value >> 8) & 0xFF)
  }

  private func put32(_ bytes: inout [UInt8], _ at: Int, _ value: Int) {
    for i in 0..<4 { bytes[at + i] = UInt8((value >> (8 * i)) & 0xFF) }
  }

  private func out(_ bytes: UnsafeRawPointer, _ count: Int, _ fd: Int32) -> Bool {
    if used + count > stagingSize {
      guard flush(fd) else { return false }
      if count > stagingSize { return Wire.write(fd, bytes, count) }
    }
    (staging + used).copyMemory(from: bytes, byteCount: count)
    used += count
    return true
  }

  private func flush(_ fd: Int32) -> Bool {
    defer { used = 0 }
    return used == 0 || Wire.write(fd, staging, used)
  }

  private func resize(_ w: Int, _ h: Int) {
    if w == width && h == height { return }
    free(current)
    free(shown)
    current = malloc(w * h * 4)
    shown = calloc(w * h * 4, 1)
    width = w
    height = h
    let tile = Frames.tile
    dirty = [Bool](repeating: false, count: ((w + tile - 1) / tile) * ((h + tile - 1) / tile))
    keyframe = true
  }

  /// Converts [buffer] into `current` at the chosen size.
  private func convert(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let fullWidth = CVPixelBufferGetWidth(buffer), fullHeight = CVPixelBufferGetHeight(buffer)
    let half = !sharp
    let w = (half ? fullWidth / 2 : fullWidth) & ~1
    let h = (half ? fullHeight / 2 : fullHeight) & ~1
    guard w > 0, h > 0, w < 65536, h < 65536 else { return false }
    resize(w, h)
    var dest = vImage_Buffer(data: current, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
    let none = vImage_Flags(kvImageNoFlags)
    switch format {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
      guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
      else { return false }
      var luma = vImage_Buffer(
        data: lumaBase, height: vImagePixelCount(fullHeight), width: vImagePixelCount(fullWidth),
        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
      var chroma = vImage_Buffer(
        data: chromaBase, height: vImagePixelCount(fullHeight / 2), width: vImagePixelCount(fullWidth / 2),
        rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
      if half {
        // Scaling the planes before converting: a quarter of the work.
        if smallSize != w * h {
          free(lumaSmall)
          free(chromaSmall)
          lumaSmall = malloc(w * h)
          chromaSmall = malloc(w * h / 2)
          smallSize = w * h
        }
        var smallLuma = vImage_Buffer(
          data: lumaSmall, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
        var smallChroma = vImage_Buffer(
          data: chromaSmall, height: vImagePixelCount(h / 2), width: vImagePixelCount(w / 2), rowBytes: w)
        guard vImageScale_Planar8(&luma, &smallLuma, nil, none) == kvImageNoError,
          vImageScale_CbCr8(&chroma, &smallChroma, nil, none) == kvImageNoError
        else { return false }
        luma = smallLuma
        chroma = smallChroma
      } else {
        luma.width = vImagePixelCount(w)
        luma.height = vImagePixelCount(h)
        chroma.width = vImagePixelCount(w / 2)
        chroma.height = vImagePixelCount(h / 2)
      }
      prepare(full: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
      let bgra: [UInt8] = [3, 2, 1, 0]
      return vImageConvert_420Yp8_CbCr8ToARGB8888(&luma, &chroma, &dest, &info, bgra, 255, none) == kvImageNoError
    case kCVPixelFormatType_32BGRA:
      guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
      var source = vImage_Buffer(
        data: base, height: vImagePixelCount(fullHeight), width: vImagePixelCount(fullWidth),
        rowBytes: CVPixelBufferGetBytesPerRow(buffer))
      if half { return vImageScale_ARGB8888(&source, &dest, nil, none) == kvImageNoError }
      source.width = vImagePixelCount(w)
      source.height = vImagePixelCount(h)
      return vImageCopyBuffer(&source, &dest, 4, none) == kvImageNoError
    default:
      return false
    }
  }

  private func prepare(full: Bool) {
    if preparedFull == full { return }
    var range =
      full
      ? vImage_YpCbCrPixelRange(
        Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255, YpMax: 255, YpMin: 0, CbCrMax: 255,
        CbCrMin: 0)
      : vImage_YpCbCrPixelRange(
        Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240,
        CbCrMin: 16)
    _ = vImageConvert_YpCbCrToARGB_GenerateConversion(
      kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888,
      vImage_Flags(kvImageNoFlags))
    preparedFull = full
  }

  /// Marks the tiles that differ from what was sent, then keeps the new
  /// picture as what was sent.
  private func compare() {
    guard let current = current, let shown = shown else { return }
    let tile = Frames.tile, stride = width * 4
    let tilesX = (width + tile - 1) / tile
    var any = false
    for y in 0..<height {
      let band = (y / tile) * tilesX
      let row = y * stride
      for tx in 0..<tilesX where !dirty[band + tx] {
        let x0 = tx * tile * 4
        let bytes = min(tile, width - tx * tile) * 4
        if memcmp(current + row + x0, shown + row + x0, bytes) != 0 {
          dirty[band + tx] = true
          any = true
        }
      }
    }
    if any { memcpy(shown, current, width * height * 4) }
  }
}

/// A plain blocking TCP connection to the app, on this iPhone only.
enum Wire {
  static func connect(port: UInt16) -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var on: Int32 = 1
    setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0 {
      Darwin.close(fd)
      return -1
    }
    return fd
  }

  static func write(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Bool {
    var sent = 0
    while sent < count {
      let n = Darwin.write(fd, bytes + sent, count - sent)
      if n < 0 && errno == EINTR { continue }
      if n <= 0 { return false }
      sent += n
    }
    return true
  }
}
