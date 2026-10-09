// Measure actual encoded brightness on source-selected matched footprints.
// Correspondence is selected from source only, never from corrected pixels.
import Foundation
@main struct MatchedSurfaceAudit {
 static func meanLuminance(_ image: SpatialThumbnail,x: Double,y: Double) -> Double {
  let ix = Int(x),iy = Int(y),fx = x-Double(ix),fy = y-Double(iy)
  var result = 0.0
  for dy in -6...6 { for dx in -6...6 {
   let p = ((iy+dy)*image.width+ix+dx)*3
   let right = ((iy+dy)*image.width+min(image.width-1,ix+dx+1))*3
   let bottomIndex = (min(image.height-1,iy+dy+1)*image.width+ix+dx)*3
   let bottomRight = (min(image.height-1,iy+dy+1)*image.width+min(image.width-1,ix+dx+1))*3
   let weights = [0.2126,0.7152,0.0722]
   for c in 0..<3 {
    let top = Double(image.rgb[p+c])*(1-fx)+Double(image.rgb[right+c])*fx
    let bottom = Double(image.rgb[bottomIndex+c])*(1-fx)+Double(image.rgb[bottomRight+c])*fx
    result += weights[c]*max(0,top*(1-fy)+bottom*fy)/169
   }
  } }
  return max(0.000001,result)
 }
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count == 6 else { throw VideoError.message("Usage: source corrected first-frame second-frame report.json; or all adjacent") }
  let batch = args[3] == "all" && args[4] == "adjacent"
  guard batch || (Int(args[3]) != nil && Int(args[4]) != nil) else { throw VideoError.message("Invalid frame selection") }
  let source = try await VideoEngine.analyse(url: URL(fileURLWithPath: args[1]),region: nil,progress: { _ in })
  let corrected = try await VideoEngine.analyse(url: URL(fileURLWithPath: args[2]),region: nil,progress: { _ in })
  guard source.samples.count == corrected.samples.count else { throw VideoError.message("Frame count mismatch") }
  let pairs = batch ? (1..<source.samples.count).map { ($0-1,$0) } : [(Int(args[3])!,Int(args[4])!)]
  var reports = [[String:Any]]()
  for (first,second) in pairs {
  guard source.samples.indices.contains(first),source.samples.indices.contains(second) else { throw VideoError.message("Frame index out of bounds") }
  if source.samples[first].segment != source.samples[second].segment {
   if batch { continue }
   throw VideoError.message("Comparison crosses a source cut")
  }
  guard
   let a = source.samples[first].thumbnail,let b = source.samples[second].thumbnail,
   let outputA = corrected.samples[first].thumbnail,let outputB = corrected.samples[second].thumbnail else { throw VideoError.message("Missing thumbnail") }
  let camera = SurfaceMotion.estimate(SurfaceMotion.coarse(a),SurfaceMotion.coarse(b))
  let model = camera ?? SurfaceMotion.Model(x: [1,0,0],y: [0,1,0])
  var rows = [[String:Any]]()
  for y in stride(from: 6,to: a.height-6,by: 8) { for x in stride(from: 6,to: a.width-6,by: 8) {
   let q = model.point(Double(x),Double(y))
   guard let original = SurfaceTracking.descriptor(a,x: x,y: y,half: 6),
    let matched = SurfaceTracking.descriptor(b,x: q.0,y: q.1,half: 6),original.energy > 0.03,matched.energy > 0.03,
    let renderedA = SurfaceTracking.descriptor(outputA,x: x,y: y,half: 6),
    let renderedB = SurfaceTracking.descriptor(outputB,x: q.0,y: q.1,half: 6) else { continue }
   let correlation = zip(original.texture,matched.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(original.texture.count)*original.energy*matched.energy)
   guard correlation > 0.95 else { continue }
   let input: [Double] = zip(matched.mean,original.mean).map { $0.0-$0.1 }
   let output: [Double] = zip(renderedB.mean,renderedA.mean).map { $0.0-$0.1 }
   var row: [String:Any] = ["x":x,"y":y,"matchedX":q.0,"matchedY":q.1,"sourceTextureCorrelation":correlation]
   row["sourceChannelStepEV"] = input; row["outputChannelStepEV"] = output
   row["sourceMeanChannelStepEV"] = input.reduce(0,+)/3
   row["outputMeanChannelStepEV"] = output.reduce(0,+)/3
   row["sourceLumaStepEV"] = log2(meanLuminance(b,x: q.0,y: q.1)/meanLuminance(a,x: Double(x),y: Double(y)))
   row["outputLumaStepEV"] = log2(meanLuminance(outputB,x: q.0,y: q.1)/meanLuminance(outputA,x: Double(x),y: Double(y)))
   rows.append(row)
  } }
  let sourceSteps = rows.map { $0["sourceMeanChannelStepEV"] as! Double },outputSteps = rows.map { $0["outputMeanChannelStepEV"] as! Double }
  var report: [String:Any] = ["source":args[1],"corrected":args[2],"frames":[first,second],"sourceSelectedMatchedFootprints":rows,
   "supportedFootprints":rows.count,"cameraModelFound":camera != nil,"sourceMedianSignedStepEV":sourceSteps.isEmpty ? NSNull() : ExposureMath.median(sourceSteps),
   "outputMedianSignedStepEV":outputSteps.isEmpty ? NSNull() : ExposureMath.median(outputSteps),
   "sourceMedianAbsoluteStepEV":sourceSteps.isEmpty ? NSNull() : ExposureMath.median(sourceSteps.map(abs)),
   "outputMedianAbsoluteStepEV":outputSteps.isEmpty ? NSNull() : ExposureMath.median(outputSteps.map(abs)),
   "limitation":"Source-selected 13x13 log-RGB footprints follow fitted camera geometry. Residual reflectance, deformation, occlusion or registration errors remain possible. No clean lighting reference or perceptual guarantee."]
  let inputLuma = rows.map { $0["sourceLumaStepEV"] as! Double }
  let outputLuma = rows.map { $0["outputLumaStepEV"] as! Double }
  report["sourceMedianAbsoluteLumaStepEV"] = inputLuma.isEmpty ? NSNull() : ExposureMath.median(inputLuma.map(abs))
  report["outputMedianAbsoluteLumaStepEV"] = outputLuma.isEmpty ? NSNull() : ExposureMath.median(outputLuma.map(abs))
  reports.append(report)
  }
  let payload: Any = batch ? ["source":args[1],"corrected":args[2],"transitions":reports,"selection":"Source texture only; cuts excluded; identity fallback requires matching fixed texture", "supportedTransitions":reports.filter { ($0["supportedFootprints"] as! Int) >= 12 }.count] as [String:Any] : reports[0]
  try JSONSerialization.data(withJSONObject: payload,options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: args[5]))
  print("TRANSITIONS",reports.count)
 }
}
