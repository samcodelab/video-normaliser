// Bounded source-only fine-scale geometry/photometry diagnostic. Never authorizes correction.
import Foundation
import AVFoundation
import CoreImage

@main struct NativeRegionalSurfaceAudit {
    static func main() async throws {
        let args = CommandLine.arguments
        guard (args.count == 11 || (args.count == 13 && args[11] == "--diagnostics")),let first = Int(args[2]),let end = Int(args[3]),let event = Int(args[4]),
              let width = Int(args[5]),let left = Int(args[6]),let bottom = Int(args[7]),let columns = Int(args[8]),let rows = Int(args[9]),
              first >= 0,first < event,event+1 < end,(96...768).contains(width),width%96 == 0,
              left >= 0,bottom >= 0,columns >= 5,rows >= 5,left+columns <= 96,bottom+rows <= 56 else {
            throw VideoError.message("Usage: source first end-exclusive event analysis-width left top columns rows output.json (ROI in 96x56 analysis coordinates)")
        }
        let destination = URL(fileURLWithPath:args[10])
        guard !FileManager.default.fileExists(atPath:destination.path),end-first <= 17 else {throw VideoError.message("Fresh output and bounded interval required")}
        let scale = width/96,height = 56*scale,x0 = left*scale,y0 = bottom*scale,w = columns*scale,h = rows*scale
        guard w*h <= 65536 else {throw VideoError.message("ROI exceeds bounded descriptor budget")}
        let asset = AVURLAsset(url:URL(fileURLWithPath:args[1]))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No video")}
        let preferred = try await track.load(.preferredTransform),natural = try await track.load(.naturalSize)
        let transform = VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:natural)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false;reader.add(output)
        guard reader.startReading() else {throw reader.error ?? VideoError.message("Decode failed")}
        defer {reader.cancelReading()}
        let areaResampling = ProcessInfo.processInfo.environment["FRANKLUMA_AREA_RESAMPLING_PROBE"] == "1"
        let linear = CGColorSpace(name:CGColorSpace.linearSRGB)!
        let context = CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
        var frames:[SpatialThumbnail] = [],times:[Double] = [],index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer {index += 1}
            if index >= end {break}
            guard index >= first else {continue}
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {throw VideoError.message("Missing pixel buffer")}
            let frame = CIImage(cvPixelBuffer:buffer).transformed(by:transform),extent = frame.extent
            let small = frame.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
                .applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:Double(height)/extent.height,kCIInputAspectRatioKey:Double(width)/extent.width/(Double(height)/extent.height)])
            // Extract by bitmap row index from one full-frame render. This
            // removes crop-origin conversion and tile-dependent resampling.
            var whole = [Float](repeating:0,count:width*height*4)
            whole.withUnsafeMutableBytes {context.render(small,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:linear)}
            if areaResampling {
                let native=frame.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
                let nw=Int(extent.width.rounded()),nh=Int(extent.height.rounded())
                guard nw > 0,nh > 0,nw*nh <= 40_000_000 else {throw VideoError.message("Native raster budget exceeded")}
                var raster=[Float](repeating:0,count:nw*nh*4)
                raster.withUnsafeMutableBytes {context.render(native,toBitmap:$0.baseAddress!,rowBytes:nw*16,bounds:CGRect(x:0,y:0,width:nw,height:nh),format:.RGBAf,colorSpace:linear)}
                let sx=Double(nw)/Double(width),sy=Double(nh)/Double(height)
                for y in 0..<height {for x in 0..<width {
                    let loX=Double(x)*sx,hiX=Double(x+1)*sx,loY=Double(y)*sy,hiY=Double(y+1)*sy
                    var sums=[Double](repeating:0,count:4)
                    for py in Int(floor(loY))..<min(nh,Int(ceil(hiY))) {
                        let wy=max(0,min(hiY,Double(py+1))-max(loY,Double(py)))
                        for px in Int(floor(loX))..<min(nw,Int(ceil(hiX))) {
                            let weight=wy*max(0,min(hiX,Double(px+1))-max(loX,Double(px)))
                            for c in 0..<4 {sums[c] += weight*Double(raster[(py*nw+px)*4+c])}
                        }
                    }
                    for c in 0..<4 {whole[(y*width+x)*4+c]=Float(sums[c]/(sx*sy))}
                }}
            }
            var rgba = [Float](repeating:0,count:w*h*4)
            for y in 0..<h {for x in 0..<w {for c in 0..<4 {
                rgba[(y*w+x)*4+c] = whole[((y+y0)*width+x+x0)*4+c]
            }}}
            if frames.isEmpty {print("ROI_EXTRACTED_FROM_FULL_RASTER",x0,y0,w,h)}
            let rgb = (0..<w*h*3).map {rgba[($0/3)*4+$0%3]}
            frames.append(.init(width:w,height:h,rgb:rgb));times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard frames.count == end-first else {throw reader.error ?? VideoError.message("Incomplete interval")}
        var rendered = frames
        if args.count == 13 {
            let folder = URL(fileURLWithPath:args[12]),decoder = JSONDecoder()
            let fields = try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
            let stops = try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
            guard fields.count >= end,stops.count >= end,(first..<end).allSatisfy({fields[$0].surface != nil}) else {throw VideoError.message("Missing fields")}
            rendered = frames.enumerated().map { i,frame in
                var rgb = frame.rgb
                for y in 0..<h {for x in 0..<w {
                    let p = (y*w+x)*3,index = first+i
                    let value = SpatialRenderer.surfaceRGB((0..<3).map {Double(frame.rgb[p+$0])},x:(Double(x0+x)+0.5)/Double(width),y:(Double(y0+y)+0.5)/Double(height),map:fields[index].surface!,global:stops[index]+(fields[index].brightnessEV ?? 0))
                    for c in 0..<3 {rgb[p+c] = Float(value[c])}
                }}
                return SpatialThumbnail(width:w,height:h,rgb:rgb)
            }
        }
        let affineGeometry = ProcessInfo.processInfo.environment["FRANKLUMA_AFFINE_GEOMETRY_PROBE"] == "1"
        let prepared = frames.map { frame -> SurfaceTracking.Prepared in
            guard affineGeometry else {return SurfaceTracking.Prepared(frame)}
            // Diagnostic only: reuse reciprocal matcher on linear-Y texture.
            // The exponential cancels its logarithm; source photometry below
            // still uses the unmodified decoded RGB, never this surrogate.
            let rgb=(0..<(frame.width*frame.height)).flatMap { i -> [Float] in
                let p=i*3,y=0.2126*Double(frame.rgb[p])+0.7152*Double(frame.rgb[p+1])+0.0722*Double(frame.rgb[p+2])
                let v=Float(pow(2,4*y));return [v,v,v]
            }
            return SurfaceTracking.Prepared(.init(width:frame.width,height:frame.height,rgb:rgb))
        },anchor = event-first
        var rowsOut:[[String:Any]] = [],rejected:[String:Int] = [:],seeds = 0
        func pixels(_ frame:SpatialThumbnail,_ point:SurfaceTracking.Observation) -> [Double]? {
            let x = Double(point.x)+point.offsetX,y = Double(point.y)+point.offsetY,ix = Int(floor(x)),iy = Int(floor(y)),fx = x-Double(ix),fy = y-Double(iy)
            guard ix >= 2,iy >= 2,ix+3 < w,iy+3 < h else {return nil}
            var values:[Double] = []
            for dy in -2...2 {for dx in -2...2 {for c in 0..<3 {
                let p = ((iy+dy)*w+ix+dx)*3+c
                let a = Double(frame.rgb[p])*(1-fx)+Double(frame.rgb[p+3])*fx
                let b = Double(frame.rgb[p+w*3])*(1-fx)+Double(frame.rgb[p+w*3+3])*fx
                values.append(a*(1-fy)+b*fy)
            }}}
            return values
        }
        // Five-by-five meter and existing reciprocal descriptor matching; physical
        // extent intentionally shrinks at finer resolutions. No gain-field fitting.
        for y in stride(from:7,to:h-7,by:8) {for x in stride(from:7,to:w-7,by:8) {
            seeds += 1
            let trajectory = SurfaceTracking.trajectoryThrough(prepared,segments:Array(repeating:0,count:frames.count),anchor:anchor,x:x,y:y,radius:8)
            guard trajectory.count >= 4,trajectory.allSatisfy({$0.confidence > 0}),
                  let a = trajectory.first(where:{$0.frame == anchor-1}),let b = trajectory.first(where:{$0.frame == anchor}),let c = trajectory.first(where:{$0.frame == anchor+1}) else {rejected["geometry",default:0] += 1;continue}
            let source = [a,b,c].compactMap {pixels(frames[$0.frame],$0)}
            guard source.count == 3 else {rejected["footprint",default:0] += 1;continue}
            let alpha = (times[anchor]-times[anchor-1])/(times[anchor+1]-times[anchor-1])
            let pulse = CommonIlluminationComponent.pulsePixels(before:source[0],middle:source[1],after:source[2],alpha:alpha,tolerance:0.04)
            let step = CommonIlluminationComponent.stepPixels(before:source[0],after:source[1])
            if let reason = pulse.rejection {rejected[reason,default:0] += 1}
            let pulseY = CommonIlluminationComponent.pulseLuminancePixels(before:source[0],middle:source[1],after:source[2],alpha:alpha,tolerance:0.04)
            let stepY = CommonIlluminationComponent.pulseLuminancePixels(before:source[0],middle:source[1],after:source[0],alpha:0.5,tolerance:0.04)
            for (name,condition) in [("negativeRGB",source.contains {$0.contains {$0 < 0}}),("nearClippedRGB",source.contains {$0.contains {$0 >= 0.95}}),("nonfiniteRGB",source.contains {$0.contains {!$0.isFinite}})] where condition {
                rejected["raw:"+name,default:0] += 1
            }
            let plane = CommonIlluminationComponent.pulsePlaneLuminancePixels(before:source[0],middle:source[1],after:source[2],alpha:alpha,tolerance:0.04)
            if let reason = plane.rejection {rejected["plane:"+reason,default:0] += 1}
            let affine = CommonIlluminationComponent.pulseLinearLuminancePixels(before:source[0],middle:source[1],after:source[2],alpha:alpha,tolerance:0.04,reference:.arithmeticRadiance)
            if let reason = affine.rejection {rejected["arithmeticAffine:"+reason,default:0] += 1}
            if let reason = stepY.rejection {rejected["stepY:"+reason,default:0] += 1}
            if pulse.rejection == nil || step.rejection == nil || pulseY.rejection == nil || stepY.rejection == nil || affine.rejection == nil || plane.rejection == nil {
                let result = [a,b].compactMap {pixels(rendered[$0.frame],$0)}
                func ev(_ rgb:[Double]) -> Double {
                    log2(max(1e-9,(0..<25).reduce(0.0) {$0+0.2126*rgb[$1*3]+0.7152*rgb[$1*3+1]+0.0722*rgb[$1*3+2]}/25))
                }
                let outputStep = result.count == 2 ? ev(result[1])-ev(result[0]) : 0
                rowsOut.append(["planeRejection":plane.rejection as Any? ?? NSNull(),"planeCoefficients":plane.coefficients,"arithmeticAffineRejection":affine.rejection as Any? ?? NSNull(),"arithmeticAffineGain":affine.gain as Any? ?? NSNull(),"arithmeticAffineOffset":affine.offset as Any? ?? NSNull(),"outputMeanLuminanceStepEV":outputStep,"analysisX":x+x0,"analysisY":y+y0,"normalisedX":Double(x+x0)/Double(width),"normalisedY":Double(y+y0)/Double(height),"pulseY":pulseY.channelExcursion,"pulseYRejection":pulseY.rejection as Any? ?? NSNull(),"stepY":stepY.channelExcursion,"stepYRejection":stepY.rejection as Any? ?? NSNull(),"persistentFrames":trajectory.count,"pulseRGB":pulse.channelExcursion,"pulseRejection":pulse.rejection as Any? ?? NSNull(),"stepRGB":step.channelExcursion,"stepRejection":step.rejection as Any? ?? NSNull(),"geometryConfidence":trajectory.map(\.confidence).min()!])
            }
        }}
        let report:[String:Any] = ["areaResamplingProbe":areaResampling,"affineGeometryProbe":affineGeometry,"source":args[1],"first":first,"endExclusive":end,"event":event,"hasRetainedCorrection":args.count == 13,"analysisWidth":width,"analysisHeight":height,"roi":[x0,y0,w,h],"roiOrigin":"top-left bitmap rows, checked against full-frame raster","times":times,"seeds":seeds,"rows":rowsOut,"rejections":rejected,"limitation":"Source-only bounded ROI diagnostic, actual decoded PTS. Fixed five-pixel photometry and geometry supports shrink physically at finer analysis resolutions; these results isolate no single resolution effect. No disjoint donor certification, native support independence, clean target, rendered gain fit or correction authorization. Tracks and meter footprints can overlap." ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.withoutOverwriting)
        print("FINE_SURFACE",width,"plane",rowsOut.filter {$0["planeRejection"] is NSNull}.count,"arithmeticAffine",rowsOut.filter {$0["arithmeticAffineRejection"] is NSNull}.count,"seeds",seeds,"pulse",rowsOut.filter {$0["pulseRejection"] is NSNull}.count,"step",rowsOut.filter {$0["stepRejection"] is NSNull}.count,"stepY",rowsOut.filter {$0["stepYRejection"] is NSNull}.count,"pulseY",rowsOut.filter {$0["pulseYRejection"] is NSNull}.count,"rejections",rejected)
    }
}
