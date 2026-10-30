import CoreGraphics
import Foundation
import ImageIO
// alpha <png>: whether the PNG has native alpha by Ming-Image's gate metric (more than 10% of pixels with α ≤ 12 on
// 8 bits, MingNativeAlpha.isTransparent). Prints the PNG's alpha info and that fraction; exits 0 when it is transparent.
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
var clear = 0
for i in stride(from: 3, to: buf.count, by: 4) where buf[i] <= 12 { clear += 1 }
let fraction = Double(clear) / Double(w * h)
print("\(w)x\(h) alphaInfo \(img.alphaInfo.rawValue): \(String(format: "%.3f", fraction)) of pixels have α ≤ 12")
exit(fraction > 0.10 ? 0 : 1)
