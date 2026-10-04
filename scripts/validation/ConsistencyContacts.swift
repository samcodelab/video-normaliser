import AppKit
import ImageIO
import UniformTypeIdentifiers
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let out=URL(fileURLWithPath:CommandLine.arguments[2])
let cs=CGColorSpace(name:CGColorSpace.sRGB)!
for start in stride(from:0,to:86,by:12) {
 let ctx=CGContext(data:nil,width:1920,height:1740,bitsPerComponent:8,bytesPerRow:1920*4,space:cs,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.setFillColor(CGColor(gray:0.08,alpha:1));ctx.fill(CGRect(x:0,y:0,width:1920,height:1740))
 for index in start..<min(start+12,86) {
  let position=index-start,x=(position%2)*960,y=1740-(position/2+1)*290
  for (c,kind) in ["before","after"].enumerated() {
   let path=root.appendingPathComponent("movie-\(kind)/frame-\(index).png")
   let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(path as CFURL,nil)!,0,nil)!
   ctx.draw(image,in:CGRect(x:x+c*480,y:y+20,width:480,height:270))
   let text=NSAttributedString(string:"Frame \(index+1) · \(kind)",attributes:[.font:NSFont.monospacedSystemFont(ofSize:13,weight:.regular),.foregroundColor:NSColor.white])
   ctx.textPosition=CGPoint(x:x+c*480+8,y:y+4);CTLineDraw(CTLineCreateWithAttributedString(text),ctx)
  }
 }
 let dest=CGImageDestinationCreateWithURL(out.appendingPathComponent("contact-\(start).png") as CFURL,UTType.png.identifier as CFString,1,nil)!
 CGImageDestinationAddImage(dest,ctx.makeImage()!,nil);CGImageDestinationFinalize(dest)
}
