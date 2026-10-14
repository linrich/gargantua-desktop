// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Metal
import ScreenCaptureKit
import CoreMedia
import CoreVideo

// A live IOSurface reference, not an image file. Retain it until GPU completion.
final class DesktopFrame {
    let texture: MTLTexture
    let displayID: CGDirectDisplayID
    let sequence: UInt64
    private let pixelBuffer: CVPixelBuffer
    private let metalImage: CVMetalTexture
    init(texture: MTLTexture, displayID: CGDirectDisplayID, sequence: UInt64, pixelBuffer: CVPixelBuffer, metalImage: CVMetalTexture) {
        self.texture=texture;self.displayID=displayID;self.sequence=sequence;self.pixelBuffer=pixelBuffer;self.metalImage=metalImage
    }
}

// Control methods run on the main thread; frame delivery has its own queue.
// No audio, screenshots, encoding, files, network, or external processing.
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let frameQueue=DispatchQueue(label:"local.gargantua.desktop-frames",qos:.userInteractive)
    private let lock=NSLock()
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?
    private var wantedDisplay: CGDirectDisplayID?
    private var wantedWindowIDs=Set<CGWindowID>()
    private var generation=0
    private var activeID: ObjectIdentifier?
    private var activeDisplay: CGDirectDisplayID=0
    private var latest: DesktopFrame?
    // Only the serial sample queue advances this; do not reset on stop/restart.
    private var frameSequence: UInt64 = 0
    var onStatus: ((String)->Void)?
    var onFailure: ((String)->Void)?
    // Callback carries no surface and must be safe on either delivery queue.
    var onFrameChanged: (() -> Void)?

    init(device: MTLDevice) {
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache)
    }

    func frame(for displayID: CGDirectDisplayID) -> DesktopFrame? {
        lock.lock();defer{lock.unlock()}
        return latest?.displayID == displayID ? latest:nil
    }

    func configure(displayID: CGDirectDisplayID?, excludingWindowIDs windowIDs: Set<CGWindowID> = []) {
        guard wantedDisplay != displayID || (displayID != nil && wantedWindowIDs != windowIDs) else {return}
        stop()
        guard let displayID else {return}
        // Permission is requested only by the explicit control-panel action.
        guard CGPreflightScreenCaptureAccess() else {
            onFailure?("需要屏幕录制授权；请打开桌面引力透镜开关后按系统提示处理。")
            return
        }
        wantedDisplay=displayID
        wantedWindowIDs=windowIDs
        let request=generation
        onStatus?("正在连接本机桌面…")
        Task { @MainActor [weak self] in
            guard let self else {return}
            do {
                // Include ordered-out windows so a hide/show transition can
                // resolve the persistent NSPanel before its first visible frame.
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard self.generation==request,self.wantedDisplay==displayID else {return}
                guard let display=content.displays.first(where:{$0.displayID==displayID}) else {
                    throw RenderError.unavailable("所在显示器已变化，请重新打开桌面引力透镜。")
                }
                let currentPID=ProcessInfo.processInfo.processIdentifier
                let windows=content.windows.map {
                    CaptureWindow(id:$0.windowID,processID:$0.owningApplication?.processID,
                                  bundleID:$0.owningApplication?.bundleIdentifier,title:$0.title)
                }
                let excludedIDs=try DesktopCapturePolicy.excludedWindowIDs(in:windows,overlayIDs:windowIDs,currentPID:currentPID)
                // Keep the control panel and later-opened windows in the normal
                // display composite; excluding the app exposes windows beneath it.
                let filter=SCContentFilter(display:display,excludingWindows:content.windows.filter {excludedIDs.contains($0.windowID)})
                let config=SCStreamConfiguration()
                let screen=NSScreen.screens.first {($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==displayID}
                var pixelScale=Double(screen?.backingScaleFactor ?? 1)
                if #available(macOS 14.0, *) {pixelScale=Double(filter.pointPixelScale)}
                let captureSize=DesktopCoordinates.captureSize(points:CGSize(width:display.width,height:display.height),pixelScale:pixelScale)
                config.width=Int(captureSize.width);config.height=Int(captureSize.height)
                config.pixelFormat=kCVPixelFormatType_32BGRA
                config.colorSpaceName=CGColorSpace.sRGB
                config.minimumFrameInterval=CMTime(value:1,timescale:30)
                config.queueDepth=3;config.showsCursor=false;config.capturesAudio=false
                config.scalesToFit=true
                let stream=SCStream(filter:filter,configuration:config,delegate:self)
                try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:self.frameQueue)
                self.stream=stream
                self.lock.withLock {self.activeID=ObjectIdentifier(stream);self.activeDisplay=displayID}
                try await stream.startCapture()
                guard self.generation==request,self.wantedDisplay==displayID else {
                    try? await stream.stopCapture();return
                }
                self.onStatus?(self.frame(for:displayID) == nil ? "已启动采集，等待首帧…":"桌面实时扭曲 · 本机内存处理 · 30 FPS 采集上限")
            } catch {
                guard self.generation==request else {return}
                self.stop()
                self.onFailure?("桌面采集不可用：\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        generation+=1;wantedDisplay=nil;wantedWindowIDs=[]
        lock.lock();let hadFrame=latest != nil;activeID=nil;latest=nil;lock.unlock()
        if hadFrame { onFrameChanged?() }
        let old=stream;stream=nil
        if let old {Task {try? await old.stopCapture()}}
        if let cache {CVMetalTextureCacheFlush(cache,0)}
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,sampleBuffer.isValid,
              let attachments=CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
              let raw=attachments.first?[.status] as? Int,let status=SCFrameStatus(rawValue:raw) else {return}
        lock.lock()
        let current=activeID==ObjectIdentifier(stream),displayID=activeDisplay
        let cleared=current && latest != nil && (status == .blank || status == .suspended || status == .stopped)
        if cleared {latest=nil}
        lock.unlock()
        if cleared {onFrameChanged?()}
        guard current,status == .complete,let pixels=sampleBuffer.imageBuffer,let cache else {return}
        var image: CVMetalTexture?
        let result=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,pixels,nil,.bgra8Unorm,
            CVPixelBufferGetWidth(pixels),CVPixelBufferGetHeight(pixels),0,&image)
        guard result==kCVReturnSuccess,let image,let texture=CVMetalTextureGetTexture(image) else {return}
        frameSequence &+= 1
        let frame=DesktopFrame(texture:texture,displayID:displayID,sequence:frameSequence,pixelBuffer:pixels,metalImage:image)
        lock.lock()
        let accepted=activeID==ObjectIdentifier(stream)
        let first=accepted && latest==nil
        if accepted {latest=frame}
        lock.unlock()
        if accepted {onFrameChanged?()}
        if first {
            DispatchQueue.main.async { [weak self] in
                guard let self,self.stream === stream,self.wantedDisplay==displayID else {return}
                self.onStatus?("桌面实时扭曲 · 本机内存处理 · 30 FPS 采集上限")
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock();let current=activeID==ObjectIdentifier(stream);lock.unlock()
        guard current else {return}
        DispatchQueue.main.async { [weak self] in
            guard let self,self.stream === stream else {return}
            self.stop();self.onFailure?("桌面采集已停止：\(error.localizedDescription)")
        }
    }
}

enum DesktopCoordinates {
    // SCDisplay dimensions are points. Preserve Retina pixels; cap exceptional
    // displays by area to bound the three-frame capture queue, not at 1x.
    static func captureSize(points: CGSize, pixelScale: Double) -> CGSize {
        let scale=pixelScale.isFinite ? min(4,max(1,pixelScale)):1
        let w=max(1,Double(points.width)*scale),h=max(1,Double(points.height)*scale)
        let limit=min(1,min(8192/max(w,h),sqrt(16_777_216/(w*h))))
        return CGSize(width:max(1,(w*limit).rounded(.down)),height:max(1,(h*limit).rounded(.down)))
    }

    // AppKit's bottom-left points -> ScreenCaptureKit's top-left normalized UV.
    static func rect(overlay: CGRect, screen: CGRect) -> SIMD4<Float> {
        SIMD4(Float((overlay.minX-screen.minX)/screen.width),Float((screen.maxY-overlay.maxY)/screen.height),
              Float(overlay.width/screen.width),Float(overlay.height/screen.height))
    }
}
