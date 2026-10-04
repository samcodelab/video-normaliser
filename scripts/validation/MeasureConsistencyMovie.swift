// Clip-specific audit: reviewed cuts and measurement regions for the 86-frame fixture.
import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@main struct MeasureMovie {
 static func main() async throws {
  let args=CommandLine.arguments
  guard args.count == 3 else { fatalError("Usage: measure <movie> <output directory>") }
  let asset=AVURLAsset(url:URL(fileURLWithPath:args[1]))
  let directory=URL(fileURLWithPath:args[2])
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  let track=try await asset.loadTracks(withMediaType:.video)[0]
  let reader=try AVAssetReader(asset:asset)
  let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
  reader.add(output);guard reader.startReading() else { throw reader.error! }
  let ctx=CIContext(options:[.cacheIntermediates:false]);let cs=CGColorSpace(name:CGColorSpace.sRGB)!
  let shotRegions: [[(String,CGRect)]] = [
   [("blue left",CGRect(x:0.03,y:0.1,width:0.12,height:0.5)),("upper right wall",CGRect(x:0.84,y:0.08,width:0.12,height:0.24)),("lower right wall",CGRect(x:0.84,y:0.45,width:0.12,height:0.25)),("left floor",CGRect(x:0.02,y:0.85,width:0.15,height:0.12))],
   [("upper wall",CGRect(x:0.38,y:0.03,width:0.22,height:0.15)),("lower left wall",CGRect(x:0.02,y:0.48,width:0.12,height:0.20)),("right wall",CGRect(x:0.86,y:0.30,width:0.12,height:0.35)),("left floor",CGRect(x:0.02,y:0.88,width:0.14,height:0.10)),("upper left wall",CGRect(x:0.02,y:0.04,width:0.12,height:0.20))],
   [("upper left wall",CGRect(x:0.02,y:0.12,width:0.10,height:0.18)),("lower left wall",CGRect(x:0.02,y:0.6,width:0.08,height:0.15)),("upper blue",CGRect(x:0.44,y:0.04,width:0.25,height:0.14)),("right blue",CGRect(x:0.93,y:0.18,width:0.06,height:0.35)),("left floor",CGRect(x:0.02,y:0.87,width:0.12,height:0.11))],
   [("upper blue",CGRect(x:0.2,y:0.03,width:0.2,height:0.18)),("upper right wall",CGRect(x:0.78,y:0.03,width:0.16,height:0.10)),("lower right wall",CGRect(x:0.92,y:0.30,width:0.07,height:0.25)),("left blue",CGRect(x:0.18,y:0.4,width:0.12,height:0.25)),("left floor",CGRect(x:0.13,y:0.91,width:0.18,height:0.07))],
   [("upper wall",CGRect(x:0.38,y:0.04,width:0.22,height:0.16)),("upper right wall",CGRect(x:0.80,y:0.06,width:0.16,height:0.16)),("lower right wall",CGRect(x:0.8,y:0.48,width:0.16,height:0.22)),("left floor",CGRect(x:0.05,y:0.90,width:0.13,height:0.08)),("left blue",CGRect(x:0.02,y:0.12,width:0.1,height:0.30))]
  ]
  var frames:[[String:Any]]=[]
  while let sample=output.copyNextSampleBuffer() { try autoreleasepool {
   let image=CIImage(cvPixelBuffer:CMSampleBufferGetImageBuffer(sample)!)
   let cg=ctx.createCGImage(image,from:image.extent,format:.RGBA8,colorSpace:cs)!
   let w=cg.width,h=cg.height
   let bitmap=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   bitmap.draw(cg,in:CGRect(x:0,y:0,width:w,height:h))
   let bytes=bitmap.data!.assumingMemoryBound(to:UInt8.self)
   let index=frames.count,shot=index<11 ? 0:index<18 ? 1:index<38 ? 2:index<50 ? 3:4
   var regions:[[String:Any]]=[]
   var boxes=shotRegions[shot]
   if shot==1 { boxes += [("centre floor",CGRect(x:0.4,y:0.88,width:0.18,height:0.1)),("right floor",CGRect(x:0.84,y:0.88,width:0.14,height:0.1))] }
   for (name,rect) in boxes {
    var light=[Double](),rgb=[Double](repeating:0,count:3),nearWhite=0
    for y in Int(rect.minY*Double(h))..<Int(rect.maxY*Double(h)) { for x in Int(rect.minX*Double(w))..<Int(rect.maxX*Double(w)) {
     let p=(y*w+x)*4,r=Double(bytes[p]),g=Double(bytes[p+1]),b=Double(bytes[p+2])
     light.append(0.2126*r+0.7152*g+0.0722*b);rgb[0]+=r;rgb[1]+=g;rgb[2]+=b
     if max(r,g,b)>=250 { nearWhite+=1 }
    } }
    let count=Double(light.count);light.sort();rgb=rgb.map{$0/count}
    regions.append(["name":name,"rect":[rect.minX,rect.minY,rect.width,rect.height],"mean":light.reduce(0,+)/count,"p10":light[Int(count*0.1)],"p90":light[Int(count*0.9)],"rgb":rgb,"rg":rgb[0]/rgb[1],"bg":rgb[2]/rgb[1],"nearWhite":Double(nearWhite)/count])
   }
   frames.append(["frame":index,"time":CMSampleBufferGetPresentationTimeStamp(sample).seconds,"duration":CMSampleBufferGetDuration(sample).seconds.isFinite ? CMSampleBufferGetDuration(sample).seconds : -1,"regions":regions])
   let small=CGContext(data:nil,width:480,height:270,bitsPerComponent:8,bytesPerRow:480*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   small.draw(cg,in:CGRect(x:0,y:0,width:480,height:270))
   let dest=CGImageDestinationCreateWithURL(directory.appendingPathComponent("frame-\(index).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
   CGImageDestinationAddImage(dest,small.makeImage()!,nil);CGImageDestinationFinalize(dest)
  } }
  guard reader.status == .completed else { throw reader.error! }
  try JSONSerialization.data(withJSONObject:frames,options:.prettyPrinted).write(to:directory.appendingPathComponent("measurements.json"))
  print("Measured \(frames.count) native frames")
 }
}
