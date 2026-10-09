// Decode the actual source/previous/candidate movies into a labelled-by-sidecar
// contact sheet. No correction is applied while making this review artifact.
import Foundation
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
@main struct Contacts {
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count == 7,let frame = Int(args[4]),let fps = Int32(args[5]) else { throw NSError(domain: "ContactsUsage",code: 1) }
  let assets = args[1...3].map { AVURLAsset(url: URL(fileURLWithPath: $0)) }
  var images = [[CGImage]]()
  for asset in assets {
   let generator = AVAssetImageGenerator(asset: asset)
   generator.appliesPreferredTrackTransform = true
   generator.maximumSize = CGSize(width: 640,height: 640)
   generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
   var row = [CGImage]()
   for index in (frame-1)...(frame+1) {
    let result = try await generator.image(at: CMTime(value: Int64(index),timescale: fps))
    row.append(result.image)
   }
   images.append(row)
  }
  let width = images[0][0].width,height = images[0][0].height
  let context = CGContext(data: nil,width: width*3,height: height*3,bitsPerComponent: 8,bytesPerRow: width*3*4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for r in 0..<3 { for c in 0..<3 {
   context.draw(images[r][c],in: CGRect(x: c*width,y: (2-r)*height,width: width,height: height))
  } }
  let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[6]) as CFURL,UTType.png.identifier as CFString,1,nil)!
  CGImageDestinationAddImage(destination,context.makeImage()!,nil)
  guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "ContactsWrite",code: 1) }
 }
}
