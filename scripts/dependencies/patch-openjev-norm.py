#!/usr/bin/env python3
"""Carry the two-line Qwen 3.5 normalization correction at the pinned revision.

HF's l2norm adds epsilon to the SUM of squares. MLX RMSNorm adds it to
MEAN squares. Divide RMSNorm epsilon by head width before converting to L2.
The package's original q/k normalization otherwise changes typed decision
probabilities beyond our 0.001 comparison tolerance.
"""
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'Libraries/MLXLLM/Models/Qwen35.swift'
s = p.read_text()
for name in ('q', 'k'):
    original = f'MLXFast.rmsNorm({name}, weight: MLXArray.mlxNone, eps: 1e-6)'
    corrected = f'MLXFast.rmsNorm({name}, weight: MLXArray.mlxNone, eps: 1e-6 / Float(headKDim))'
    if corrected not in s:
        if s.count(original) != 1:
            raise SystemExit('Pinned Qwen normalization source changed; refusing an ambiguous patch')
        s = s.replace(original, corrected)
p.write_text(s)
