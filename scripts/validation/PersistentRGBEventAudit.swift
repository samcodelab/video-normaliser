// Source-selected persistent RGB footprints. This audit does not authorize correction.
import Foundation

@main struct PersistentRGBEventAudit {
    static func main() throws {
        let args = CommandLine.arguments
        guard (args.count == 7 || (args.count == 8 && args[7] == "--anchor-event")),let first = Int(args[2]),let end = Int(args[3]),let event = Int(args[4]),let fps = Double(args[5]),fps > 0 else {
            throw VideoError.message("Usage: diagnostics first end-exclusive event-frame fps report.json [--anchor-event]")
        }
        let folder = URL(fileURLWithPath:args[1]),decoder = JSONDecoder()
        let images = try decoder.decode([SpatialThumbnail].self,from:Data(contentsOf:folder.appendingPathComponent("thumbnails.json")))
        let fields = try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
        let stops = try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
        guard first >= 0,end <= images.count,first < event,event+1 < end,images.count == fields.count,images.count == stops.count else { throw VideoError.message("Invalid single-scene interval") }
        let frames = Array(images[first..<end]),prepared = frames.map {SurfaceTracking.Prepared($0)}
        let corrected = (first..<end).map { i -> SpatialThumbnail in
            let image = images[i];guard let map = fields[i].surface else { return image }
            var rgb = [Float](repeating:0,count:image.rgb.count)
            for y in 0..<image.height {for x in 0..<image.width {
                let p = (y*image.width+x)*3
                let value = SpatialRenderer.surfaceRGB((0..<3).map {Double(image.rgb[p+$0])},x:(Double(x)+0.5)/Double(image.width),y:(Double(y)+0.5)/Double(image.height),map:map,global:stops[i]+(fields[i].brightnessEV ?? 0))
                for c in 0..<3 {rgb[p+c] = Float(value[c])}
            }}
            return SpatialThumbnail(width:image.width,height:image.height,rgb:rgb)
        }
        func pixels(_ image: SpatialThumbnail,_ point: SurfaceTracking.Observation) -> [Double]? {
            let x = Double(point.x)+point.offsetX,y = Double(point.y)+point.offsetY
            let ix = Int(floor(x)),iy = Int(floor(y)),fx = x-Double(ix),fy = y-Double(iy)
            guard ix >= 2,iy >= 2,ix+3 < image.width,iy+3 < image.height else {return nil}
            var values:[Double] = []
            for dy in -2...2 {for dx in -2...2 {for c in 0..<3 {
                let p = ((iy+dy)*image.width+ix+dx)*3+c
                let top = Double(image.rgb[p])*(1-fx)+Double(image.rgb[p+3])*fx
                let bottom = Double(image.rgb[p+image.width*3])*(1-fx)+Double(image.rgb[p+image.width*3+3])*fx
                values.append(top*(1-fy)+bottom*fy)
            }}}
            return values
        }
        func levels(_ values:[Double]) -> [Double] {
            (0..<3).map {c in log2(max(1e-9,(0..<25).reduce(0.0) {$0+values[$1*3+c]}/25))}
        }
        var stepRows:[[String:Any]] = [],stepRejections:[String:Int] = [:]
        var rows:[[String:Any]] = [],rejections:[String:Int] = [:],seeds = 0
        let local = event-first,anchorEvent = args.count == 8
        for y in stride(from:7,to:frames[0].height-7,by:8) {for x in stride(from:7,to:frames[0].width-7,by:8) {
            seeds += 1
            let segments = Array(repeating:0,count:frames.count)
            let track = anchorEvent ? SurfaceTracking.trajectoryThrough(prepared,segments:segments,anchor:local,x:x,y:y) : SurfaceTracking.trajectory(prepared,segments:segments,start:0,x:x,y:y)
            guard track.count >= 4,track.allSatisfy({$0.confidence > 0}),
                  let a = track.first(where:{$0.frame == local-1}),let b = track.first(where:{$0.frame == local}),let c = track.first(where:{$0.frame == local+1}) else {rejections["insufficientPersistentGeometry",default:0] += 1;continue}
            let points = [a,b,c]
            let source = points.compactMap {pixels(frames[$0.frame],$0)}
            guard source.count == 3 else {rejections["invalidFootprint",default:0] += 1;continue}
            let step = CommonIlluminationComponent.stepPixels(before:source[0],after:source[1])
            if let reason = step.rejection {stepRejections[reason,default:0] += 1}
            else {stepRows.append(["seedX":x,"seedY":y,"eventX":Double(b.x)+b.offsetX,"eventY":Double(b.y)+b.offsetY,"sourceRGBStepEV":step.channelExcursion,"heldRGBErrorEV":step.heldError])}
            let evidence = CommonIlluminationComponent.pulsePixels(before:source[0],middle:source[1],after:source[2],alpha:0.5,tolerance:0.04)
            if let reason = evidence.rejection {rejections[reason,default:0] += 1;continue}
            let output = points.compactMap {pixels(corrected[$0.frame],$0)}
            guard output.count == 3 else {rejections["invalidOutputFootprint",default:0] += 1;continue}
            let sl = source.map(levels),ol = output.map(levels)
            let sc = (0..<3).map {sl[1][$0]-(sl[0][$0]+sl[2][$0])/2}
            let oc = (0..<3).map {ol[1][$0]-(ol[0][$0]+ol[2][$0])/2}
            rows.append(["seedX":x,"seedY":y,"eventX":Double(b.x)+b.offsetX,"eventY":Double(b.y)+b.offsetY,
                         "persistentFrames":track.count,"minimumGeometryConfidence":track.map(\.confidence).min()!,
                         "heldRGBErrorEV":evidence.heldError,"sourceRGBCurvatureEV":sc,"outputRGBCurvatureEV":oc,
                         "sourceRGBStepEV":(0..<3).map {sl[1][$0]-sl[0][$0]},"outputRGBStepEV":(0..<3).map {ol[1][$0]-ol[0][$0]}])
        }}
        let report:[String:Any] = ["anchorEvent":anchorEvent,"firstFrame":first,"endExclusive":end,"eventFrame":event,"fps":fps,"seeds":seeds,"rows":rows,"rejections":rejections,"stepRows":stepRows,"stepRejections":stepRejections,
            "limitation":"Thumbnail diagnostic with source-only geometric tracking and held RGB response tests. Overlapping seeds are not independent donors. Source response uniformity is not proof of lighting rather than changing material; no donor clock, correction authorization or clean-light target is inferred. Intervals must be within one scene; nominal CFR timing supplied explicitly. No interpolation across track gaps."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[6]),options:.withoutOverwriting)
        print("Persistent RGB event",event,"qualified",rows.count,"stepQualified",stepRows.count,"of",seeds,"rejections",rejections)
    }
}
