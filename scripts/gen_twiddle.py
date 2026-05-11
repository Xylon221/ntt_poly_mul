#!/usr/bin/env python3
"""生成 NTT 加权方法的旋转因子 ROM hex 文件。

   Q = 12289, N = 1024
   psi = 7    (本原 2048 次单位根, psi^1024 = -1)
   omega = 49 (本原 1024 次单位根, omega = psi^2)

   正向 NTT 用 omega 为底:
     twiddle = omega^(j * 2^s) = psi^(2j * 2^s) = psi_pow[(j * 2^(s+1)) % 2048]

   逆向 NTT 用 omega^(-1) 为底:
     twiddle = omega_inv^(j * 2^s) = psi_inv_pow[(j * 2^(s+1)) % 2048]

   预旋乘表:  psi_j = psi^j          (j=0..1023)
   后旋乘表:  psi_inv_j = psi^(-j)    (j=0..1023)
"""

import os

Q = 12289
N = 1024
PSI = 7
OMEGA = (PSI * PSI) % Q    # 49

psi_inv = pow(PSI, -1, Q)
omega_inv = pow(OMEGA, -1, Q)

# 预计算 psi 的所有幂
psi_pow = [1] * 2048
for i in range(1, 2048):
    psi_pow[i] = (psi_pow[i-1] * PSI) % Q

psi_inv_pow = [1] * 2048
for i in range(1, 2048):
    psi_inv_pow[i] = (psi_inv_pow[i-1] * psi_inv) % Q

# 正向 NTT 旋转因子 (根 omega)
# Stage s (0..9): step = 2^(s+1), m = N / 2^(s+1)
fw_lines = []
for s in range(10):
    step = 1 << (s + 1)      # 2^(s+1): 2, 4, 8, ..., 1024
    m = N // (2 << s)         # N / 2^(s+1): 512, 256, ..., 1
    for j in range(m):
        tw = psi_pow[(j * step) % 2048]  # = omega^(j * 2^s)
        fw_lines.append(f"{tw:04x}")

# 逆向 NTT 旋转因子 (根 omega^(-1))
# RTL 按 stride 从小到大访问: stage 0 (stride=1), stage 1 (stride=2), ...
inv_lines = []
for s in range(10):
    stride = 1 << s           # 1, 2, 4, ..., 512
    step = 1 << (10 - s)      # 1024, 512, ..., 2
    for j in range(stride):
        tw = psi_inv_pow[(j * step) % 2048]
        inv_lines.append(f"{tw:04x}")

# 预旋乘表: psi^j (j=0..1023)
pre_lines = []
for j in range(N):
    pre_lines.append(f"{psi_pow[j]:04x}")

# 后旋乘表: psi^(-j) * N^(-1) (j=0..1023)
N_INV = pow(N, -1, Q)
post_lines = []
for j in range(N):
    val = (psi_inv_pow[j] * N_INV) % Q
    post_lines.append(f"{val:04x}")

outpath = os.path.join(os.path.dirname(__file__), "..", "sim", "twiddle.hex")
all_entries = fw_lines + inv_lines + pre_lines + post_lines
# 补齐至 4096 项 (ROM 深度 4096)
while len(all_entries) < 4096:
    all_entries.append("0000")
with open(outpath, "w") as f:
    f.write("\n".join(all_entries) + "\n")

print(f"已生成:")
print(f"  正向旋转因子:  {len(fw_lines)} 项")
print(f"  逆向旋转因子:  {len(inv_lines)} 项")
print(f"  预旋乘表:      {len(pre_lines)} 项")
print(f"  后旋乘表:      {len(post_lines)} 项")
print(f"  ROM 总大小:    {len(fw_lines + inv_lines + pre_lines + post_lines)} 项")
print(f"  ROM 深度:      4096 (12-bit 地址)")

# 验证
assert psi_pow[1024] == Q - 1, f"psi^1024 != -1 mod Q"
assert (OMEGA * omega_inv) % Q == 1, "omega * omega_inv != 1"
print(f"psi^1024 mod Q = {psi_pow[1024]} (期望 {Q-1}) ✓")
print(f"N^(-1) mod Q = {N_INV} ✓")
print(f"omega = {OMEGA}, omega^(-1) = {omega_inv} ✓")
