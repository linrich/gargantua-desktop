// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
struct DesktopUniforms {
    float4 rect;      // captured display UV rectangle of the output
    float4 controls;  // strength, cached camera-plane extent, companding scale, reserved
    float4 viewport;  // original black-hole frame inside this output, top-left UV
};

float desktopHeight(constant Uniforms &u,constant DesktopUniforms &d) {
    return round(d.viewport.w*u.resolution.y*256)/256;
}

float2 desktopScreen(float2 uv,constant Uniforms &u,constant DesktopUniforms &d) {
    // Use the same subpixel grid in any cropped target. Otherwise float UV
    // roundoff can choose opposite ray branches at a critical curve when the
    // window origin moves. 1/256 pixel is below the existing sampling precision.
    float height=desktopHeight(u,d);
    float2 center=round((d.viewport.xy+.5*d.viewport.zw)*u.resolution*256)/256;
    float2 pixel=floor(uv*u.resolution)+.5;
    return (pixel-center)/height*float2(1,-1);
}

// The sinh grid spends samples near the shadow and fewer in the smooth far
// field. It changes cache density only; it is not a spatial falloff or mask.
float4 desktopMapSample(float2 uv,texture2d<float> mapping,constant Uniforms &u,constant DesktopUniforms &d) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 screen=desktopScreen(uv,u,d);
    float2 mapUV=.5+.5*asinh(screen/d.controls.z)/asinh(d.controls.y/d.controls.z);
    float2 size=float2(mapping.get_width(),mapping.get_height());
    uint2 pos=min(uint2(clamp(mapUV,0.0,1.0)*size),uint2(size)-1);
    float4 nearest=mapping.read(pos);
    float4 value=mapping.sample(linear,mapUV,level(0));
    // Never interpolate a captured ray with an escaped branch.
    return nearest.z==3 && abs(value.z-3)<1.e-5 ? float4(value.xy,3,0):nearest;
}

struct DesktopLookup { float2 uv; float weight; float displacementPixels; };
float desktopEllipseDistance(float2 p,float2 axes) {
    float k0=length(p/axes),k1=length(p/(axes*axes));
    return k1>1.e-6 ? k0*(k0-1)/k1 : -min(axes.x,axes.y);
}
float desktopSupportDistance(float2 p,float inclination) {
    float disk=desktopEllipseDistance(p-float2(0,-.025),float2(.635,.06+.46*sin(inclination*M_PI_F/180)));
    float arc=desktopEllipseDistance(p-float2(0,.018),float2(.285,.265));
    float h=max(.05-abs(disk-arc),0.0)/.05;
    return min(disk,arc)-h*h*.05*.25;
}
DesktopLookup desktopLookup(float2 uv,float4 map,constant Uniforms &u,constant DesktopUniforms &d) {
    float2 base=d.rect.xy+uv*d.rect.zw;
    float height=desktopHeight(u,d);
    float2 offset=map.xy*float2(1,-1)*height/u.resolution*clamp(d.controls.x,0.0,1.0)*d.rect.zw;
    // User-selected local visual treatment, not a physical cutoff of gravity.
    // Fit the disk and its central lensed arc, including the inclination.
    // Feather displacement back to identity, rather than exposing a round patch.
    float distanceToDisk=desktopSupportDistance(desktopScreen(uv,u,d),u.inclination);
    // A compact footprint needs a softer join than the old wide radial fade.
    // Evaluate the seventh-order ramp from zero at the outside to avoid
    // subtractive cancellation; its first three derivatives vanish there.
    float t=clamp((.052-distanceToDisk)/.222,0.0,1.0);
    float feather=t*t*t*t*(35+t*(-84+t*(70-20*t)));
    offset*=feather;
    // The display is a finite source image. Compress only sources that approach
    // its physical edge, separately from the local artistic feather above.
    float2 room=max(select(base,1-base,offset>=0),float2(1.e-6));
    offset=room*tanh(offset/room);
    float distance=length(offset/d.rect.zw*u.resolution);
    float weight=smoothstep(.05,.35,distance);
    // Foreground coverage owns the shadow, including its transparent disk gaps.
    if(map.z!=3||d.controls.x<=0)weight=0;
    return {base+offset,weight,distance};
}

kernel void probeDesktopLookup(texture2d<float> mapping [[texture(0)]],
                               texture2d<float,access::write> output [[texture(1)]],
                               constant Uniforms &u [[buffer(0)]],constant DesktopUniforms &d [[buffer(1)]],
                               uint2 tid [[thread_position_in_grid]]) {
    if(any(tid>=uint2(u.resolution)))return;
    float2 uv=(float2(tid)+.5)/u.resolution;
    DesktopLookup sample=desktopLookup(uv,desktopMapSample(uv,mapping,u,d),u,d);
    output.write(float4(sample.uv,sample.weight,sample.displacementPixels),tid);
}

kernel void probeDesktopMapping(texture2d<float> mapping [[texture(0)]],
                                texture2d<float,access::write> output [[texture(1)]],
                                constant Uniforms &u [[buffer(0)]],constant DesktopUniforms &d [[buffer(1)]],
                                uint2 tid [[thread_position_in_grid]]) {
    if(any(tid>=uint2(u.resolution)))return;
    output.write(desktopMapSample((float2(tid)+.5)/u.resolution,mapping,u,d),tid);
}

float2 angularProjection(float3 ray,float3 forward,float3 up) {
    float2 p=float2(ray.y,dot(ray,up));
    float lengthP=length(p);
    return lengthP>1.e-7 ? p/lengthP*atan2(lengthP,dot(ray,forward))*(1.8/1.04):float2(0);
}

kernel void desktopGeometry(texture2d<float,access::write> mapping [[texture(0)]],
                            constant Uniforms &u [[buffer(0)]],constant DesktopUniforms &d [[buffer(1)]],
                            uint2 tid [[thread_position_in_grid]]) {
    uint2 size=uint2(mapping.get_width(),mapping.get_height());
    if(any(tid>=size))return;
    float2 grid=(float2(tid)+.5)/float2(size)*2-1;
    float2 screen=sinh(grid*asinh(d.controls.y/d.controls.z))*d.controls.z;
    Beam ray=traceBeam(screen,u.spin,u.inclination,u.stepScale,0,true);
    float2 displacement=0;
    if(ray.info.x==3) {
        float theta=M_PI_F/2-u.inclination*M_PI_F/180;
        float3 forward=-float3(sin(theta),0,cos(theta)),up=float3(-cos(theta),0,sin(theta));
        float3 flat=normalize(1.8*forward+1.04*(float3(0,screen.x,0)+up*screen.y));
        displacement=angularProjection(ray.hit.xyz,forward,up)-angularProjection(flat,forward,up);
        // Retain the existing finite-image deflection bound near critical rays.
        // The local artistic feather is applied later, in output coordinates.
        displacement*=min(1.0,.65/max(length(displacement),1.e-6));
    }
    mapping.write(float4(displacement,ray.info.x,0),tid);
}

float4 compositeDesktop(float2 uv,float4 front,texture2d<float> desktop,texture2d<float> mapping,
                        constant Uniforms &u,constant DesktopUniforms &d) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    DesktopLookup lookup=desktopLookup(uv,desktopMapSample(uv,mapping,u,d),u,d);
    if(lookup.weight<=0) {
        if(u.background>2.5) {
            float3 original=desktop.sample(linear,d.rect.xy+uv*d.rect.zw).rgb;
            return float4(front.rgb+original*(1-front.a),1);
        }
        return front;
    }
    float2 sampleUV=lookup.uv;
    float2 pixelSize=1/float2(desktop.get_width(),desktop.get_height());
    // Hardware derivatives are shared by a 2x2 raster quad. Moving the local
    // window by one pixel changed the quad pairing and therefore the filter,
    // even at an identical global screen position. Anchor finite differences
    // to each pixel instead; keep the same four desktop taps and width bound.
    float2 ux=uv+float2(1/u.resolution.x,0),uy=uv+float2(0,1/u.resolution.y);
    float2 gx=desktopLookup(ux,desktopMapSample(ux,mapping,u,d),u,d).uv-sampleUV;
    float2 gy=desktopLookup(uy,desktopMapSample(uy,mapping,u,d),u,d).uv-sampleUV;
    float2 dx=clamp(gx,-4*pixelSize,4*pixelSize)*.25;
    float2 dy=clamp(gy,-4*pixelSize,4*pixelSize)*.25;
    float extra=smoothstep(1.1,2.0,max(length(gx/pixelSize),length(gy/pixelSize)));
    dx*=extra;dy*=extra;
    float3 bg=(desktop.sample(linear,sampleUV-dx-dy).rgb+desktop.sample(linear,sampleUV+dx-dy).rgb
              +desktop.sample(linear,sampleUV-dx+dy).rgb+desktop.sample(linear,sampleUV+dx+dy).rgb)*.25;
    float4 result=float4(front.rgb+bg*lookup.weight*(1-front.a),front.a+lookup.weight*(1-front.a));
    if(u.background>2.5) {
        float3 original=desktop.sample(linear,d.rect.xy+uv*d.rect.zw).rgb;
        result=float4(result.rgb+original*(1-result.a),1);
    }
    return result;
}

fragment float4 desktopCompositeFragment(VertexOut in [[stage_in]],texture2d<float> scene [[texture(0)]],
                 texture2d<float> desktop [[texture(1)]],texture2d<float> mapping [[texture(2)]],
                 constant Uniforms &u [[buffer(0)]],constant DesktopUniforms &d [[buffer(1)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 local=(in.uv-d.viewport.xy)/d.viewport.zw;
    float4 front=all(local>=0)&&all(local<=1) ? overlayColor(scene.sample(linear,local),local,u.exposure):float4(0);
    return compositeDesktop(in.position.xy/u.resolution,front,desktop,mapping,u,d);
}

fragment float4 desktopBackgroundFragment(VertexOut in [[stage_in]],texture2d<float> desktop [[texture(1)]],
                 texture2d<float> mapping [[texture(2)]],constant Uniforms &u [[buffer(0)]],constant DesktopUniforms &d [[buffer(1)]]) {
    return compositeDesktop(in.position.xy/u.resolution,float4(0),desktop,mapping,u,d);
}
