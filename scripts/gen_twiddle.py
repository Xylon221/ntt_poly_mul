#!/usr/bin/env python3
"""Generate twiddle factor ROM hex file for NTT (weighted approach).

   Q = 12289, N = 1024
   psi = 7    (primitive 2048-th root of unity, psi^1024 = -1)
   omega = 49 (primitive 1024-th root of unity, omega = psi^2)

   Forward NTT uses omega as base twiddle:
     twiddle = omega^(j * 2^s) = psi^(2j * 2^s)
     = psi_pow[(j * 2^(s+1)) % 2048]

   Inverse NTT uses omega^(-1) as base twiddle:
     twiddle = omega_inv^(j * 2^s) = psi_inv^(2j * 2^s)
     = psi_inv_pow[(j * 2^(s+1)) % 2048]

   Pre-twist table:  psi_j = psi^j          for j=0..1023
   Post-twist table: psi_inv_j = psi^(-j)   for j=0..1023
"""

import os

Q = 12289
N = 1024
PSI = 7
OMEGA = (PSI * PSI) % Q    # 49

psi_inv = pow(PSI, -1, Q)
omega_inv = pow(OMEGA, -1, Q)

# Pre-compute all powers of psi
psi_pow = [1] * 2048
for i in range(1, 2048):
    psi_pow[i] = (psi_pow[i-1] * PSI) % Q

psi_inv_pow = [1] * 2048
for i in range(1, 2048):
    psi_inv_pow[i] = (psi_inv_pow[i-1] * psi_inv) % Q

# Forward twiddles for NTT with root omega
# Stage s (0..9): step = 2^(s+1), m = N / 2^(s+1)
fw_lines = []
for s in range(10):
    step = 1 << (s + 1)      # 2^(s+1): 2, 4, 8, ..., 1024
    m = N // (2 << s)         # N / 2^(s+1): 512, 256, ..., 1
    for j in range(m):
        tw = psi_pow[(j * step) % 2048]  # = omega^(j * 2^s)
        fw_lines.append(f"{tw:04x}")

# Inverse twiddles for INTT with root omega^(-1)
# RTL accesses in small-stride-first order: stage 0 (stride=1), stage 1 (stride=2), ...
inv_lines = []
for s in range(10):
    stride = 1 << s           # 1, 2, 4, ..., 512
    step = 1 << (10 - s)      # 1024, 512, ..., 2
    for j in range(stride):
        tw = psi_inv_pow[(j * step) % 2048]  # = omega_inv^(j * N/(2*stride))
        inv_lines.append(f"{tw:04x}")

# Pre-twist table: psi^j for j=0..1023
pre_lines = []
for j in range(N):
    pre_lines.append(f"{psi_pow[j]:04x}")

# Post-twist table: psi^(-j) * N^(-1) pre-computed
N_INV = pow(N, -1, Q)
post_lines = []
for j in range(N):
    val = (psi_inv_pow[j] * N_INV) % Q
    post_lines.append(f"{val:04x}")

outpath = os.path.join(os.path.dirname(__file__), "..", "sim", "twiddle.hex")
total_entries = len(fw_lines) + len(inv_lines) + len(pre_lines) + len(post_lines)
all_entries = fw_lines + inv_lines + pre_lines + post_lines
# Pad to 4096 entries (ROM is 4096-deep)
while len(all_entries) < 4096:
    all_entries.append("0000")
with open(outpath, "w") as f:
    f.write("\n".join(all_entries) + "\n")

print(f"Generated:")
print(f"  Forward twiddles:  {len(fw_lines)} entries")
print(f"  Inverse twiddles:  {len(inv_lines)} entries")
print(f"  Pre-twist table:   {len(pre_lines)} entries")
print(f"  Post-twist table:  {len(post_lines)} entries")
print(f"  Total ROM size:    {len(fw_lines + inv_lines + pre_lines + post_lines)} entries")
print(f"  ROM depth needed:  4096 (12-bit address)")

# Verify
assert psi_pow[1024] == Q - 1, f"psi^1024 != -1 mod Q"
assert (OMEGA * omega_inv) % Q == 1, "omega * omega_inv != 1"
print(f"psi^1024 mod Q = {psi_pow[1024]} (expected {Q-1}) ✓")
print(f"N^(-1) mod Q = {N_INV} ✓")
print(f"omega = {OMEGA}, omega^(-1) = {omega_inv} ✓")
