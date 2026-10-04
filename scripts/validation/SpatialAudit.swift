import SwiftUI
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CoreText
@main struct PatchAudit: App {
 @State private var status = "Ready"
 var body: some Scene { WindowGroup { VStack { Text(status); Button("Measure patches") { status = "Measuring…"; Task { do { try await Task.detached(priority: .userInitiated) { try await run() }.value; status = "Complete" } catch { status = "\(error)" } } } }.disabled(status == "Measuring…").padding(30).frame(width:650,height:160).task { status = "Measuring…"; do { try await Task.detached(priority: .userInitiated) { try await run() }.value; status = "Complete" } catch { status = "\(error)"; try? status.write(toFile: "/Users/sam/Documents/Development/VideoNormaliser/.build/audit/spatial-error.txt", atomically: true, encoding: .utf8) } } } }
 func run() async throws {
  let root = "/Users/sam/Documents/Development/VideoNormaliser/.build/audit/"
  func mark(_ text: String) { try? text.write(toFile: root + "spatial-progress.txt", atomically: true, encoding: .utf8) }
  mark("Analysing")
  let source = URL(fileURLWithPath: root + "source-input.mov")
  mark("Read bytes: \(try Data(contentsOf: source).count)")
  let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { value in mark("Analysing \(value)") })
  mark("Fitting fields")
  let cuts: Set<Int> = [11,18,38,50]
  let settings = Dictionary(uniqueKeysWithValues: ([0] + cuts.sorted()).map { ($0, SceneSettings()) })
  let curve = SceneCorrection.curve(base: analysis.samples, boundaries: cuts, settings: settings, references: [:])
  let destination = URL(fileURLWithPath: root + "spatial-final.mov")
  mark("Exporting")
  try? FileManager.default.removeItem(at: destination)
  try await VideoEngine.export(asset: AVURLAsset(url: source), curve: curve, destination: destination, progress: { _ in })
  try JSONSerialization.data(withJSONObject: ["stops":curve.stops, "cuts": SceneMath.boundaries(in: analysis.samples).sorted(), "cells": analysis.samples.map(\.cells)]).write(to: URL(fileURLWithPath: root + "spatial-final-analysis.json"))
  try JSONEncoder().encode(curve.spatial).write(to: URL(fileURLWithPath: root + "spatial-final-fields.json"))
  try JSONEncoder().encode(analysis.samples.map { $0.thumbnail! }).write(to: URL(fileURLWithPath: root + "spatial-final-thumbnails.json"))
  for index in [0,8,9,10,12,13,14,40,41,42,43,79,80,84,85] {
   let frame = try await VideoEngine.preview(url: destination, time: Double(index)/12, curve: .empty)
   let file = URL(fileURLWithPath: root + "spatial-final-\(index).png")
   let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)!
   CGImageDestinationAddImage(output,frame,nil); CGImageDestinationFinalize(output)
  }
  let paths = [source.path, root + "supplied-input.mov", destination.path]
  var reviewImages: [[CGImage]] = []
  let shotRegions: [[(String,CGRect)]] = [
   [("blue left",CGRect(x:0.03,y:0.1,width:0.12,height:0.5)),("upper right wall",CGRect(x:0.84,y:0.08,width:0.12,height:0.24)),("lower right wall",CGRect(x:0.84,y:0.45,width:0.12,height:0.25)),("left floor",CGRect(x:0.02,y:0.85,width:0.15,height:0.12))],
   [("upper wall",CGRect(x:0.38,y:0.03,width:0.22,height:0.15)),("lower left wall",CGRect(x:0.02,y:0.48,width:0.12,height:0.20)),("right wall",CGRect(x:0.86,y:0.30,width:0.12,height:0.35)),("left floor",CGRect(x:0.02,y:0.88,width:0.14,height:0.10)),("upper left wall",CGRect(x:0.02,y:0.04,width:0.12,height:0.20))],
   [("upper left wall",CGRect(x:0.02,y:0.12,width:0.10,height:0.18)),("lower left wall",CGRect(x:0.02,y:0.6,width:0.08,height:0.15)),("upper blue",CGRect(x:0.44,y:0.04,width:0.25,height:0.14)),("right blue",CGRect(x:0.93,y:0.18,width:0.06,height:0.35)),("left floor",CGRect(x:0.02,y:0.87,width:0.12,height:0.11))],
   [("upper blue",CGRect(x:0.2,y:0.03,width:0.2,height:0.18)),("upper right wall",CGRect(x:0.78,y:0.03,width:0.16,height:0.10)),("lower right wall",CGRect(x:0.92,y:0.30,width:0.07,height:0.25)),("left blue",CGRect(x:0.18,y:0.4,width:0.12,height:0.25)),("left floor",CGRect(x:0.13,y:0.91,width:0.18,height:0.07))],
   [("upper wall",CGRect(x:0.38,y:0.04,width:0.22,height:0.16)),("upper right wall",CGRect(x:0.80,y:0.06,width:0.16,height:0.16)),("lower right wall",CGRect(x:0.8,y:0.48,width:0.16,height:0.22)),("left floor",CGRect(x:0.05,y:0.90,width:0.13,height:0.08)),("left blue",CGRect(x:0.02,y:0.12,width:0.1,height:0.30))]
  ]
  let lut = (0...255).map { i -> Double in let x=Double(i)/255; return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4) }
  let ctx = CIContext(options:[.cacheIntermediates:false]); let cs=CGColorSpace(name:CGColorSpace.sRGB)!
  for (file,path) in paths.enumerated() {
   mark("Measuring file \(file)")
   let asset=AVURLAsset(url:URL(fileURLWithPath:path)); let track=try await asset.loadTracks(withMediaType:.video)[0]
   let preferred=try await track.load(.preferredTransform)
   let naturalSize=try await track.load(.naturalSize)
   let transform=VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:naturalSize)
   let reader=try AVAssetReader(asset:asset); let output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]); reader.add(output); reader.startReading()
   var frames:[[String:Any]]=[]
   var review:[CGImage]=[]
   while let sample=output.copyNextSampleBuffer() { autoreleasepool {
    let rawImage=CIImage(cvPixelBuffer:CMSampleBufferGetImageBuffer(sample)!)
    let im=rawImage.transformed(by:transform)
    if file != 1 {
     let thumb=rawImage.transformed(by:CGAffineTransform(scaleX:360/rawImage.extent.width,y:203/rawImage.extent.height))
     if let image=ctx.createCGImage(thumb,from:thumb.extent) { review.append(image) }
     if [12,13,14].contains(frames.count) {
      let large=rawImage.transformed(by:CGAffineTransform(scaleX:1600/rawImage.extent.width,y:900/rawImage.extent.height))
      if let image=ctx.createCGImage(large,from:large.extent) {
       let fileURL=URL(fileURLWithPath:root+"detail-\(file)-\(frames.count).png")
       let output=CGImageDestinationCreateWithURL(fileURL as CFURL,UTType.png.identifier as CFString,1,nil)!
       CGImageDestinationAddImage(output,image,nil);CGImageDestinationFinalize(output)
      }
     }
    }
    if frames.isEmpty {
     let description = "Colour space: \(String(describing: im.colorSpace))\nAttachments: \(String(describing: CVBufferCopyAttachments(CMSampleBufferGetImageBuffer(sample)!, .shouldPropagate)))"
     try? description.write(toFile: root + "colour-\(file).txt", atomically: true, encoding: .utf8)
    }
    let w=Int(im.extent.width), h=Int(im.extent.height), cols=24, rows=14
    var pixels=[UInt8](repeating:0,count:w*h*4)
    pixels.withUnsafeMutableBytes { ctx.render(im,toBitmap:$0.baseAddress!,rowBytes:w*4,bounds:im.extent,format:.RGBA8,colorSpace:cs) }
    var encoded=[Double](repeating:0,count:cols*rows), linear=encoded, counts=encoded
    var red=encoded, green=encoded, blue=encoded, linearRed=encoded, linearGreen=encoded, linearBlue=encoded
    for y in 0..<h { for x in 0..<w {
     let p=(y*w+x)*4; let t=min(rows-1,y*rows/h)*cols+min(cols-1,x*cols/w)
     let r=Int(pixels[p]),g=Int(pixels[p+1]),b=Int(pixels[p+2])
     encoded[t] += 0.2126*Double(r)+0.7152*Double(g)+0.0722*Double(b)
     linear[t] += 0.2126*lut[r]+0.7152*lut[g]+0.0722*lut[b]; counts[t] += 1
     red[t] += Double(r); green[t] += Double(g); blue[t] += Double(b)
     linearRed[t] += lut[r]; linearGreen[t] += lut[g]; linearBlue[t] += lut[b]
    } }
    let index=frames.count
    let shot = index<11 ? 0:index<18 ? 1:index<38 ? 2:index<50 ? 3:4
    var regions:[[String:Any]]=[]
    for (name,rect) in shotRegions[shot] {
     // Validation boxes are defined in the readable encoded landscape image.
     // Transform them to the same displayed coordinates as the image/masks.
     let rawRect=CGRect(x:rect.minX*naturalSize.width,y:rect.minY*naturalSize.height,width:rect.width*naturalSize.width,height:rect.height*naturalSize.height)
     let displayed=rawRect.applying(preferred)
     let x0=max(0,Int(displayed.minX)),x1=min(w,Int(displayed.maxX)),y0=max(0,Int(displayed.minY)),y1=min(h,Int(displayed.maxY))
     var channels=[Double](repeating:0,count:6),count=0.0,clipped=0.0,dark=0.0
     for y in y0..<y1 { for x in x0..<x1 {
      let p=(y*w+x)*4;let r=Int(pixels[p]),g=Int(pixels[p+1]),b=Int(pixels[p+2])
      channels[0]+=Double(r);channels[1]+=Double(g);channels[2]+=Double(b)
      channels[3]+=lut[r];channels[4]+=lut[g];channels[5]+=lut[b];count+=1
      if max(r,g,b)>=250 { clipped+=1 };if 0.2126*lut[r]+0.7152*lut[g]+0.0722*lut[b]<0.015 { dark+=1 }
     } }
     let m=channels.map { $0/max(1,count) }
     let nx=displayed.midX/Double(w),ny=displayed.midY/Double(h)
     let field=curve.spatial[index]
     let sx=min(23,max(0,Int(nx*24))),sy=min(13,max(0,Int(ny*14)))
     regions.append(["name":name,"sensorRect":[rect.minX,rect.minY,rect.width,rect.height],"displayRect":[displayed.minX/Double(w),displayed.minY/Double(h),displayed.width/Double(w),displayed.height/Double(h)],"rgb":Array(m[0..<3]),"linearRGB":Array(m[3..<6]),"luma":0.2126*m[0]+0.7152*m[1]+0.0722*m[2],"linearLuma":0.2126*m[3]+0.7152*m[4]+0.0722*m[5],"clippedFraction":clipped/max(1,count),"darkFraction":dark/max(1,count),"confidenceAtCentre":field.confidence[sy*24+sx]])
    }
    frames.append(["regions":regions,"time":CMSampleBufferGetPresentationTimeStamp(sample).seconds,"luma":zip(encoded,counts).map(/),"linear":zip(linear,counts).map(/), "red":zip(red,counts).map(/), "green":zip(green,counts).map(/), "blue":zip(blue,counts).map(/), "linearRed":zip(linearRed,counts).map(/), "linearGreen":zip(linearGreen,counts).map(/), "linearBlue":zip(linearBlue,counts).map(/)])
   } }
   reviewImages.append(review)
   if reader.status == .failed { throw reader.error! }
   try JSONSerialization.data(withJSONObject:frames).write(to:URL(fileURLWithPath:root+"spatial-final-patches-\(file).json"))
  }
  for first in stride(from:0,to:86,by:10) {
   let count=min(10,86-first),width=720,height=count*220
   let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
   context.setFillColor(CGColor(gray:0.08,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
   for offset in 0..<count {
    let y=height-(offset+1)*220
    for (column,file) in [0,2].enumerated() {
     context.draw(reviewImages[file][first+offset],in:CGRect(x:column*360,y:y+17,width:360,height:203))
     let text=NSAttributedString(string:"Frame \(first+offset) · \(file==0 ? "Source":"Spatial candidate")",attributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.white])
     context.textPosition=CGPoint(x:column*360+8,y:y+3);CTLineDraw(CTLineCreateWithAttributedString(text),context)
    }
   }
   let file=URL(fileURLWithPath:root+"review-\(first).png")
   let output=CGImageDestinationCreateWithURL(file as CFURL,UTType.png.identifier as CFString,1,nil)!
   CGImageDestinationAddImage(output,context.makeImage()!,nil);CGImageDestinationFinalize(output)
  }
 }
}
