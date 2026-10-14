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

// Effects consumed by OverlayController. GPU caches still use their exact
// parameter keys; these flags avoid unrelated window/capture work.
struct SettingsChange: OptionSet {
    let rawValue: Int
    static let appearance = Self(rawValue: 1 << 0)
    static let layout = Self(rawValue: 1 << 1)
    static let playback = Self(rawValue: 1 << 2)
    static let window = Self(rawValue: 1 << 3)
    static let desktop = Self(rawValue: 1 << 4)
    static let all: Self = [.appearance, .layout, .playback, .window, .desktop]
}

final class Settings: ObservableObject {
    // App-local preferences only. No login items, telemetry, network, or global input hooks.
    private let defaults: UserDefaults
    private let persistent: Bool
    var onChange: ((SettingsChange) -> Void)?
    private let preferenceWriter: ((String, Any) -> Void)?
    private var batchDepth = 0
    private var pendingChanges: SettingsChange = []
    private var pendingWrites: [String: Any] = [:]
    @Published var size: Double { didSet { changed("size", value: size, old: oldValue, effects: [.layout, .playback, .desktop, .appearance]) } }
    @Published var inclination: Double { didSet { changed("inclination", value: inclination, old: oldValue, effects: [.appearance, .desktop]) } }
    @Published var brightness: Double { didSet { changed("brightness", value: brightness, old: oldValue, effects: [.appearance]) } }
    @Published var glow: Double { didSet { changed("glow", value: glow, old: oldValue, effects: [.appearance]) } }
    @Published var speed: Double { didSet { changed("speed", value: speed, old: oldValue, effects: [.playback, .appearance]) } }
    @Published var spin: Double { didSet { changed("spin", value: spin, old: oldValue, effects: [.appearance, .desktop]) } }
    @Published var relativistic: Bool { didSet { changed("relativistic", value: relativistic, old: oldValue, effects: [.appearance]) } }
    @Published var beamFiltering: Bool { didSet { changed("beamFiltering", value: beamFiltering, old: oldValue, effects: [.appearance]) } }
    @Published var lensResponse: Bool { didSet { changed("lensResponse", value: lensResponse, old: oldValue, effects: [.appearance]) } }
    @Published var shutterAngle: Double { didSet { changed("shutterAngle", value: shutterAngle, old: oldValue, effects: [.appearance]) } }
    @Published var lensScale: Double { didSet { changed("lensScale", value: lensScale, old: oldValue, effects: [.appearance]) } }
    @Published var diskHue: Double { didSet { changed("diskHue", value: diskHue, old: oldValue, effects: [.appearance]) } }
    @Published var diskSaturation: Double { didSet { changed("diskSaturation", value: diskSaturation, old: oldValue, effects: [.appearance]) } }
    @Published var psfLabel = "合成镜头响应"
    @Published var psfError: String?
    var measuredPSF: MeasuredPSF?
    var psfRevision = 0
    @Published var quality: RenderQuality { didSet { changed("quality", value: quality.rawValue, old: oldValue.rawValue, effects: [.layout, .playback, .desktop, .appearance]) } }
    @Published var clickThrough: Bool { didSet { changed("clickThrough", value: clickThrough, old: oldValue, effects: [.window]) } }
    @Published var alwaysOnTop: Bool { didSet { changed("alwaysOnTop", value: alwaysOnTop, old: oldValue, effects: [.window, .desktop]) } }
    @Published var visible = true { didSet { if visible != oldValue { notify([.playback, .window, .desktop, .appearance]) } } }
    @Published var paused = false { didSet { if paused != oldValue { notify([.playback, .appearance]) } } }
    @Published var rendererError: String?
    @Published var renderResolution = ""
    @Published var displayedWidth = 0.0
    @Published var maximumSize = OverlaySizing.minimum
    // Explicit opt-in per launch. Never persist capture enablement.
    @Published var desktopLensing = false { didSet { if desktopLensing != oldValue { notify([.layout, .playback, .desktop, .appearance]) } } }
    @Published var desktopStrength = 0.65 { didSet { if desktopStrength != oldValue { notify([.desktop, .appearance]) } } }
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

    init(persistent: Bool = true, preferenceWriter: ((String, Any) -> Void)? = nil) {
        self.preferenceWriter = preferenceWriter
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

    private func changed<T: Equatable>(_ key: String, value: T, old: T, effects: SettingsChange) {
        guard value != old else { return }
        pendingWrites[key] = value
        notify(effects)
    }
    private func notify(_ effects: SettingsChange) {
        pendingChanges.formUnion(effects)
        if batchDepth == 0 { flushChanges() }
    }
    private func flushChanges() {
        let changes = pendingChanges, writes = pendingWrites
        pendingChanges = []; pendingWrites = [:]
        for (key, value) in writes {
            if let preferenceWriter { preferenceWriter(key, value) }
            else if persistent { defaults.set(value, forKey: key) }
        }
        if !changes.isEmpty { onChange?(changes) }
    }
    func batchUpdates(_ action: () -> Void) {
        batchDepth += 1
        defer { batchDepth -= 1; if batchDepth == 0 { flushChanges() } }
        action()
    }

    func restoreAppearance() {
        batchUpdates {
            size = OverlaySizing.minimum; inclination = 8; brightness = 1.3; glow = 0.65
            speed = MotionTuning.defaultSpeed; quality = .balanced
            spin = 0; relativistic = false
            beamFiltering = true; lensResponse = true; shutterAngle = 180; lensScale = 1
            setPalette(.gold)
            resetPSF()
        }
    }

    func updateSizeLimit(screenSize: CGSize) {
        let limit=max(OverlaySizing.minimum,OverlaySizing.maximumWidth(in:screenSize))
        if maximumSize != limit {maximumSize=limit}
        if size>limit {size=limit}
    }

    func setMovieParameters() {
        batchUpdates {
            spin=0.6;relativistic=false;inclination=8
            beamFiltering=true;lensResponse=true;shutterAngle=180
        }
    }

    func setPalette(_ palette: DiskPalette) {
        batchUpdates { diskHue = palette.hue; diskSaturation = palette.saturation }
    }
    var selectedPalette: DiskPalette? {
        DiskPalette.allCases.first { abs(diskHue-$0.hue)<0.001 && abs(diskSaturation-$0.saturation)<0.001 }
    }

    func resetPSF() {
        measuredPSF = nil; psfRevision += 1; psfLabel = "合成镜头响应"; psfError = nil
        notify([.appearance])
    }
    func choosePSF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "选择线性光强 PSF 的 JSON 数据。仅在本次运行使用，不复制或上传文件。"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                measuredPSF = try MeasuredPSF.read(url); psfRevision += 1
                psfLabel = url.lastPathComponent; psfError = nil; notify([.appearance])
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
