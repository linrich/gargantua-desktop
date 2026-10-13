#!/usr/bin/env python3
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
"""Independent double-precision Boyer-Lindquist super-Hamiltonian reference.

The GPU uses inverse-radius/polar polynomials in reverse Mino time. This
reference instead evolves r, theta and canonical momenta in affine time,
including off-constraint derivatives of Sigma, to cross-check disk events.
Only Python's standard library is used; no network or desktop access.
"""
import json
import math
from pathlib import Path
import sys


def isco(a):
    # Independently solve marginal radial stability, rather than reuse Z1/Z2.
    a = abs(a)
    lo, hi = 1.0, 6.0
    for _ in range(70):
        r = (lo + hi) / 2
        f = r*r - 6*r + 8*a*math.sqrt(r) - 3*a*a
        if f > 0: hi = r
        else: lo = r
    return (lo + hi)/2


def reference(case):
    a = case['spin']
    x, y = case['screen']
    theta = math.pi/2 - math.radians(case['elevation'])
    r = 64.0
    st, ct = math.sin(theta), math.cos(theta)
    rho = math.sqrt(r*r+a*a*ct*ct)
    delta = r*r-2*r+a*a
    sigma = math.sqrt((r*r+a*a)**2-a*a*delta*st*st)
    lapse, omega, varpi = rho*math.sqrt(delta)/sigma, 2*a*r/sigma**2, sigma*st/rho
    norm = math.sqrt(1.8**2+(x*1.04)**2+(y*1.04)**2)
    nr, nt, np = 1.8/norm, y*1.04/norm, -x*1.04/norm
    ef = 1/(lapse+omega*varpi*np)
    b = ef*varpi*np
    state = [r, theta, ef*rho/math.sqrt(delta)*nr, ef*rho*nt, 0.0, 0.0]
    inner = isco(a)
    horizon = 1+math.sqrt(1-a*a)

    def rhs(s):
        r, t, pr, pt, phi, time = s
        sn, cs = math.sin(t), math.cos(t)
        sn = math.copysign(max(abs(sn),1e-10),sn)
        rr = r*r+a*a*cs*cs  # Sigma (rho squared in James et al.)
        d = r*r-2*r+a*a
        p = r*r+a*a-a*b
        h2 = d*pr*pr+pt*pt-p*p/d+(b/sn-a*sn)**2
        return [d*pr/rr, pt/rr,
                (-(r-1)*pr*pr+2*r*p/d-(r-1)*p*p/(d*d))/rr+r*h2/(rr*rr),
                cs*(b*b/sn**3-a*a*sn)/rr-a*a*cs*sn*h2/(rr*rr),
                (b/sn**2-a+a*p/d)/rr,
                (a*(b-a*sn*sn)+(r*r+a*a)*p/d)/rr]

    def step(s,h):
        k1 = rhs(s)
        k2 = rhs([v+h*k/2 for v,k in zip(s,k1)])
        k3 = rhs([v+h*k/2 for v,k in zip(s,k2)])
        k4 = rhs([v+h*k for v,k in zip(s,k3)])
        return [v+h*(v1+2*v2+2*v3+v4)/6 for v,v1,v2,v3,v4 in zip(s,k1,k2,k3,k4)]

    for count in range(50000):
        r,theta = state[:2]
        if r < horizon+0.015: return {'status':2,'steps':count}
        if r > 90: return {'status':3,'steps':count}
        f = rhs(state)
        h = -min(0.008*r,0.008/max(abs(f[1])+abs(f[4]),1e-4),
                 0.025*(r-horizon)/max(abs(f[0]),0.01))
        # Resolve the polar turning point even when phi' is still small before
        # the close approach. Fractional theta control prevents a nonmeridional
        # ray from numerically jumping through the BL coordinate pole.
        if abs(b) > 1e-10:
            h = -min(abs(h), 0.02*max(abs(math.sin(theta)),1e-12)/max(abs(f[1]),1e-12))
        nxt = step(state,h)
        if (theta-math.pi/2)*(nxt[1]-math.pi/2) < 0:
            fraction = (theta-math.pi/2)/(theta-nxt[1])
            event = step(state,h*fraction)
            for _ in range(4):
                slope = rhs(event)[1]
                if abs(slope)>1e-12:
                    fraction = max(0,min(1,fraction-(event[1]-math.pi/2)/(h*slope)))
                    event = step(state,h*fraction)
            radius = event[0]
            if case['disk'] and inner <= radius <= 23:
                sense = -1 if a < 0 else 1
                om = sense/(radius**1.5+abs(a))
                ut = (radius**1.5+abs(a))/math.sqrt(radius**3-3*radius*radius+2*abs(a)*radius**1.5)
                return {'status':1,'hit':[radius,event[4],ef/(ut*(1-om*b)),-event[5]],'steps':count}
        # Canonical polar-chart transition for exactly meridional rays. This
        # preserves the physical direction and momentum when theta crosses a pole.
        if nxt[1] < 0:
            nxt[1] = -nxt[1]; nxt[3] = -nxt[3]; nxt[4] += math.pi
        elif nxt[1] > math.pi:
            nxt[1] = 2*math.pi-nxt[1]; nxt[3] = -nxt[3]; nxt[4] += math.pi
        state = nxt
    return {'status':4,'steps':50000}


def main():
    path = Path(sys.argv[1] if len(sys.argv)>1 else 'build/verification/kerr-geodesics.json')
    data = json.loads(path.read_text())
    comparisons=[]
    maxima=[0.0]*4
    outcomes=True
    for c in data['cases']:
        if not c['cpu_reference']: continue
        ref=reference(c)
        gpu=c['gpu']
        outcomes &= ref['status']==round(gpu[4])
        errors=None
        if ref['status']==1 and round(gpu[4])==1:
            hit=ref['hit']
            errors=[abs(gpu[0]-hit[0]),abs(math.atan2(math.sin(gpu[1]-hit[1]),math.cos(gpu[1]-hit[1]))),
                    abs(gpu[2]-hit[2]),abs(gpu[3]-hit[3])]
            maxima=[max(a,b) for a,b in zip(maxima,errors)]
        comparisons.append({'spin':c['spin'],'screen':c['screen'],'cpu':ref,'gpu':gpu[:5],'absolute_errors':errors})
    thresholds=[0.003,0.002,0.002,0.02]
    checks={'all_outcomes_match':outcomes,'independent_hamiltonian_agrees':all(x<t for x,t in zip(maxima,thresholds))}
    result={'reference':'Double precision BL super-Hamiltonian in affine time',
            'compared_rays':len(comparisons),'max_errors_r_phi_g_delay':maxima,
            'thresholds_r_phi_g_delay':thresholds,'checks':checks,'cases':comparisons}
    (path.parent/'kerr-cpu-reference.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2))
    if not all(checks.values()):sys.exit(1)

if __name__=='__main__':main()
