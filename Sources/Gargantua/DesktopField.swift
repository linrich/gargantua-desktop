// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import simd

// Local visual support around the disk, measured with equal x/y pixel scales.
// Window movement changes only the sampling transform, not the cached rays.
enum DesktopField {
    static let maximumMapSide=3072
    static let compandingScale: Float=0.2
    // A fitted visual envelope: projected horizontal disk + central lensed arc.
    // These are artistic bounds, not a cutoff of the physical deflection field.
    static let featherInner: Float = -0.17
    static let featherOuter: Float = 0.052
    static func diskHalfHeight(inclination: Float) -> Float {
        0.06+0.46*sin(inclination*Float.pi/180)
    }
    static func distance(_ point: SIMD2<Float>, inclination: Float) -> Float {
        func ellipse(_ p: SIMD2<Float>, _ axes: SIMD2<Float>) -> Float {
            let k0=simd_length(p/axes),k1=simd_length(p/(axes*axes))
            return k1>1e-6 ? k0*(k0-1)/k1 : -min(axes.x,axes.y)
        }
        let disk=ellipse(point-SIMD2(0,-0.025),SIMD2(0.635,diskHalfHeight(inclination:inclination)))
        let arc=ellipse(point-SIMD2(0,0.018),SIMD2(0.285,0.265))
        let h=max(0.05-abs(disk-arc),0)/0.05
        return min(disk,arc)-h*h*0.05*0.25
    }
    static func bounds(inclination: Float) -> CGRect {
        // The distance approximation can underestimate true distance; retain
        // conservative padding. The shader owns the exact feather contour.
        let padding:Float=0.09,dy=diskHalfHeight(inclination:inclination)
        let low=min(-0.025-dy,0.018-0.265)-padding
        let high=max(-0.025+dy,0.018+0.265)+padding
        return CGRect(x:CGFloat(-0.635-padding),y:CGFloat(low),width:CGFloat(2*(0.635+padding)),height:CGFloat(high-low))
    }
    static func extent(output: SIMD2<Int>, viewport: SIMD4<Float>) -> Float {
        // Includes the feather's full support plus interpolation padding.
        // Independent of clipping at a display edge, so dragging reuses rays.
        0.80
    }
    static func mapSide(output: SIMD2<Int>, viewport: SIMD4<Float>) -> Int {
        let height=Float(output.y)*viewport.w
        return min(maximumMapSide,max(512,Int(ceil(height*2/16))*16))
    }

    static func frame(overlay: CGRect, screen: CGRect, pixelScale: CGFloat, inclination: Float = 8) -> CGRect {
        let support=bounds(inclination:inclination)
        let scale=max(1,pixelScale)
        // Round the origin but keep the pixel extent fixed during subpixel
        // movement. Rounding both edges independently used to alternate the
        // drawable's width/height by one pixel and recreate its backing store.
        // A pixel on each side keeps the feather inside the rounded surface.
        let x0=floor((overlay.midX+support.minX*overlay.height-screen.minX)*scale-1)/scale+screen.minX
        let y0=floor((overlay.midY+support.minY*overlay.height-screen.minY)*scale-1)/scale+screen.minY
        let width=(ceil(support.width*overlay.height*scale)+2)/scale
        let height=(ceil(support.height*overlay.height*scale)+2)/scale
        return CGRect(x:x0,y:y0,width:width,height:height).intersection(screen)
    }

    // Top-left pixel rectangle, clipped inside the attachment as Metal requires.
    static func rasterBounds(output: SIMD2<Int>, viewport: SIMD4<Float>, inclination: Float) -> CGRect {
        let h=CGFloat(Float(output.y)*viewport.w),support=bounds(inclination:inclination)
        let cx=CGFloat((viewport.x+viewport.z/2)*Float(output.x))
        let cy=CGFloat((viewport.y+viewport.w/2)*Float(output.y))
        let x0=floor(cx+support.minX*h-2),y0=floor(cy-support.maxY*h-2)
        let x1=ceil(cx+support.maxX*h+2),y1=ceil(cy-support.minY*h+2)
        return CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0).intersection(CGRect(x:0,y:0,width:output.x,height:output.y))
    }
}
