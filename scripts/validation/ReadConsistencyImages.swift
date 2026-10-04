import Foundation
import ImageIO
import CoreGraphics
for path in CommandLine.arguments.dropFirst() {
 let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil)!,0,nil)!
 let w=image.width,h=image.height
 let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
 try Data(bytes:ctx.data!,count:w*h*4).write(to:URL(fileURLWithPath:path+".rgba"))
 print(path,w,h)
}
