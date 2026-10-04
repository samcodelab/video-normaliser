// Deterministic, original geometric stop-motion demo; no third-party media.
import AppKit
import AVFoundation
import CoreVideo
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360])
writer.add(input)
guard writer.startWriting() else { fatalError("Cannot start demo writer") }
writer.startSession(atSourceTime: .zero)
for frame in 0..<96 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32ARGB, [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let gain = [1.0,0.78,1.05,0.9,1.12,0.83,1.0,0.94][frame % 8]
    func fill(_ r: Double, _ g: Double, _ b: Double, _ rect: CGRect) {
        ctx.setFillColor(CGColor(red:r*gain,green:g*gain,blue:b*gain,alpha:1));ctx.fill(rect)
    }
    fill(0.35,0.39,0.44,CGRect(x:0,y:0,width:640,height:360))
    for row in 0..<6 { for col in 0..<10 {
        let tone = 0.32 + Double((row*3+col)%7)*0.025
        fill(tone,tone+0.025,tone+0.05,CGRect(x:col*70-(row%2)*35+2,y:row*60+2,width:66,height:56))
    } }
    fill(0.21,0.24,0.28,CGRect(x:0,y:0,width:640,height:65))
    let x=50+Double(frame/3)*13
    fill(0.65,0.27,0.16,CGRect(x:x,y:65,width:65,height:90))
    fill(0.15,0.5,0.6,CGRect(x:470,y:65,width:85,height:65))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    guard adaptor.append(pixel, withPresentationTime: CMTime(value:Int64(frame),timescale:24)) else { fatalError("Cannot write demo") }
}
input.markAsFinished()
let semaphore=DispatchSemaphore(value:0)
writer.finishWriting { semaphore.signal() }
semaphore.wait()
guard writer.status == .completed else { fatalError("Demo encoding failed") }
print("Generated original four-second SDR demo")
