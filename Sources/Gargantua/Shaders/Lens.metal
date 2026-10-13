// Copyright (C) 2026 linrich
// SPDX-License-Identifier: GPL-3.0-only
// Linear, zero-padded PSF convolution. RG packs R+iG; BA packs B+i0.
// A real scalar PSF filters all three linear radiance channels independently.
struct FFTParams { uint width,height,axis,span,inverse,bits,kernelSize,padding; };
float2 cmul(float2 a,float2 b){return float2(a.x*b.x-a.y*b.y,a.x*b.y+a.y*b.x);}
kernel void fftLoadScene(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=dest.get_width()||p.y>=dest.get_height())return;
    float3 rgb=p.x<source.get_width()&&p.y<source.get_height()?source.read(p).rgb:float3(0);
    dest.write(float4(rgb,0),p);
}
kernel void fftLoadKernel(const device float *weights [[buffer(0)]],constant FFTParams &u [[buffer(1)]],texture2d<float,access::write> dest [[texture(0)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=u.width||p.y>=u.height)return;
    int r=int(u.kernelSize/2),x=p.x<=u.width/2?int(p.x):int(p.x)-int(u.width), y=p.y<=u.height/2?int(p.y):int(p.y)-int(u.height);
    float v=abs(x)<=r&&abs(y)<=r?weights[(y+r)*int(u.kernelSize)+x+r]:0;
    dest.write(float4(v,0,v,0),p);
}
kernel void fftReorder(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],constant FFTParams &u [[buffer(0)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=u.width||p.y>=u.height)return;
    uint2 q=p;uint index=u.axis==0?p.x:p.y;uint reverse=reverse_bits(index)>>(32-u.bits);
    if(u.axis==0)q.x=reverse;else q.y=reverse;
    dest.write(source.read(q),p);
}
kernel void fftStage(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],constant FFTParams &u [[buffer(0)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=u.width||p.y>=u.height)return;
    uint n=u.axis==0?u.width:u.height,index=u.axis==0?p.x:p.y,halfSpan=u.span/2,jj=index%halfSpan,base=index/u.span*u.span;
    uint2 q=p,k=p;if(u.axis==0){q.x=base+jj;k.x=q.x+halfSpan;}else{q.y=base+jj;k.y=q.y+halfSpan;}
    float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(jj)/u.span;
    float2 w=float2(cos(angle),sin(angle));float4 a=source.read(q),b=source.read(k);
    float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
    float4 out=index%u.span<halfSpan?a+wb:a-wb;
    if(u.inverse!=0&&u.span==n)out/=float(n);dest.write(out,p);
}
// Bit reversal and up to ten radix-2 stages share one small local tile.
// Two outputs per lane avoid duplicate loads and twiddle evaluations. All lanes
// reach each barrier, including transforms smaller than a tile.
kernel void fftBlock(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],
                     constant FFTParams &u [[buffer(0)]],threadgroup float4 *tile [[threadgroup(0)]],
                     uint lane [[thread_index_in_threadgroup]],uint2 group [[threadgroup_position_in_grid]]) {
    uint n=u.axis==0?u.width:u.height, block=u.span, base=group.x*block;
    if(block==1){uint2 p=u.axis==0?uint2(0,group.y):uint2(group.y,0);dest.write(source.read(p),p);return;}
    for(uint i=lane;i<block;i+=block/2){
        uint reversed=reverse_bits(base+i)>>(32-u.bits);
        tile[i]=source.read(u.axis==0?uint2(reversed,group.y):uint2(group.y,reversed));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint span=2;span<=block;span*=2){
        uint halfSpan=span/2,j=lane%halfSpan,lo=lane/halfSpan*span+j,hi=lo+halfSpan;
        float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(j)/float(span);
        float2 w=float2(cos(angle),sin(angle));float4 a=tile[lo],b=tile[hi];
        float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
        threadgroup_barrier(mem_flags::mem_threadgroup);
        tile[lo]=a+wb;tile[hi]=a-wb;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=lane;i<block;i+=block/2){
        float4 value=tile[i];if(u.inverse!=0&&block==n)value/=float(n);
        dest.write(value,u.axis==0?uint2(base+i,group.y):uint2(group.y,base+i));
    }
}
kernel void fftStagePair(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],
                         constant FFTParams &u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    uint n=u.axis==0?u.width:u.height,index=u.axis==0?p.x:p.y;
    if(index>=n/2||(u.axis==0?p.y>=u.height:p.x>=u.width))return;
    uint halfSpan=u.span/2,j=index%halfSpan,lo=index/halfSpan*u.span+j;
    uint2 q=u.axis==0?uint2(lo,p.y):uint2(p.x,lo),k=q;
    if(u.axis==0)k.x+=halfSpan;else k.y+=halfSpan;
    float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(j)/float(u.span);
    float2 w=float2(cos(angle),sin(angle));float4 a=source.read(q),b=source.read(k);
    float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
    float factor=u.inverse!=0&&u.span==n?1.0/float(n):1.0;
    dest.write((a+wb)*factor,q);dest.write((a-wb)*factor,k);
}
kernel void fftMultiply(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::read> psf [[texture(1)]],texture2d<float,access::write> dest [[texture(2)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=dest.get_width()||p.y>=dest.get_height())return;
    float4 a=source.read(p),b=psf.read(p);dest.write(float4(cmul(a.xy,b.xy),cmul(a.zw,b.xy)),p);
}
kernel void fftFinish(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::read> scene [[texture(1)]],texture2d<float,access::write> dest [[texture(2)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=dest.get_width()||p.y>=dest.get_height())return;
    dest.write(float4(max(source.read(p).xyz,float3(0)),scene.read(p).a),p);
}

// Specialize away unused textures/branches. The butterflies and normalization
// are identical to fftBlock; only the full-texture boundary passes are fused.
constant uint fftBoundaryMode [[function_constant(0)]];
constant bool fftUseSIMD [[function_constant(1)]];
float4 fftBoundaryRead(texture2d<float,access::read> source,
                       texture2d<float,access::read> psf, uint2 p) {
    if(fftBoundaryMode==1) {
        float3 rgb=p.x<source.get_width()&&p.y<source.get_height()?source.read(p).rgb:float3(0);
        return float4(rgb,0);
    }
    float4 value=source.read(p);
    if(fftBoundaryMode==2) {
        float2 weight=psf.read(p).xy;
        return float4(cmul(value.xy,weight),cmul(value.zw,weight));
    }
    return value;
}
void fftCroppedWrite(float4 value, uint2 p, texture2d<float,access::write> dest,
                     texture2d<float,access::read> scene) {
    if(p.x<dest.get_width()&&p.y<dest.get_height())
        dest.write(float4(max(value.xyz,float3(0)),scene.read(p).a),p);
}
float4 fftRegisterButterfly(float4 value, float2 w, uint halfSpan, bool upper) {
    float4 other=simd_shuffle_xor(value,ushort(halfSpan));
    float4 a=upper?other:value,b=upper?value:other;
    float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
    return upper?a-wb:a+wb;
}
kernel void fftBlockFused(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],
                          texture2d<float,access::read> psf [[texture(2)]],texture2d<float,access::read> scene [[texture(3)]],
                          constant FFTParams &u [[buffer(0)]],threadgroup float4 *tile [[threadgroup(0)]],
                          uint lane [[thread_index_in_threadgroup]],uint2 group [[threadgroup_position_in_grid]],
                          uint simdWidth [[threads_per_simdgroup]]) {
    uint n=u.axis==0?u.width:u.height,block=u.span,base=group.x*block;
    if(block==1) {
        uint2 p=u.axis==0?uint2(0,group.y):uint2(group.y,0);
        float4 value=fftBoundaryRead(source,psf,p);
        if(fftBoundaryMode==3)fftCroppedWrite(value,p,dest,scene);else dest.write(value,p);
        return;
    }
    uint r0=reverse_bits(base+lane)>>(32-u.bits),r1=reverse_bits(base+lane+block/2)>>(32-u.bits);
    float4 v0=fftBoundaryRead(source,psf,u.axis==0?uint2(r0,group.y):uint2(group.y,r0));
    float4 v1=fftBoundaryRead(source,psf,u.axis==0?uint2(r1,group.y):uint2(group.y,r1));
    // Early butterflies exchange register values within a SIMD group. They
    // preserve the same a +/- cmul(b,w) order without threadgroup barriers.
    uint registerSpan=fftUseSIMD?min(simdWidth,block/2):1;
    for(uint span=2;span<=registerSpan;span*=2) {
        uint halfSpan=span/2,j=lane%halfSpan;
        float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(j)/float(span);
        float2 w=float2(cos(angle),sin(angle));
        bool upper=lane%span>=halfSpan;
        v0=fftRegisterButterfly(v0,w,halfSpan,upper);
        v1=fftRegisterButterfly(v1,w,halfSpan,upper);
    }
    tile[lane]=v0;tile[lane+block/2]=v1;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for(uint span=registerSpan*2;span<=block;span*=2) {
        uint halfSpan=span/2,j=lane%halfSpan,lo=lane/halfSpan*span+j,hi=lo+halfSpan;
        float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(j)/float(span);
        float2 w=float2(cos(angle),sin(angle));float4 a=tile[lo],b=tile[hi];
        float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
        threadgroup_barrier(mem_flags::mem_threadgroup);
        tile[lo]=a+wb;tile[hi]=a-wb;
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    for(uint i=lane;i<block;i+=block/2) {
        float4 value=tile[i];if(u.inverse!=0&&block==n)value/=float(n);
        uint2 p=u.axis==0?uint2(base+i,group.y):uint2(group.y,base+i);
        if(fftBoundaryMode==3)fftCroppedWrite(value,p,dest,scene);else dest.write(value,p);
    }
}
kernel void fftStagePairFinish(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> dest [[texture(1)]],
                               texture2d<float,access::read> scene [[texture(2)]],
                               constant FFTParams &u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    uint n=u.axis==0?u.width:u.height,index=u.axis==0?p.x:p.y;
    if(index>=n/2||(u.axis==0?p.y>=u.height:p.x>=u.width))return;
    uint halfSpan=u.span/2,j=index%halfSpan,lo=index/halfSpan*u.span+j;
    uint2 q=u.axis==0?uint2(lo,p.y):uint2(p.x,lo),k=q;
    if(u.axis==0)k.x+=halfSpan;else k.y+=halfSpan;
    float angle=(u.inverse!=0?2.0:-2.0)*M_PI_F*float(j)/float(u.span);
    float2 w=float2(cos(angle),sin(angle));float4 a=source.read(q),b=source.read(k);
    float4 wb=float4(cmul(b.xy,w),cmul(b.zw,w));
    float factor=u.inverse!=0&&u.span==n?1.0/float(n):1.0;
    fftCroppedWrite((a+wb)*factor,q,dest,scene);fftCroppedWrite((a-wb)*factor,k,dest,scene);
}
