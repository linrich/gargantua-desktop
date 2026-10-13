// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import UniformTypeIdentifiers

enum RenderQuality: String, CaseIterable, Identifiable {
    case eco, balanced, cinematic
    var id: String { rawValue }
    var title: String {
        switch self { case .eco: return "节能"; case .balanced: return "均衡"; case .cinematic: return "精细" }
    }
    var fps: Int { self == .cinematic ? 60 : (self == .eco ? 24 : 30) }
    var pixelScale: CGFloat { self == .cinematic ? 2 : (self == .eco ? 1 : 1.5) }
    var detailDescription: String {
        switch self {
        case .eco: return "1× 清晰度 · 24 FPS 目标，适合较小尺寸"
        case .balanced: return "最高 1.5× 清晰度 · 30 FPS 目标"
        case .cinematic: return "最高 2× Retina 清晰度 · 60 FPS 目标，大尺寸开销较高"
        }
    }
}

enum DiskPalette: String, CaseIterable, Identifiable {
    case gold, blue, violet, ember, silver
    var id: String { rawValue }
    var title: String {
        switch self { case .gold: return "暖金"; case .blue: return "冰蓝"; case .violet: return "紫罗兰"
        case .ember: return "赤焰"; case .silver: return "银白" }
    }
    var hue: Double {
        switch self { case .gold, .silver: return 0; case .blue: return 145; case .violet: return 110; case .ember: return 25 }
    }
    var saturation: Double { self == .silver ? 0 : (self == .gold ? 1 : 1.15) }
}

final class Settings: ObservableObject {
    // App-local preferences only. No login items, telemetry, network, or global input hooks.
    private let defaults: UserDefaults
    private let persistent: Bool
    var onChange: (() -> Void)?
    @Published var size: Double { didSet { changed() } }
    @Published var inclination: Double { didSet { changed() } }
    @Published var brightness: Double { didSet { changed() } }
    @Published var glow: Double { didSet { changed() } }
    @Published var speed: Double { didSet { changed() } }
    @Published var spin: Double { didSet { changed() } }
    @Published var relativistic: Bool { didSet { changed() } }
    @Published var beamFiltering: Bool { didSet { changed() } }
    @Published var lensResponse: Bool { didSet { changed() } }
    @Published var shutterAngle: Double { didSet { changed() } }
    @Published var lensScale: Double { didSet { changed() } }
    @Published var diskHue: Double { didSet { changed() } }
    @Published var diskSaturation: Double { didSet { changed() } }
    @Published var psfLabel = "合成镜头响应"
    @Published var psfError: String?
    var measuredPSF: MeasuredPSF?
    var psfRevision = 0
    @Published var quality: RenderQuality { didSet { changed() } }
    @Published var clickThrough: Bool { didSet { changed() } }
    @Published var alwaysOnTop: Bool { didSet { changed() } }
    @Published var visible = true { didSet { onChange?() } }
    @Published var paused = false { didSet { onChange?() } }
    @Published var rendererError: String?
    @Published var renderResolution = ""
    @Published var displayedWidth = 0.0
    @Published var maximumSize = OverlaySizing.minimum
    // Explicit opt-in per launch. Never persist capture enablement.
    @Published var desktopLensing = false {didSet {onChange?()}}
    @Published var desktopStrength = 0.65 {didSet {onChange?()}}
    @Published var desktopStatus = "未采集桌面"

    func setDesktopLensing(_ enabled: Bool) {
        if enabled && !CGPreflightScreenCaptureAccess() && !CGRequestScreenCaptureAccess() {
            desktopStatus="需要在系统设置的屏幕录制权限中允许 Gargantua，然后重新打开此开关。"
            return
        }
        desktopLensing=enabled
        if !enabled {desktopStatus="未采集桌面"}
    }
    var effectiveSpeed: Double {
        MotionTuning.effectiveSpeed(speed,width:displayedWidth>0 ? displayedWidth : size)
    }
    var targetFPS: Int {desktopLensing ? min(30,quality.fps):quality.fps}
    var shutterDuration: Double {
        shutterAngle/360/Double(targetFPS)*effectiveSpeed
    }

    init(persistent: Bool = true) {
        self.persistent = persistent
        let storage = persistent ? UserDefaults.standard : UserDefaults(suiteName: "local.gargantua.snapshot")!
        defaults = storage
        storage.register(defaults: ["size": OverlaySizing.minimum, "inclination": 8.0,
            "brightness": 1.3, "glow": 0.65, "speed": MotionTuning.defaultSpeed,
            "quality": "balanced", "clickThrough": true, "alwaysOnTop": true,
            "spin": 0.0, "relativistic": false, "beamFiltering": true,
            "lensResponse": true, "shutterAngle": 180.0, "lensScale": 1.0,
            "diskHue": 0.0, "diskSaturation": 1.0])
        let savedSize=storage.double(forKey:"size")
        size = savedSize.isFinite ? max(OverlaySizing.minimum,savedSize) : OverlaySizing.minimum
        inclination = min(35, max(2, storage.double(forKey: "inclination")))
        brightness = min(RenderDetail.brightnessRange.upperBound, max(RenderDetail.brightnessRange.lowerBound, storage.double(forKey: "brightness")))
        glow = min(RenderDetail.glowRange.upperBound, max(RenderDetail.glowRange.lowerBound, storage.double(forKey: "glow")))
        speed = min(2, max(0, storage.double(forKey: "speed")))
        spin = min(0.998, max(-0.998, storage.double(forKey: "spin")))
        relativistic = storage.bool(forKey: "relativistic")
        beamFiltering = storage.bool(forKey: "beamFiltering")
        lensResponse = storage.bool(forKey: "lensResponse")
        shutterAngle = min(360,max(0,storage.double(forKey: "shutterAngle")))
        lensScale = min(2,max(0.5,storage.double(forKey: "lensScale")))
        diskHue = min(180,max(-180,storage.double(forKey: "diskHue")))
        diskSaturation = min(2,max(0,storage.double(forKey: "diskSaturation")))
        quality = RenderQuality(rawValue: storage.string(forKey: "quality") ?? "") ?? .balanced
        clickThrough = storage.bool(forKey: "clickThrough")
        alwaysOnTop = storage.bool(forKey: "alwaysOnTop")
    }

    private func changed() {
        guard persistent else { onChange?(); return }
        defaults.set(size, forKey: "size")
        defaults.set(inclination, forKey: "inclination")
        defaults.set(brightness, forKey: "brightness")
        defaults.set(glow, forKey: "glow")
        defaults.set(speed, forKey: "speed")
        defaults.set(spin, forKey: "spin")
        defaults.set(relativistic, forKey: "relativistic")
        defaults.set(beamFiltering, forKey: "beamFiltering")
        defaults.set(lensResponse, forKey: "lensResponse")
        defaults.set(shutterAngle, forKey: "shutterAngle")
        defaults.set(lensScale, forKey: "lensScale")
        defaults.set(diskHue, forKey: "diskHue")
        defaults.set(diskSaturation, forKey: "diskSaturation")
        defaults.set(quality.rawValue, forKey: "quality")
        defaults.set(clickThrough, forKey: "clickThrough")
        defaults.set(alwaysOnTop, forKey: "alwaysOnTop")
        onChange?()
    }

    func restoreAppearance() {
        size = OverlaySizing.minimum; inclination = 8; brightness = 1.3; glow = 0.65
        speed = MotionTuning.defaultSpeed; quality = .balanced
        spin = 0; relativistic = false
        beamFiltering = true; lensResponse = true; shutterAngle = 180; lensScale = 1
        setPalette(.gold)
        resetPSF()
    }

    func updateSizeLimit(screenSize: CGSize) {
        let limit=max(OverlaySizing.minimum,OverlaySizing.maximumWidth(in:screenSize))
        if maximumSize != limit {maximumSize=limit}
        if size>limit {size=limit}
    }

    func setMovieParameters() {
        spin=0.6;relativistic=false;inclination=8
        beamFiltering=true;lensResponse=true;shutterAngle=180
    }

    func setPalette(_ palette: DiskPalette) {
        diskHue = palette.hue; diskSaturation = palette.saturation
    }
    var selectedPalette: DiskPalette? {
        DiskPalette.allCases.first { abs(diskHue-$0.hue)<0.001 && abs(diskSaturation-$0.saturation)<0.001 }
    }

    func resetPSF() {
        measuredPSF = nil; psfRevision += 1; psfLabel = "合成镜头响应"; psfError = nil
        onChange?()
    }
    func choosePSF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "选择线性光强 PSF 的 JSON 数据。仅在本次运行使用，不复制或上传文件。"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                measuredPSF = try MeasuredPSF.read(url); psfRevision += 1
                psfLabel = url.lastPathComponent; psfError = nil; onChange?()
            } catch { psfError = error.localizedDescription }
        }
    }

    var isco: Double {
        let a = abs(spin)
        let z1 = 1 + pow(1 - a*a, 1.0/3) * (pow(1+a, 1.0/3) + pow(1-a, 1.0/3))
        let z2 = sqrt(3*a*a + z1*z1)
        return 3 + z2 - sqrt(max(0, (3-z1)*(3+z1+2*z2)))
    }
}
