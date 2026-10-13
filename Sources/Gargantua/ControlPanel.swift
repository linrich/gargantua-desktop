// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

private let gold = Color(red: 0.91, green: 0.72, blue: 0.43)

struct ControlPanel: View {
    @ObservedObject var settings: Settings
    var center: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(.black).frame(width: 44, height: 44)
                        .overlay(Circle().stroke(gold.opacity(0.9), lineWidth: 1.3))
                        .shadow(color: gold.opacity(0.28), radius: 12)
                    Ellipse().stroke(gold, lineWidth: 2).frame(width: 74, height: 14)
                        .rotationEffect(.degrees(-12))
                }.frame(width: 76, height: 68).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("GARGANTUA").font(.system(size: 18, weight: .medium, design: .monospaced)).tracking(2.6)
                    Text("把宇宙的一角，留在桌面。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Circle().fill(settings.visible ? gold : .gray).frame(width: 5, height: 5)
                Text(!settings.visible ? "已隐藏" : (settings.paused ? "时间已暂停" : (settings.speed == 0 ? "时间静止" : "吸积盘正在流动")))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("METAL · \(settings.targetFPS) FPS 目标").font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(gold.opacity(0.8))
            }
            Divider().overlay(.white.opacity(0.04))
            HStack(spacing: 10) {
                Button { settings.paused.toggle() } label: {
                    Label(settings.paused ? "继续流动" : "暂停时间", systemImage: settings.paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                Button { settings.visible.toggle() } label: {
                    Label(settings.visible ? "隐藏黑洞" : "显示黑洞", systemImage: settings.visible ? "eye.slash" : "eye")
                        .frame(maxWidth: .infinity)
                }
            }.controlSize(.large)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("KERR · 旋转黑洞").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(gold)
                    Spacer()
                    Button("无自旋") {settings.spin=0}
                        .buttonStyle(.borderless).font(.system(size: 11))
                    Button("电影参数") {settings.setMovieParameters()}
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                ValueSlider(title: "自旋 a/M", value: $settings.spin, range: -0.998...0.998,
                            display: String(format: "%+.3f", settings.spin))
                Toggle("引力红移与多普勒频移", isOn: $settings.relativistic)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Text(String(format: "盘内缘 ISCO %.2f GM/c² · %@", settings.isco,
                            settings.relativistic ? "频移开启" : "电影风格：频移关闭"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text("光线包含自旋拖曳与传播时延；负值反转黑洞和盘的旋转方向。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("吸积盘颜色").font(.system(size: 11, weight: .medium)).foregroundStyle(gold)
                    Spacer()
                    Text(settings.selectedPalette?.title ?? "自定义").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    ForEach(DiskPalette.allCases) { palette in
                        Button(palette.title) { settings.setPalette(palette) }
                            .buttonStyle(.bordered)
                            .tint(settings.selectedPalette == palette ? gold : .gray)
                            .accessibilityLabel("吸积盘配色：\(palette.title)")
                    }
                }.controlSize(.small).font(.system(size: 10))
                ValueSlider(title: "色相", value: $settings.diskHue, range: -180...180,
                            display: String(format: "%+.0f°", settings.diskHue))
                ValueSlider(title: "饱和度", value: $settings.diskSaturation, range: 0...2,
                            display: String(format: "%.0f%%", settings.diskSaturation*100))
                Text("暖金恢复原有配色。艺术调色作用于盘与光晕，不改变光路；频移开启时也会参与调色。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 12) {
                Text("光束与镜头").font(.system(size: 11, weight: .medium)).foregroundStyle(gold)
                Toggle("椭圆光束抗闪烁", isOn: $settings.beamFiltering)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Toggle("镜头光晕与散射", isOn: $settings.lensResponse)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                ValueSlider(title: "快门角度", value: $settings.shutterAngle, range: 0...360,
                            display: "\(Int(settings.shutterAngle))°")
                ValueSlider(title: "镜头扩散尺度", value: $settings.lensScale, range: 0.5...2,
                            display: String(format: "%.2f×", settings.lensScale))
                Text("180° 对应半帧曝光；0° 关闭运动模糊。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Button("载入 PSF…") { settings.choosePSF() }
                    if settings.measuredPSF != nil { Button("恢复合成响应") { settings.resetPSF() } }
                }.buttonStyle(.borderless).font(.system(size: 11))
                Text(settings.measuredPSF == nil ? settings.psfLabel : "\(settings.psfLabel) · 散射光量由文件决定").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Text("默认响应为可调光学近似，未经原片 IMAX 镜头实测标定。")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = settings.psfError { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(12).background(gold.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            VStack(spacing: 15) {
                VStack(alignment:.leading,spacing:8) {
                    ValueSlider(title: "黑洞尺寸", value: $settings.size, range: OverlaySizing.minimum...settings.maximumSize,
                                display: "\(Int(settings.size)) pt")
                    HStack {
                        Text("当前屏幕上限 \(Int(settings.maximumSize)) pt")
                        Spacer()
                        Button("360 pt") {settings.size=OverlaySizing.minimum}
                        Button("全屏适配") {settings.size=settings.maximumSize}
                    }.font(.system(size:10)).foregroundStyle(.secondary).buttonStyle(.borderless)
                    Text("保持黑洞比例，完整适配所在屏幕。")
                        .font(.system(size:10)).foregroundStyle(.secondary)
                }
                ValueSlider(title: "观察仰角", value: $settings.inclination, range: 2...35,
                            display: "\(Int(settings.inclination))°")
                ValueSlider(title: "光芒亮度", value: $settings.brightness, range: RenderDetail.brightnessRange,
                            display: String(format: "%.2f", settings.brightness))
                ValueSlider(title: "散射光量", value: $settings.glow, range: RenderDetail.glowRange,
                            display: String(format: "%.2f", settings.glow)).disabled(settings.measuredPSF != nil)
                VStack(alignment: .leading, spacing: 8) {
                    ValueSlider(title: "流动速度", value: Binding(
                        get: {MotionTuning.sliderPosition(for:settings.speed)},
                        set: {settings.speed=MotionTuning.speed(at:$0)}), range: 0...1,
                        display: String(format: "%.3f×", settings.speed))
                    HStack {
                        Text("以 760 pt 为基准，放大时自动减速")
                        Spacer()
                        Button("舒缓 0.05×") {settings.speed=MotionTuning.defaultSpeed}
                            .buttonStyle(.borderless).foregroundStyle(gold)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(String(format:"当前尺寸下实际流速 %.3f×",settings.effectiveSpeed))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Picker("渲染画质", selection: $settings.quality) {
                ForEach(RenderQuality.allCases) { quality in Text(quality.title).tag(quality) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("渲染画质")
            Text("\(settings.quality.detailDescription)\n\(settings.renderResolution) · 放大观看建议选择精细")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 13) {
                Toggle("桌面引力透镜", isOn: Binding(get:{settings.desktopLensing},set:{settings.setDesktopLensing($0)}))
                if settings.desktopLensing {
                    ValueSlider(title:"背景扭曲强度",value:$settings.desktopStrength,range:0...1,
                                display:String(format:"%.0f%%",settings.desktopStrength*100))
                }
                Text("开启后读取所在显示器的实时画面，包含控制台及其他可见窗口；排除黑洞及透镜效果窗口，不采集音频，不保存或上传。每次启动默认关闭。")
                    .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text(settings.desktopStatus).font(.system(size:10)).foregroundStyle(.secondary)
                if settings.desktopLensing {
                    Text("暂停时间只冻结盘面；桌面仍实时更新。关闭此开关可停止采集。")
                        .font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                Toggle("鼠标穿透", isOn: $settings.clickThrough)
                Toggle("始终显示在其他窗口上方", isOn: $settings.alwaysOnTop)
            }.toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
            Text(settings.clickThrough ? "鼠标穿透已开启，可正常操作下方桌面。关闭后拖动黑洞，双击打开此面板。" : "拖动黑洞区域可移动位置；双击可打开面板。窗口的透明区域也会接收鼠标操作。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if let error = settings.rendererError {
                Text("渲染已停止：\(error)").font(.caption).foregroundStyle(.orange)
                    .lineLimit(3).textSelection(.enabled)
            }
            Divider()
            HStack {
                Button("回到屏幕中央", action: center)
                Button("重置外观") { settings.restoreAppearance() }
                Spacer()
                Button(action: quit) { Image(systemName: "power") }.help("退出 Gargantua")
            }.buttonStyle(.borderless).font(.system(size: 11)).foregroundStyle(gold)
            Text("关闭面板后仍在菜单栏运行 · 完全离线渲染")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
        .padding(26)
        .frame(width: 390)
        .background(LinearGradient(colors: [Color(red: 0.095, green: 0.096, blue: 0.112), Color(red: 0.045, green: 0.05, blue: 0.064)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .tint(gold).preferredColorScheme(.dark)
    }
}

private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(display).font(.system(size: 11, design: .monospaced)).foregroundStyle(gold)
            }
            Slider(value: $value, in: range).controlSize(.small).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}
