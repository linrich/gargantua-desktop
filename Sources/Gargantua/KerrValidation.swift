// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

func runKerrChecks(renderer: BlackHoleRenderer, output: URL) throws {
    var inputs: [GeodesicProbe] = []
    var cases: [[String: Any]] = []
    func add(_ name: String, _ x: Float, _ y: Float, _ a: Float, _ elevation: Float = 8,
             scale: Float = 1, disk: Bool = true, reference: Bool = false) -> Int {
        let index = inputs.count
        inputs.append(GeodesicProbe(camera: SIMD4(x,y,a,elevation), options: SIMD4(scale,disk ? 1:0,0,0)))
        cases.append(["name": name, "screen": [x,y], "spin": a, "elevation": elevation,
                      "step_scale": scale, "disk": disk, "cpu_reference": reference])
        return index
    }
    // Finite-distance static observer: sin(alpha_c)=3sqrt(3)*sqrt(1-2/r)/r.
    let sinCritical = 3*sqrt(3.0)*sqrt(1-2.0/64)/64
    let critical = Float(1.8/1.04 * sinCritical/sqrt(1-sinCritical*sinCritical))
    var analytic: [(Int, Int)] = []
    for factor: Float in [0.8,0.98,0.998,1.002,1.02,1.2] {
        for angle: Float in [0,0.7,1.57,2.3] {
            let i = add("schwarzschild-critical",critical*factor*cos(angle),critical*factor*sin(angle),0,disk:false)
            analytic.append((i,factor<1 ? 2:3))
        }
    }
    // Independent analytic Kerr critical curve from spherical photon orbits
    // (James et al. A.1 Eqs. 5-6), converted back into the finite ZAMO camera.
    var kerrAnalytic: [(Int, Int)] = []
    for a: Double in [0.6,0.998,-0.6,-0.998] {
        let magnitude = abs(a)
        let r1 = 2*(1+cos(2.0/3*acos(-magnitude)))
        let r2 = 2*(1+cos(2.0/3*acos(magnitude)))
        let rc = 64.0, theta = Double.pi/2-8*Double.pi/180
        let st = sin(theta), ct = cos(theta), rho = sqrt(rc*rc+a*a*ct*ct)
        let delta = rc*rc-2*rc+a*a
        let sigma = sqrt(pow(rc*rc+a*a,2)-a*a*delta*st*st)
        let lapse = rho*sqrt(delta)/sigma, omega = 2*a*rc/(sigma*sigma), varpi = sigma*st/rho
        for j in 1...9 {
            let r = r1+(r2-r1)*Double(j)/10
            let b = -(r*r*r-3*r*r+a*a*r+a*a)/(a*(r-1))
            let qc = -(r*r*r*(r*r*r-6*r*r+9*r-4*a*a))/(a*a*(r-1)*(r-1))
            for factor in [0.99,1.01] {
                let q = qc*factor, polar = q-ct*ct*(b*b/(st*st)-a*a)
                if polar <= 0 { continue }
                let ef = (1-omega*b)/lapse
                let np = b/(varpi*ef), nt = sqrt(polar)/(rho*ef), nr = sqrt(1-np*np-nt*nt)
                let index = add("kerr-critical",Float(-1.8/1.04*np/nr),Float(1.8/1.04*nt/nr),Float(a),disk:false)
                kerrAnalytic.append((index,factor<1 ? 2:3))
            }
        }
    }
    var mirrorPairs: [(Int,Int)] = []
    for x: Float in [-0.22,-0.14,-0.08,0,0.08,0.14,0.22] {
        for y: Float in [-0.18,-0.10,0,0.10,0.18] {
            mirrorPairs.append((add("spin-mirror+",x,y,0.9,disk:false),add("spin-mirror-",-x,y,-0.9,disk:false)))
        }
    }
    let points: [(Float,Float)] = [(-0.35,-0.05),(-0.18,0.09),(-0.1,0.20),(0.08,0.20),
                                  (0.22,0.07),(0.35,-0.05),(-0.10,-0.12),(0.10,-0.12),
                                  (0,0),(0.5,0.3),(-0.22,-0.03),(0.22,-0.03)]
    var convergence: [(Int,Int)] = []
    for spin: Float in [0,0.6,0.998,-0.998] {
        for (x,y) in points {
            convergence.append((add("reference",x,y,spin,reference:true),add("half-step",x,y,spin,scale:0.5)))
        }
    }
    let results = try renderer.probe(inputs)
    var maxRadial: Float = 0, maxPolar: Float = 0
    for (index,result) in results.enumerated() {
        cases[index]["gpu"] = result
        maxRadial = max(maxRadial,result[8]); maxPolar = max(maxPolar,result[9])
    }
    let finite = results.allSatisfy { $0.allSatisfy(\.isFinite) && $0[4] < 4 }
    let analyticOK = analytic.allSatisfy { Int(results[$0.0][4]) == $0.1 }
    let kerrAnalyticOK = kerrAnalytic.allSatisfy { Int(results[$0.0][4]) == $0.1 }
    let mirrorOK = mirrorPairs.allSatisfy { results[$0.0][4] == results[$0.1][4] }
    var maxRadius: Float = 0, maxPhi: Float = 0, maxDelay: Float = 0, maxShift: Float = 0
    var sameOutcomes = true, comparedHits = 0
    for (i,j) in convergence {
        let x = results[i], y = results[j]
        if x[4] != y[4] { sameOutcomes = false }
        if x[4] == 1 && y[4] == 1 {
            comparedHits += 1
            maxRadius = max(maxRadius, abs(x[0]-y[0]))
            maxPhi = max(maxPhi, abs(atan2(sin(x[1]-y[1]),cos(x[1]-y[1]))))
            maxShift = max(maxShift, abs(x[2]-y[2]))
            maxDelay = max(maxDelay, abs(x[3]-y[3]))
        }
    }
    let checks = ["schwarzschild_analytic_capture_boundary": analyticOK,
                  "kerr_analytic_critical_curve": kerrAnalyticOK,
                  "spin_reversal_mirrors_shadow": mirrorOK,
                  "finite_and_all_probes_terminated": finite,
                  "radial_and_carter_invariants": maxRadial < 0.002 && maxPolar < 0.002,
                  "half_step_same_outcomes": sameOutcomes,
                  "half_step_disk_hit_convergence": comparedHits > 10 && maxRadius < 0.01 && maxPhi < 0.003 && maxShift < 0.003 && maxDelay < 0.04]
    let report: [String: Any] = ["model":"Kerr null geodesics, G=c=M=1", "probe_count":inputs.count,
        "checks":checks, "max_radial_error":maxRadial,"max_polar_error":maxPolar,
        "convergence":["disk_hits":comparedHits,"max_radius_M":maxRadius,"max_phi_radians":maxPhi,
                       "max_g":maxShift,"max_lookback_M":maxDelay], "cases":cases]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        .write(to:output.appendingPathComponent("kerr-geodesics.json"),options:.atomic)
    print("Kerr probes: \(inputs.count); checks: \(checks); invariant errors: \(maxRadial), \(maxPolar)")
    guard checks.values.allSatisfy({$0}) else { throw RenderError.unavailable("Kerr 测地线检查未全部通过，详见 kerr-geodesics.json。") }
}


func runBundleChecks(renderer: BlackHoleRenderer, output: URL) throws {
    var inputs: [GeodesicProbe] = []
    var cases: [[String:Any]] = []
    let pitch: Float = 1/800.0
    let points: [(Float,Float)] = [(-0.35,-0.05),(-0.18,0.09),(-0.1,0.20),(0.08,0.20),
                                  (0.22,0.07),(0.35,-0.05),(-0.10,-0.12),(0.10,-0.12)]
    for angle: Float in [2,8,35] {for spin: Float in [0,0.6,0.998,-0.998] {for (x,y) in points {
        inputs.append(GeodesicProbe(camera:SIMD4(x,y,spin,angle),options:SIMD4(1,1,pitch,0)))
        cases.append(["screen":[x,y],"spin":spin,"elevation":angle,"disk":true,"pixel_pitch":pitch])
    }}}
    for x: Float in [-0.000625,-0.00001,0,0.00001,0.000625] {for y: Float in [-0.23,-0.18,0.18,0.23,0.27] {
        inputs.append(GeodesicProbe(camera:SIMD4(x,y,0.6,8),options:SIMD4(1,1,pitch,0)))
        cases.append(["screen":[x,y],"spin":Float(0.6),"elevation":Float(8),"disk":true,"pixel_pitch":pitch,"axis_case":true])
    }}
    let rays = try renderer.probe(inputs)
    let beams = try renderer.probe(inputs,bundles:true)
    var differences: Float = 0, maxHit: Float = 0, diskCount = 0, negativeParity = 0
    var valid = true
    for i in beams.indices {
        let b=beams[i],r=rays[i]
        valid = valid && b.allSatisfy(\.isFinite) && b[12] < 4
        if b[12] != r[4] {differences+=1}
        if b[12] == 1 {
            diskCount+=1
            for j in 0..<4 where cases[i]["axis_case"] == nil {let d=b[j]-r[j]; maxHit=max(maxHit,j == 1 ? abs(atan2(sin(d),cos(d))):abs(d))}
            if b[4]*b[9]-b[5]*b[8] < 0 {negativeParity+=1}
        }
        cases[i]["gpu"] = b
    }
    let checks=["bundle_and_ray_outcomes_match":differences==0,"all_bundles_finite":valid,
                "central_paths_match":maxHit<0.005,"higher_order_beams_exercised":beams.contains {$0[12] == 1 && $0[13] > 1}]
    let report: [String:Any] = ["method":"Kerr flow variational equations with disk-event projection", "beam_count":inputs.count,
                              "disk_hits":diskCount,"negative_parity":negativeParity,"max_center_difference":maxHit,"checks":checks,"cases":cases]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("ray-bundles.json"),options:.atomic)
    print("Bundle checks: \(checks); center difference \(maxHit)")
    guard checks.values.allSatisfy({$0}) else {throw RenderError.unavailable("光束演化检查失败，详见 ray-bundles.json。")}
    let filter = try renderer.checkEllipticalFilter()
    try JSONSerialization.data(withJSONObject:filter,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("elliptical-filter.json"),options:.atomic)
    print("EWA checks: \(filter)")
    guard let filterChecks=filter["checks"] as? [String:Bool], filterChecks.values.allSatisfy({$0}) else {throw RenderError.unavailable("椭圆滤波检查失败。")}
    let lens = try renderer.checkLensConvolution()
    try JSONSerialization.data(withJSONObject:lens,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("lens-response.json"),options:.atomic)
    guard let lensChecks=lens["checks"] as? [String:Bool], lensChecks.values.allSatisfy({$0}) else {throw RenderError.unavailable("PSF 卷积检查失败。")}
    print("PSF checks: \(lens)")
}
