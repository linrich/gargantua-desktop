// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
// Coordinate Jacobi fields: forward-mode differentiation of the Kerr flow.
// This is the variational/geodesic-deviation formulation, not finite differences
// between pixels and not DNGR's particular Sachs-basis implementation.
struct Jet { float v; float2 d; };
Jet j(float v) { return {v,float2(0)}; }
Jet operator+(Jet a,Jet b){return {a.v+b.v,a.d+b.d};}
Jet operator-(Jet a,Jet b){return {a.v-b.v,a.d-b.d};}
Jet operator-(Jet a){return {-a.v,-a.d};}
Jet operator*(Jet a,Jet b){return {a.v*b.v,a.d*b.v+b.d*a.v};}
Jet operator/(Jet a,Jet b){return {a.v/b.v,(a.d*b.v-b.d*a.v)/(b.v*b.v)};}
Jet operator+(Jet a,float b){return a+j(b);} Jet operator+(float a,Jet b){return j(a)+b;}
Jet operator-(Jet a,float b){return a-j(b);} Jet operator-(float a,Jet b){return j(a)-b;}
Jet operator*(Jet a,float b){return {a.v*b,a.d*b};} Jet operator*(float a,Jet b){return b*a;}
Jet operator/(Jet a,float b){return {a.v/b,a.d/b};} Jet operator/(float a,Jet b){return j(a)/b;}
Jet jsqrt(Jet a){float s=sqrt(a.v);return {s,a.d/(2.0*s)};}
Jet jatan2(Jet y,Jet x){return {atan2(y.v,x.v),(x.v*y.d-y.v*x.d)/max(1.e-15,x.v*x.v+y.v*y.v)};}
Jet jfloor(Jet a,float floor){return a.v>floor ? a:j(floor);}
// nx,ny are the Cartesian angular direction with frame-dragging rotation
// factored out. Their ODE is regular at the polar axis, unlike b/sin²(theta).
struct BState { Jet u,mu,du,dmu,phi,t,nx,ny,vx,vy; };
struct BConstants { float a; Jet b,q,e; };
struct Beam { float4 hit,dx,dy,info; };
BState badd(BState a,BState b,float h){return {a.u+b.u*h,a.mu+b.mu*h,a.du+b.du*h,a.dmu+b.dmu*h,a.phi+b.phi*h,a.t+b.t*h,a.nx+b.nx*h,a.ny+b.ny*h,a.vx+b.vx*h,a.vy+b.vy*h};}
BState bderivative(BState s,BConstants c) {
    float aa=c.a*c.a;
    Jet r=1.0/jfloor(s.u,1.e-6), delta=jfloor(r*r-2.0*r+aa,1.e-5);
    Jet p=r*r+aa-c.a*c.b, sn=jfloor(1.0-s.mu*s.mu,1.e-7);
    Jet coef=aa-c.b*c.b-c.q, k=(c.b-c.a)*(c.b-c.a)+c.q;
    Jet angular=c.q+c.b*c.b+2.0*aa*s.mu*s.mu;
    return {s.du,s.dmu,coef*s.u+3.0*k*s.u*s.u-2.0*aa*c.q*s.u*s.u*s.u,
            coef*s.mu-2.0*aa*s.mu*s.mu*s.mu,
            c.a-c.a*p/delta,(r*r+aa)*p/delta+c.a*(c.b-c.a*sn),
            s.vx,s.vy,-angular*s.nx,-angular*s.ny};
}
BState brk4(BState s,BConstants c,float h) {
    BState k1=bderivative(s,c), k2=bderivative(badd(s,k1,h*.5),c);
    BState k3=bderivative(badd(s,k2,h*.5),c), k4=bderivative(badd(s,k3,h),c);
    BState sum=badd(badd(badd(k1,k2,2),k3,2),k4,1);
    return badd(s,sum,h/6.0);
}
State bvalue(BState s){return {float4(s.u.v,s.mu.v,s.du.v,s.dmu.v),float2(s.phi.v,s.t.v)};}
Beam traceBeam(float2 screen,float a,float elevation,float stepScale,float pixelPitch,bool backgroundOnly=false) {
    float rc=64, theta=M_PI_F/2.0-elevation*M_PI_F/180.0, st=sin(theta), ct=cos(theta), aa=a*a;
    float rho=sqrt(rc*rc+aa*ct*ct), delta=rc*rc-2.0*rc+aa;
    float sigma=sqrt((rc*rc+aa)*(rc*rc+aa)-aa*delta*st*st);
    float lapse=rho*sqrt(delta)/sigma, omega=2*a*rc/(sigma*sigma), varpi=sigma*st/rho;
    Jet x={screen.x,float2(pixelPitch,0)}, y={screen.y,float2(0,-pixelPitch)};
    Jet norm=jsqrt(1.8*1.8+1.04*1.04*(x*x+y*y));
    Jet nr=1.8/norm, nt=y*1.04/norm, np=x*(-1.04)/norm;
    Jet energy=1.0/(lapse+omega*varpi*np), b=energy*varpi*np, pt=energy*rho*nt;
    Jet q=pt*pt+ct*ct*(b*b/(st*st)-aa);
    BConstants c={a,b,q,energy}; RayConstants plain={a,b.v,q.v,energy.v};
    BState s={j(1.0/rc),j(ct),energy*(sqrt(delta)*rho/(rc*rc))*nr,st*pt,j(0),j(0),j(st),j(0),-ct*pt,-b/st};
    float inner=iscoRadius(a), horizon=1+sqrt(1-aa);
    float base=min(.006,.04/sqrt(max(1.0,b.v*b.v+abs(q.v)+aa)))*stepScale;
    int crossings=0,status=4; float2 errors=float2(0);
    Beam result={float4(0),float4(0),float4(0),float4(0)};
    for(int i=0;i<2400;++i) {
        State v=bvalue(s);
        if(!all(isfinite(v.d))||!all(isfinite(v.transport))) {status=5;break;}
        float r=1/max(s.u.v,1.e-6);
        if(r<horizon+.015){status=2;break;}
        if(s.u.v<1.0/90.0&&s.du.v<0){status=3;break;}
        float h=min(base,.10/max(abs(bderivative(s,c).phi.v),1.e-4));
        h=min(h,.12*max(r-horizon,.005)/max(abs(s.du.v)*r*r,.01)); h=max(h,1.e-7);
        BState next=brk4(s,c,h);
        errors=max(errors,invariantErrors(bvalue(next),plain));
        if(s.mu.v*next.mu.v<0) {
            crossings++;
            float fraction=clamp(s.mu.v/(s.mu.v-next.mu.v),0.0,1.0);
            BState cross=brk4(s,c,h*fraction);
            for(int k=0;k<3;++k){
                if(abs(cross.dmu.v)>1.e-6) fraction=clamp(fraction-cross.mu.v/(h*cross.dmu.v),0.0,1.0);
                cross=brk4(s,c,h*fraction);
            }
            float radius=1/cross.u.v;
            if(!backgroundOnly&&radius>=inner&&radius<=23) {
                // Endpoint projection is essential: neighbouring rays hit the
                // disk at DIFFERENT Mino times. d(s_hit)/d(pixel)=-dmu/mu'.
                float2 ds=-cross.mu.d/cross.dmu.v;
                BState f=bderivative(cross,c);
                cross.u.d+=f.u.v*ds; cross.phi.d+=f.phi.v*ds; cross.t.d+=f.t.v*ds;
                cross.nx.d+=f.nx.v*ds; cross.ny.d+=f.ny.v*ds;
                Jet azimuth=jatan2(cross.ny,cross.nx)+cross.phi;
                Jet rj=1.0/cross.u, r32=rj*jsqrt(rj);
                float sense=a<0?-1.0:1.0;
                Jet om=sense/(r32+abs(a));
                Jet ut=(r32+abs(a))/jsqrt(jfloor(rj*rj*rj-3*rj*rj+2*abs(a)*r32,1.e-6));
                Jet g=energy/(ut*(1-om*b));
                result.hit=float4(rj.v,azimuth.v,g.v,cross.t.v);
                result.dx=float4(rj.d.x,azimuth.d.x,g.d.x,cross.t.d.x);
                result.dy=float4(rj.d.y,azimuth.d.y,g.d.y,cross.t.d.y);
                status=all(isfinite(result.dx))&&all(isfinite(result.dy))?1:6;
                break;
            }
        }
        s=next;
    }
    if(backgroundOnly&&status==3) {
        // Past-directed escaping tangent in Cartesian space at the outer
        // sphere r=90M. The regular nx/ny variables include polar crossings.
        float cp=cos(s.phi.v),sp=sin(s.phi.v);
        float3 direction=float3(cp*s.nx.v-sp*s.ny.v,sp*s.nx.v+cp*s.ny.v,s.mu.v);
        BState slope=bderivative(s,c);
        float3 angular=float3(cp*s.vx.v-sp*s.vy.v,sp*s.vx.v+cp*s.vy.v,s.dmu.v);
        angular.xy+=slope.phi.v*float2(-direction.y,direction.x);
        float r=1/s.u.v,dr=-s.du.v*r*r;
        float3 tangent=normalize(dr*direction+r*angular);
        result.hit=float4(tangent,1);
        if(!all(isfinite(tangent)))status=5;
    }
    result.info=float4(status,crossings,errors);
    return result;
}
kernel void beamGeometry(texture2d<float,access::write> primary [[texture(0)]],
                         texture2d<float,access::write> info [[texture(1)]],
                         texture2d<float,access::write> dx [[texture(2)]],
                         texture2d<float,access::write> dy [[texture(3)]],
                         constant Uniforms &u [[buffer(0)]],uint2 tid [[thread_position_in_grid]]) {
    if(any(tid>=uint2(u.resolution)))return;
    float2 screen=((float2(tid)+.5)/u.resolution-.5)*float2(u.resolution.x/u.resolution.y,-1);
    Beam b=traceBeam(screen,u.spin,u.inclination,u.stepScale,1/u.resolution.y);
    primary.write(b.hit,tid); info.write(b.info,tid); dx.write(b.dx,tid); dy.write(b.dy,tid);
}
// Cache a 4x4 grid at visibility / image-branch boundaries, and a 2x2 grid
// for large smooth footprints. The upper index bits encode the grid size.
// Shared classification: counting and refinement must request identical grids.
uint refinedBeamGrid(texture2d<float,access::read> info,
                     texture2d<float,access::read> dx,
                     texture2d<float,access::read> dy,
                     constant Uniforms &u, uint2 tid) {
    float4 center=info.read(tid); bool split=center.x>=4;
    for(int k=0;k<4;++k){
        int2 offset=k==0?int2(2,0):k==1?int2(-2,0):k==2?int2(0,2):int2(0,-2);
        uint2 pos=uint2(clamp(int2(tid)+offset,int2(0),int2(u.resolution)-1));
        float4 n=info.read(pos);
        split=split||n.x!=center.x||(center.x==1&&n.y!=center.y);
    }
    float4 x=dx.read(tid),y=dy.read(tid);
    split=split||(center.x==1&&(length(float2(x.x,y.x))>.22||length(float2(x.y,y.y))>.12));
    bool edge=false;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
        uint2 pos=uint2(clamp(int2(tid)+int2(x,y),int2(0),int2(u.resolution)-1));
        float4 n=info.read(pos);
        edge=edge||n.x!=center.x||(center.x==1&&n.y!=center.y);
    }
    // The 8x8 validation path samples EVERY pixel, avoiding dependence on the
    // edge detector when measuring convergence and missed subpixel features.
    if(u.edgeGrid>4)edge=true;
    split=split||edge;
    return split ? (edge ? uint(u.edgeGrid) : 2u) : 0u;
}
kernel void countRefinedBeams(texture2d<float,access::read> info [[texture(0)]],
                              texture2d<float,access::read> dx [[texture(1)]],
                              texture2d<float,access::read> dy [[texture(2)]],
                              device atomic_uint *counter [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]], uint2 tid [[thread_position_in_grid]]) {
    if(any(tid>=uint2(u.resolution)))return;
    uint grid=refinedBeamGrid(info,dx,dy,u,tid);
    if(grid)atomic_fetch_add_explicit(counter+3,grid*grid,memory_order_relaxed);
}
kernel void refineBeams(texture2d<float,access::read> primary [[texture(0)]],
                        texture2d<float,access::read> info [[texture(1)]],
                        texture2d<float,access::read> dx [[texture(2)]],
                        texture2d<float,access::read> dy [[texture(3)]],
                        texture2d<uint,access::write> indices [[texture(4)]],
                        device Beam *atlas [[buffer(0)]], device atomic_uint *counter [[buffer(1)]],
                        constant uint &capacity [[buffer(2)]],constant Uniforms &u [[buffer(3)]],
                        uint2 tid [[thread_position_in_grid]]) {
    if(any(tid>=uint2(u.resolution)))return;
    uint grid=refinedBeamGrid(info,dx,dy,u,tid);
    uint slot=0xffffffff;
    if(grid) {
        uint samples=grid*grid;
        atomic_fetch_add_explicit(counter,1,memory_order_relaxed);
        uint index=atomic_fetch_add_explicit(counter+3,samples,memory_order_relaxed);
        if(index+samples<=capacity) {
            slot=index|(grid==8?0x80000000u:grid==4?0x40000000u:0u);
            for(uint k=0;k<samples;++k){
                float2 offset=(float2(k%grid,k/grid)+.5)/float(grid)-.5;
                float2 screen=((float2(tid)+.5+offset)/u.resolution-.5)*float2(u.resolution.x/u.resolution.y,-1);
                Beam refined=traceBeam(screen,u.spin,u.inclination,u.stepScale,1/(float(grid)*u.resolution.y));
                atlas[index+k]=refined;
                if(refined.info.x>=4) atomic_fetch_add_explicit(counter+2,1,memory_order_relaxed);
            }
        } else atomic_fetch_add_explicit(counter+1,1,memory_order_relaxed);
    }
    indices.write(uint4(slot),tid);
}
kernel void probeBundles(const device ProbeInput *inputs [[buffer(0)]],device Beam *outputs [[buffer(1)]],
                         constant uint &count [[buffer(2)]],uint id [[thread_position_in_grid]]){
    if(id>=count)return; ProbeInput p=inputs[id];
    outputs[id]=traceBeam(p.camera.xy,p.camera.z,p.camera.w,p.options.x,p.options.z,p.options.w>0.5);
}

float matterHash(float3 p) {
    p=fract(p*float3(.1031,.1030,.0973));
    p+=dot(p,p.yxz+33.33);
    return fract((p.x+p.y)*p.z);
}
float matterNoise(float3 p) {
    float3 cell=floor(p), f=fract(p);
    f=f*f*f*(f*(f*6-15)+10);
    return mix(mix(mix(matterHash(cell),matterHash(cell+float3(1,0,0)),f.x),
                   mix(matterHash(cell+float3(0,1,0)),matterHash(cell+float3(1,1,0)),f.x),f.y),
               mix(mix(matterHash(cell+float3(0,0,1)),matterHash(cell+float3(1,0,1)),f.x),
                   mix(matterHash(cell+float3(0,1,1)),matterHash(cell+float3(1,1,1)),f.x),f.y),f.z);
}

float filteredMatterNoise(float3 q,float frequency,float offset,float footprint) {
    float weight=1-smoothstep(.35,.9,frequency*footprint);
    if(weight<=0)return .5;
    return mix(.5,matterNoise(q*frequency+offset),weight);
}

// Procedural density/emissivity, not a fluid or dust radiative-transfer solver.
// The cylindrical embedding is exactly periodic in azimuth. Unequal radial and
// tangential scales plus domain warping form broken sheared clouds, without a
// periodic radial carrier (which made the old disk look like luminous wires).
float4 diskMatter(float r,float phase,float spin,float2 texelSize,bool legacyDetail) {
    float angle=phase+.12*r;
    float2 orbit=float2(cos(angle),sin(angle));
    float3 p=float3(orbit*(11+.35*r),r*.85);
    float3 warp=float3(matterNoise(p*.57+11),matterNoise(p*.57+37),matterNoise(p*.57+71))-.5;
    float3 q=p+1.6*warp;
    // Estimate the material texel footprint, including a conservative warp
    // allowance. Unresolved octaves tend to their mean instead of aliasing.
    float footprint=legacyDetail?0:1.8*max(2*M_PI_F*(11+.35*r)*texelSize.x,24*.85*texelSize.y);
    float cloud=.52*filteredMatterNoise(q,.75,0,footprint)+.28*filteredMatterNoise(q,1.9,19,footprint)
                +.14*filteredMatterNoise(q,4.3,43,footprint)+.06*filteredMatterNoise(q,9.1,97,footprint);
    float density=pow(smoothstep(.25,.78,cloud),1.8);
    float lanes=.16+.84*smoothstep(.24,.62,matterNoise(float3(orbit*26+q.xy*.3,r*2+q.z)));
    float granules=.60+.8*filteredMatterNoise(q,16,0,footprint);
    if(!legacyDetail) {
        // Fine structure is attached to the same advected clouds, never screen
        // noise. Fade frequencies not resolved by this material tier before
        // mip generation; the transported EWA footprint then filters the image.
        granules+=.42*(filteredMatterNoise(q,32,137,footprint)-.5);
    }
    float inner=iscoRadius(spin), profile=pow(inner/max(r,inner),1.4);
    float edge=smoothstep(inner,inner+.6,r)*(1-smoothstep(14.0,23.0,r));
    float intensity=edge*profile*(.025+9*density*lanes*granules);
    float heat=clamp(.18+.48*pow(profile,.4)+.4*density,0.0,1.0);
    float3 color=mix(float3(1,.20,.035),float3(1,.86,.61),heat);
    return float4(color*intensity,intensity);
}

// Static, seamless disk material in (azimuth, radius); mipmaps are generated in
// linear radiance, never gamma-encoded colour. Rotation/time delay are sampled
// through the transported footprint, including differential orbital shear.
kernel void buildDiskMaterial(texture2d<float,access::write> material [[texture(0)]],constant float4 &options [[buffer(0)]],
                              uint2 tid [[thread_position_in_grid]]){
    if(tid.x>=material.get_width()||tid.y>=material.get_height())return;
    float r=(tid.y+.5)/material.get_height()*24.0, phase=(tid.x+.5)/material.get_width()*2*M_PI_F;
    float spin=options.x;
    if(options.y<.5) {
        float2 texelSize=1/float2(material.get_width(),material.get_height());
        material.write(diskMatter(r,phase,spin,texelSize,options.z>.5),tid);return;
    }
    // v0.5 material retained only as an offscreen diagnostic reference.
    float2 orbit=float2(cos(phase),sin(phase));
    float n=noise(orbit*3.2+r*1.3)+.5*noise(orbit*9+r*3)+.25*noise(orbit*23+r*8.5);
    float filaments=.62+.25*sin(r*18+n*4)+.13*sin(r*43+n*6);
    float wisps=.45+.55*noise(orbit*7+float2(r*2.3,r*.5));
    float inner=iscoRadius(spin), profile=pow(inner/max(r,inner),1.4);
    float edge=smoothstep(inner,inner+.6,r)*(1-smoothstep(14.0,23.0,r));
    float intensity=edge*profile*filaments*(.65+n*.75)*(0.75+wisps*.5)*3.5;
    float3 color=mix(float3(1,.31,.065),float3(1,.86,.61),pow(profile,.40));
    material.write(float4(color*intensity,intensity),tid);
}

// Elliptical weighted-average reconstruction. J maps a camera pixel to material
// texels; C=4 J J^T + 1/4 I describes a two-pixel-radius truncated Gaussian.
// A mip level bounds numerical work in extreme anisotropy, without disguising
// finite quadrature or linearization as an exact finite-area ray mapping.
float4 ewa(texture2d<float> tex,float2 uv,float2 jx,float2 jy,bool enabled,bool reference=false){
    constexpr sampler bilinear(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear,mip_filter::linear);
    if(!enabled)return tex.sample(bilinear,uv,level(0));
    float2 dims=float2(tex.get_width(),tex.get_height());
    float2 vx=2*jx*dims, vy=2*jy*dims;
    float aa=dot(float2(vx.x,vy.x),float2(vx.x,vy.x)), bb=dot(float2(vx.x,vy.x),float2(vx.y,vy.y));
    float cc=dot(float2(vx.y,vy.y),float2(vx.y,vy.y));
    float disc=sqrt(max(0.0,(aa-cc)*(aa-cc)+4*bb*bb));
    float major=sqrt(max(0.0,.5*(aa+cc+disc))), minor=sqrt(max(0.0,.5*(aa+cc-disc)));
    float lod=clamp(floor(log2(max(1.0,max(minor,major/10.0)))),0.0,float(tex.get_num_mip_levels()-1));
    float scale=exp2(-lod);
    if(!isfinite(major)||major*scale>24.0) return tex.sample(bilinear,uv,level(float(tex.get_num_mip_levels()-1)));
    dims=max(float2(1),floor(dims*scale)); vx*=scale;vy*=scale;
    aa=vx.x*vx.x+vy.x*vy.x+.25;bb=vx.x*vx.y+vy.x*vy.y;cc=vx.y*vx.y+vy.y*vy.y+.25;
    float inv=1/max(aa*cc-bb*bb,1.e-12);
    float2 center=float2(fract(uv.x),uv.y)*dims-.5;
    int2 lo=int2(floor(center-float2(sqrt(aa),sqrt(cc))));
    int2 hi=int2(ceil(center+float2(sqrt(aa),sqrt(cc))));
    float4 sum=0;float weight=0;
    for(int iy=0;iy<50&&lo.y+iy<=hi.y;++iy){
        int y=lo.y+iy,start=lo.x,end=min(hi.x,lo.x+49);
        if(!reference){
            // Intersect this scanline with the SAME ellipse before visiting
            // texels. Keep a one-texel rounding guard and the original r² test.
            float dy=float(y)-center.y,remaining=1-dy*dy/cc;
            if(remaining<0)continue;
            float middle=center.x+bb/cc*dy;
            float radius=sqrt(max(0.0,remaining/(cc*inv)));
            start=max(start,int(floor(middle-radius))-1);end=min(end,int(ceil(middle+radius))+1);
        }
        for(int x=start;x<=end;++x){
        float2 d=float2(x,y)-center;
        float r2=(cc*d.x*d.x-2*bb*d.x*d.y+aa*d.y*d.y)*inv;
        if(r2<1){
            float w=exp(-2*r2)-exp(-2.0);
            float4 value=tex.sample(bilinear,(float2(x,y)+.5)/dims,level(lod));
            sum+=value*w;weight+=w;
        }
        }
    }
    return weight>1.e-7?sum/weight:tex.sample(bilinear,uv,level(lod));
}
// Only specialize the EWA enabled/reference switches. Keep shutter, cloud
// evolution, frequency colour and every floating-point expression unchanged.
constant bool diskFixedSampling [[function_constant(3)]];
float3 beamEmission(Beam b,texture2d<float> material,Uniforms u){
    if(b.info.x!=1)return float3(0);
    bool fixed=false;
    if(is_function_constant_defined(diskFixedSampling))fixed=diskFixedSampling;
    float r=b.hit.x, r32=pow(r,1.5), sense=u.spin<0?-1.0:1.0;
    float omega=sense/(r32+abs(u.spin)), omprime=-sense*1.5*sqrt(r)/pow(r32+abs(u.spin),2.0);
    float4 total=0;
    // Three-point Gauss-Legendre integration over the shutter, centred at time.
    bool instantaneous=u.shutter==0;
    for(int sample=0;sample<(instantaneous?1:3);++sample){
        int i=instantaneous?1:sample;
        float offset=(i-1)*.7745966692*u.shutter*.5;
        float emitTime=(u.time+offset)*20-b.hit.w;
        float2 units=float2(1/(2*M_PI_F),1.0/24.0);
        float4 value=0;
        // Two overlapping 40 M cloud generations prevent indefinite winding.
        // Each is advected by the same circular-orbit omega during its lifetime.
        // Smoothstep weights sum to one; a generation has zero weight and zero
        // time derivative when its random phase changes, including negative T.
        // Weights are evaluated at the beam centre, like the frequency colour.
        float epoch=floor(emitTime/20), blend=smoothstep(0.0,1.0,fract(emitTime/20));
        for(int layer=0;layer<(u.materialEvolution>.5?2:1);++layer) {
            float generation=epoch-1+layer;
            float age=u.materialEvolution>.5?emitTime-(generation+1)*20:emitTime;
            float seed=u.materialEvolution>.5?2*M_PI_F*hash21(float2(generation,37.17)):0;
            float phase=b.hit.y-omega*age+seed;
            float2 x=float2(b.dx.y+omega*b.dx.w-omprime*age*b.dx.x,b.dx.x);
            float2 y=float2(b.dy.y+omega*b.dy.w-omprime*age*b.dy.x,b.dy.x);
            float weight=u.materialEvolution>.5?(layer==0?1-blend:blend):1;
            value+=weight*ewa(material,float2(phase,r)*units,x*units,y*units,fixed||u.beams>.5,!fixed&&u.beams>1.5);
        }
        total+=value*(instantaneous?1.0:(i==1?4.0/9.0:5.0/18.0));
    }
    float temperature=5000+3500*pow(iscoRadius(u.spin)/r,.55);
    return mix(total.rgb,spectrum(max(300.0,temperature*b.hit.z))*total.a,u.relativistic);
}

// Offscreen continuity probes call the same material/beam path as the image.
kernel void probeMaterialEvolution(texture2d<float> material [[texture(0)]],
                                   const device float4 *inputs [[buffer(0)]],
                                   device float4 *outputs [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    float4 p=inputs[id]; // display time, lookback time, radius, azimuth
    Beam b; b.hit=float4(p.z,p.w,1,p.y);b.info=float4(1,0,0,0);
    b.dx=float4(.001,.002,0,.01);b.dy=float4(.002,-.001,0,-.02);
    Uniforms u={};u.time=p.x;u.spin=.6;u.beams=1;u.materialEvolution=1;
    outputs[id]=float4(beamEmission(b,material,u),1);
}
// Art-direction control in scene-linear light. Rotate the R-Y/B-Y chroma
// plane, clip to the nonnegative gamut, then restore luminance. The identity
// bypass is exact; this is separate from the physical frequency calculation.
float3 gradeDisk(float3 rgb,float2 rotation){
    if(rotation.x==1&&rotation.y==0)return rgb;
    const float3 luma=float3(.2126,.7152,.0722);
    float y=dot(rgb,luma);float2 chroma=rgb.rb-y;
    float r=chroma.x*rotation.x-chroma.y*rotation.y;
    float b=chroma.x*rotation.y+chroma.y*rotation.x;
    float g=-(luma.x*r+luma.z*b)/luma.y;
    float3 result=max(float3(r,g,b)+y,float3(0));
    return result*(y/max(dot(result,luma),1.e-20));
}
fragment float4 bundleDiskFragment(VertexOut in [[stage_in]],texture2d<float> primary [[texture(0)]],
          texture2d<float> info [[texture(1)]],texture2d<float> dx [[texture(2)]],texture2d<float> dy [[texture(3)]],
          texture2d<uint,access::read> indices [[texture(4)]],texture2d<float> material [[texture(5)]],
          const device Beam *atlas [[buffer(1)]],constant Uniforms &u [[buffer(0)]]){
    uint2 pos=min(uint2(in.uv*u.resolution),uint2(u.resolution)-1);
    uint index=indices.read(pos).x;
    float3 radiance=0;float alpha=0;
    if(u.beams>.5&&index!=0xffffffff){
        uint samples=4u<<((index>>30)*2),offset=index&0x3fffffffu;
        float weight=1.0/float(samples);
        for(uint i=0;i<samples;++i){
            Beam b=atlas[offset+i];radiance+=beamEmission(b,material,u)*weight;
            float opacity=b.info.x==2?1:0;
            if(b.info.x==1&&u.materialEvolution==1) {
                float inner=iscoRadius(u.spin);
                opacity=.96*smoothstep(inner,inner+.6,b.hit.x)*(1-smoothstep(14.0,23.0,b.hit.x));
            }
            alpha+=opacity*weight;
        }
    } else {
        Beam b={primary.read(pos),dx.read(pos),dy.read(pos),info.read(pos)};
        radiance=beamEmission(b,material,u);alpha=b.info.x==2?1:0;
        if(b.info.x==1&&u.materialEvolution==1) {
            float inner=iscoRadius(u.spin);
            alpha=.96*smoothstep(inner,inner+.6,b.hit.x)*(1-smoothstep(14.0,23.0,b.hit.x));
        }
    }
    return float4(gradeDisk(radiance,u.colorRotation),alpha);
}

struct FilterProbe { float4 center; float4 jacobian; };
kernel void probeEWA(texture2d<float> source [[texture(0)]],const device FilterProbe *inputs [[buffer(0)]],
                     device float4 *outputs [[buffer(1)]],constant uint &count [[buffer(2)]],uint id [[thread_position_in_grid]]){
    if(id>=count)return;FilterProbe p=inputs[id];
    outputs[id]=ewa(source,p.center.xy,p.jacobian.xy,p.jacobian.zw,p.center.z>.5);
}
