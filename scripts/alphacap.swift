import CoreGraphics
import Foundation
import ImageIO
// alphacap <input.png> <layer.png>...: exits 0 when no layer is more opaque than the input anywhere (MES Image §3.2:
// transparent input pixels stay transparent in every layer). Each layer is compared at the input's size.
func alpha(_ path: String, width: Int? = nil, height: Int? = nil) -> (Int, Int, [UInt8]) {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
    let w = width ?? img.width, h = height ?? img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, stride(from: 3, to: buf.count, by: 4).map { buf[$0] })
}
let input = alpha(CommandLine.arguments[1])
var worst = 0
for path in CommandLine.arguments.dropFirst(2) {
    let layer = alpha(path, width: input.0, height: input.1)
    var over = 0, most = 0
    for i in 0..<input.2.count where layer.2[i] > input.2[i] { over += 1; most = max(most, Int(layer.2[i]) - Int(input.2[i])) }
    print("\((path as NSString).lastPathComponent): \(over) pixels above the input's alpha, by at most \(most)")
    worst = max(worst, most)
}
exit(worst == 0 ? 0 : 1)
