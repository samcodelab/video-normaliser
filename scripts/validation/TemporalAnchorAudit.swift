import Foundation

@main struct TemporalAnchorAudit {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6,let first = Int(args[3]),let frame = Int(args[4]) else {
            throw NSError(domain: "TemporalAnchorAudit",code: 1)
        }
        let images = try JSONDecoder().decode([SpatialThumbnail].self,from: Data(contentsOf: URL(fileURLWithPath:args[1])))
        let tracking = try JSONSerialization.jsonObject(with: Data(contentsOf:URL(fileURLWithPath:args[2]))) as! [String:Any]
        let tracks = tracking["tracks"] as! [[String:Any]]
        let current = SurfaceTracking.Prepared(images[frame])
        let references = [frame-8,frame-6,frame-4,frame-2,frame-1,frame+1,frame+2,frame+4].filter { images.indices.contains($0) }
        let prepared = Dictionary(uniqueKeysWithValues:references.map { ($0,SurfaceTracking.Prepared(images[$0])) })
        var rows = [[String:Any]]()
        for (index,track) in tracks.enumerated() {
            let observations = track["observations"] as! [[String:Any]]
            guard let point = observations.first,point["frame"] as! Int == frame-first else { continue }
            let x = point["x"] as! Int,y = point["y"] as! Int
            let observation = SurfaceTracking.Observation(frame:frame,x:x,y:y,channelLevels:current.lighting(x:x,y:y)!,confidence:1)
            var matches = [[String:Any]]()
            for reference in references {
                guard let target = prepared[reference],let match = SurfaceTracking.match(current,target,x:x,y:y,radius:8) else { continue }
                matches.append(["referenceFrame":reference,"x":match.x,"y":match.y,
                    "offsetX":match.offsetX,"offsetY":match.offsetY,"channelEV":match.channelEV,
                    "confidence":match.confidence,"photometricConfidence":match.photometricConfidence,
                    "wideIdentity":SurfaceTracking.localMeasurementIdentity(current,target,point:observation,match:match)])
            }
            rows.append(["track":index,"x":x,"y":y,"matches":matches])
        }
        let destination = URL(fileURLWithPath:args[5])
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw NSError(domain:"TemporalAnchorAudit",code:2) }
        let result:[String:Any] = ["sourceFrame":frame,"references":references,"tracks":rows,
            "status":"Diagnostic only; direct nonadjacent matches are not yet cross-reference validated or used in correction."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:destination)
        print("TEMPORAL ANCHORS",rows.count,"new tracks")
    }
}
