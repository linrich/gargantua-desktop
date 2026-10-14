#!/usr/bin/env python3
# Copyright (C) 2026 linrich
# SPDX-License-Identifier: GPL-3.0-only
"""Independent finite-difference check of the transported coordinate Jacobi fields.
Uses the affine Hamiltonian CPU solver, not the GPU polynomial/AD equations.
"""
import json
import math
import sys
from pathlib import Path
from verify_kerr_reference import reference

root = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/verification')
data = json.loads((root/'ray-bundles.json').read_text())
comparisons = []
max_error = [0.0]*4
max_scaled = 0.0
convergence = 0.0
outcomes = True
center_errors=[0.0]*4
for c in data['cases']:
    b = c['gpu']
    if round(b[12]) != 1:
        continue
    center=reference(c)
    if center['status'] != 1:raise RuntimeError('CPU/GPU center visibility mismatch')
    delta=[abs(g-n) for g,n in zip(b[:4],center['hit'])]
    delta[1]=abs(math.atan2(math.sin(b[1]-center['hit'][1]),math.cos(b[1]-center['hit'][1])))
    center_errors=[max(a,v) for a,v in zip(center_errors,delta)]
    derivatives=[]
    for axis in [0,1]:
        numerical=[]
        for eps in [0.000024, 0.000012]:
            hits=[]
            for sign in [-1,1]:
                case=dict(c)
                case['screen']=c['screen'].copy()
                case['screen'][axis] += sign*eps
                ray=reference(case)
                if ray['status'] != 1:
                    outcomes=False
                    raise RuntimeError(f'Finite-difference beam crosses a visibility branch: {c["screen"]}')
                hits.append(ray['hit'])
            delta=[p-m for m,p in zip(*hits)]
            delta[1]=math.atan2(math.sin(delta[1]),math.cos(delta[1]))
            d=[v/(2*eps)*c['pixel_pitch']*(1 if axis==0 else -1) for v in delta]
            numerical.append(d)
        derivatives.append(numerical[1])
        for j in range(4):
            gpu=b[4+axis*4+j]
            error=abs(gpu-numerical[1][j])
            max_error[j]=max(max_error[j],error)
            max_scaled=max(max_scaled,error/max(0.05,abs(numerical[1][j])))
            convergence=max(convergence,abs(numerical[1][j]-numerical[0][j])/max(0.05,abs(numerical[1][j])))
    comparisons.append({'spin':c['spin'],'elevation':c['elevation'],'screen':c['screen'],
                        'gpu_dx':b[4:8],'gpu_dy':b[8:12],'cpu_derivatives':derivatives})
checks={'independent_center_paths_including_axis':all(e<t for e,t in zip(center_errors,[0.003,0.002,0.002,0.02])), 'same_disk_branches':outcomes, 'reference_step_convergence':convergence<0.001,
        'independent_jacobi_field_agreement':max_scaled<0.003, 'sufficient_disk_cases':len(comparisons)>40}
result={'method':'Double-precision affine Hamiltonian, two-sided finite differences at two spacings',
        'finite_difference_spacings':[0.000024,0.000012], 'disk_cases':len(comparisons),'max_absolute_errors_r_phi_g_delay_per_pixel':max_error,
        'max_error_scaled_by_max_abs_derivative_or_0.05':max_scaled,
        'center_errors_r_phi_g_delay':center_errors,'reference_convergence':convergence,'checks':checks,'cases':comparisons}
(root/'bundle-cpu-reference.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='cases'},indent=2))
if not all(checks.values()):raise SystemExit(1)
