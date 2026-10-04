// Package the approved master into the ten macOS AppIcon raster sizes.
// Usage: swift scripts/generate-app-icon.swift master.png AppIcon.appiconset
import AppKit
import ImageIO
import UniformTypeIdentifiers
let args=CommandLine.arguments
 guard args.count==3 else { fatalError("Usage: generate-app-icon.swift master.png AppIcon.appiconset") }
let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:args[1]) as CFURL,nil)!
let master=CGImageSourceCreateImageAtIndex(source,0,nil)!
let directory=URL(fileURLWithPath:args[2])
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
var entries:[[String:String]]=[]
for size in [16,32,128,256,512] { for scale in [1,2] {
    let pixels=size*scale
    let ctx=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(master,in:CGRect(x:0,y:0,width:pixels,height:pixels))
    let name="icon_\(size)x\(size)@\(scale)x.png"
    let output=CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(output,ctx.makeImage()!,nil);CGImageDestinationFinalize(output)
    entries.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
} }
try JSONSerialization.data(withJSONObject:["images":entries,"info":["author":"xcode","version":1]],options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("Contents.json"))
