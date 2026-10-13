// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
#include <metal_stdlib>
using namespace metal;

// G = c = M = 1. The Swift layout is 64 bytes.
struct Uniforms {
    float2 resolution;
    float time, exposure, inclination, glow, background, spin;
    float relativistic, stepScale, beams, shutter;
    float2 colorRotation;
    float edgeGrid,materialEvolution;
};
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut fullScreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2.0 - 1.0, 0, 1), float2(p.x, 1.0 - p.y)};
}

float iscoRadius(float spin) {
    float a = abs(spin);
    float z1 = 1.0 + pow(1.0-a*a, 1.0/3.0) * (pow(1.0+a, 1.0/3.0) + pow(1.0-a, 1.0/3.0));
    float z2 = sqrt(3.0*a*a + z1*z1);
    return 3.0 + z2 - sqrt(max(0.0, (3.0-z1)*(3.0+z1+2.0*z2)));
}

// The separated Kerr null equations (Carter constants b=Lz/E, q=Q/E^2),
// reparameterized by reverse Mino time and u=1/r, mu=cos(theta).
// This polynomial second-order form crosses radial/angular turning points
// without flipping square-root signs, and avoids the radial BL divergence.
// James et al. 2015 Appendix A.1; Gralla & Lupsasca 2020 Eqs. 6-11.
struct RayConstants { float a, b, q, cameraEnergy; };
struct State { float4 d; float2 transport; }; // u,mu,du,dmu; phi,lookback time
struct RayResult {
    float4 hit;       // BL radius, azimuth, frequency ratio g, lookback time
    float4 info;      // status: 1=disk,2=horizon,3=escape,4=budget,5=nonfinite; crossings,steps,min r
    float4 errors;    // max radial invariant error, max Carter error, b, q
    float4 terminal;  // final u, mu, phi, time (also used by independent validation)
};
struct ProbeInput { float4 camera; float4 options; }; // screen x,y,a,elevation; stepScale,disk,0,0

State addState(State s, State k, float h) {
    return {s.d + h*k.d, s.transport + h*k.transport};
}
State derivative(State s, RayConstants c) {
    float u = s.d.x, mu = s.d.y, a = c.a, b = c.b, q = c.q;
    float aa = a*a, bb = b*b;
    float k = (b-a)*(b-a)+q;
    float r = 1.0 / max(u, 1.e-6);
    float delta = max(r*r-2.0*r+aa, 1.e-5);
    float p = r*r+aa-a*b;
    float sin2 = max(1.0-mu*mu, 1.e-7);
    float azimuth = -(a*p/delta + b/sin2 - a);
    float delay = (r*r+aa)*p/delta + a*(b-a*sin2);
    return {float4(s.d.z, s.d.w,
        (aa-bb-q)*u + 3.0*k*u*u - 2.0*aa*q*u*u*u,
        (aa-bb-q)*mu - 2.0*aa*mu*mu*mu), float2(azimuth, delay)};
}
State rk4(State s, RayConstants c, float h) {
    State k1 = derivative(s,c);
    State k2 = derivative(addState(s,k1,h*0.5),c);
    State k3 = derivative(addState(s,k2,h*0.5),c);
    State k4 = derivative(addState(s,k3,h),c);
    return {s.d + h/6.0*(k1.d+2.0*k2.d+2.0*k3.d+k4.d),
            s.transport + h/6.0*(k1.transport+2.0*k2.transport+2.0*k3.transport+k4.transport)};
}
float2 invariantErrors(State s, RayConstants c) {
    float u=s.d.x, mu=s.d.y, a2=c.a*c.a;
    float coef=a2-c.b*c.b-c.q, k=(c.b-c.a)*(c.b-c.a)+c.q;
    float radial=1.0+coef*u*u+2.0*k*u*u*u-a2*c.q*u*u*u*u;
    float polar=c.q+coef*mu*mu-a2*mu*mu*mu*mu;
    return float2(abs(s.d.z*s.d.z-radial) / max(1.0, abs(radial)),
                  abs(s.d.w*s.d.w-polar) / max(1.0, abs(c.q)+c.b*c.b));
}

RayResult traceRay(float2 screen, float a, float elevation, float stepScale, bool diskEnabled) {
    float rc=64.0, theta=M_PI_F/2.0-elevation*M_PI_F/180.0;
    float st=sin(theta), ct=cos(theta), aa=a*a;
    float rho=sqrt(rc*rc+aa*ct*ct), delta=rc*rc-2.0*rc+aa;
    float sigma=sqrt((rc*rc+aa)*(rc*rc+aa)-aa*delta*st*st);
    float lapse=rho*sqrt(delta)/sigma, omega=2.0*a*rc/(sigma*sigma), varpi=sigma*st/rho;
    // Future-directed incoming photon in the camera's local ZAMO tetrad.
    // We integrate its past trajectory. Camera has no additional boost.
    float3 n=normalize(float3(1.8, screen.y*1.04, -screen.x*1.04));
    float energy=1.0/(lapse+omega*varpi*n.z);
    float b=energy*varpi*n.z, ptheta=energy*rho*n.y;
    float q=ptheta*ptheta+ct*ct*(b*b/(st*st)-aa);
    RayConstants c={a,b,q,energy};
    State state={float4(1.0/rc, ct, energy*sqrt(delta)*rho*n.x/(rc*rc), st*ptheta), float2(0)};
    float inner=iscoRadius(a), horizon=1.0+sqrt(1.0-aa), minR=rc;
    float baseStep=min(0.006,0.04/sqrt(max(1.0,b*b+abs(q)+aa)))*stepScale;
    float2 errors=invariantErrors(state,c);
    float4 hit=float4(0);
    int crossings=0, status=4, steps=0;
    for (int i=0; i<2400; ++i) {
        steps=i+1;
        if (!all(isfinite(state.d)) || !all(isfinite(state.transport))) { status=5; break; }
        float r=1.0/max(state.d.x,1.e-6);
        minR=min(minR,r);
        if (r < horizon+0.015) { status=2; break; }
        if (state.d.x < 1.0/90.0 && state.d.z < 0.0) { status=3; break; }
        float h=baseStep;
        // Resolve the BL azimuth near the axis and near the horizon.
        State slope=derivative(state,c);
        h=min(h,0.10/max(abs(slope.transport.x),1.e-4));
        h=min(h,0.12*max(r-horizon,0.005)/max(abs(state.d.z)*r*r,0.01));
        h=max(h,1.e-7);
        State next=rk4(state,c,h);
        errors=max(errors,invariantErrors(next,c));
        if (state.d.y*next.d.y < 0.0) {
            crossings++;
            // Refine the equatorial-plane event rather than linearly sampling
            // a disk coordinate from opposite sides of a near-critical ray.
            float fraction=clamp(state.d.y/(state.d.y-next.d.y),0.0,1.0);
            State crossing=rk4(state,c,h*fraction);
            for (int j=0;j<3;++j) {
                if (abs(crossing.d.w)>1.e-6) fraction=clamp(fraction-crossing.d.y/(h*crossing.d.w),0.0,1.0);
                crossing=rk4(state,c,h*fraction);
            }
            float radius=1.0/crossing.d.x;
            if (diskEnabled && radius>=inner && radius<=23.0) {
                float sense=a<0.0 ? -1.0:1.0;
                float orbitalOmega=sense/(pow(radius,1.5)+abs(a));
                float ut=(pow(radius,1.5)+abs(a))/sqrt(max(1.e-6,pow(radius,3.0)-3.0*radius*radius+2.0*abs(a)*pow(radius,1.5)));
                float g=energy/(ut*(1.0-orbitalOmega*b));
                hit=float4(radius,crossing.transport.x,g,crossing.transport.y);
                state=crossing; status=1; break;
            }
        }
        // Exactly meridional rays cross the coordinate axis with a pi jump.
        if (abs(b)<1.e-6 && state.d.w*next.d.w<0.0 && abs(next.d.y)>0.9999) next.transport.x+=M_PI_F;
        state=next;
    }
    return {hit,float4(status,crossings,steps,minR),float4(errors,b,q),float4(state.d.xy,state.transport)};
}

kernel void traceGeometry(texture2d<float,access::write> primary [[texture(0)]],
                          texture2d<float,access::write> secondary [[texture(1)]],
                          texture2d<float,access::write> shadow [[texture(2)]],
                          constant Uniforms &u [[buffer(0)]],uint2 tid [[thread_position_in_grid]]) {
    if (tid.x>=primary.get_width() || tid.y>=primary.get_height()) return;
    float2 uv=(float2(tid)+0.5)/u.resolution;
    float2 screen=(uv-0.5)*float2(u.resolution.x/u.resolution.y,-1.0);
    RayResult ray=traceRay(screen,u.spin,u.inclination,u.stepScale,true);
    primary.write(ray.hit,tid);
    secondary.write(float4(ray.info.x,ray.info.y,ray.errors.xy),tid);
    shadow.write(float4(ray.info.x==2.0 ? 1.0:0.0,0,0,1),tid);
}

kernel void probeGeodesics(const device ProbeInput *inputs [[buffer(0)]],
                           device RayResult *outputs [[buffer(1)]],
                           constant uint &count [[buffer(2)]],uint id [[thread_position_in_grid]]) {
    if (id>=count) return;
    ProbeInput p=inputs[id];
    outputs[id]=traceRay(p.camera.xy,p.camera.z,p.camera.w,p.options.x,p.options.y>0.5);
}

float hash21(float2 p) {
    p=fract(p*float2(123.34,456.21)); p+=dot(p,p+45.32); return fract(p.x*p.y);
}
float noise(float2 p) {
    float2 i=floor(p),f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(hash21(i),hash21(i+float2(1,0)),f.x),mix(hash21(i+float2(0,1)),hash21(i+1),f.x),f.y);
}
// Three monochromatic Planck samples, not a calibrated RGB/film response.
// B_nu(g*T) incorporates I_nu,obs = g^3 I_nu,emit(nu_obs/g).
float3 spectrum(float temperature) {
    return float3(1.0,1.616,2.821)/(exp(float3(22077.0,25916.0,31195.0)/temperature)-1.0)*25.0;
}

float4 overlayColor(float4 pixel,float2 uv,float exposure) {
    float3 radiance=max(pixel.rgb,float3(0));
    float3 color=pow(1.0-exp(-radiance*exposure),float3(1.0/2.2));
    float edge=1.0-smoothstep(0.44,0.50,max(abs(uv.x-0.5),abs(uv.y-0.5)));
    color*=edge;
    float alpha=max(pixel.a,max(color.r,max(color.g,color.b)));
    return float4(color,alpha);
}
fragment float4 compositeFragment(VertexOut in [[stage_in]],texture2d<float> scene [[texture(0)]],
                                  constant Uniforms &u [[buffer(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float4 result=overlayColor(scene.sample(s,in.uv),in.uv,u.exposure);
    if (u.background>0.5) {
        float3 bg=u.background>1.5 ? float3(0.88,0.90,0.93):float3(0.018,0.023,0.032);
        return float4(result.rgb+bg*(1.0-result.a),1);
    }
    return result;
}
