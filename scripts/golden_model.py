#!/usr/bin/env python3
"""Golden reference model for NTT polynomial multiplication.

   Uses weighted NTT approach (standard for negacyclic convolution):
   1. Pre-twist:  a_j = a_j * psi^j
   2. NTT with root omega = psi^2
   3. Pointwise multiply
   4. INTT with root omega^(-1)
   5. Post-twist + scale: c_j = c_j * psi^(-j) * N^(-1)

   Generates test vector hex files for Verilog $readmemh.
"""

import os

Q = 12289
N = 1024
PSI = 7
OMEGA = (PSI * PSI) % Q   # 49

psi_inv = pow(PSI, -1, Q)
omega_inv = pow(OMEGA, -1, Q)
N_INV = pow(N, -1, Q)

# Pre-compute powers
psi_pow = [1] * 2048
for i in range(1, 2048):
    psi_pow[i] = (psi_pow[i-1] * PSI) % Q

psi_inv_pow = [1] * 2048
for i in range(1, 2048):
    psi_inv_pow[i] = (psi_inv_pow[i-1] * psi_inv) % Q


def ntt_forward(a):
    """DIF forward NTT with root omega=49 (primitive N-th root)."""
    a = list(a)
    stride = N // 2
    for s in range(10):
        m = stride
        step = 1 << (s + 1)
        for g in range(1 << s):
            base = g * 2 * m
            for j in range(m):
                idx_a = base + j
                idx_b = idx_a + m
                u = a[idx_a]
                v = a[idx_b]
                w = psi_pow[(j * step) % 2048]
                a[idx_a] = (u + v) % Q
                a[idx_b] = ((u - v) * w) % Q
        stride //= 2
    return a


def ntt_inverse(a):
    """DIT inverse NTT with root omega^(-1)."""
    a = list(a)
    stride = 1
    for s in range(10):
        m = stride
        step = 1 << (10 - s)
        for g in range(1 << (9 - s)):
            base = g * 2 * m
            for j in range(m):
                idx_a = base + j
                idx_b = idx_a + m
                u = a[idx_a]
                v = a[idx_b]
                w = psi_inv_pow[(j * step) % 2048]
                a[idx_a] = (u + v * w) % Q
                a[idx_b] = (u - v * w) % Q
        stride *= 2
    return a


def poly_mul_ntt(a, b):
    """Weighted NTT polynomial multiplication."""
    a_tw = [(a[i] * psi_pow[i]) % Q for i in range(N)]
    b_tw = [(b[i] * psi_pow[i]) % Q for i in range(N)]
    A = ntt_forward(a_tw)
    B = ntt_forward(b_tw)
    C = [(A[i] * B[i]) % Q for i in range(N)]
    c_raw = ntt_inverse(C)
    c = [(c_raw[i] * psi_inv_pow[i % 2048] * N_INV) % Q for i in range(N)]
    return c


def poly_mul_naive(a, b):
    """Naive O(N^2) negacyclic convolution for verification."""
    c = [0] * N
    for i in range(N):
        for j in range(N):
            k = i + j
            if k < N:
                c[k] = (c[k] + a[i] * b[j]) % Q
            else:
                c[k - N] = (c[k - N] - a[i] * b[j]) % Q
    return c


def write_hex(filename, data):
    with open(filename, "w") as f:
        for v in data:
            f.write(f"{v:04x}\n")


if __name__ == "__main__":
    # Test polynomials
    a = [(i + 1) % Q for i in range(N)]          # 1, 2, 3, ..., 1024
    b = [(N - i) % Q for i in range(N)]           # 1024, 1023, ..., 1

    c_ntt = poly_mul_ntt(a, b)
    c_naive = poly_mul_naive(a, b)
    assert c_ntt == c_naive, "NTT result does not match naive convolution!"

    # Round-trip test
    rt_raw = ntt_inverse(ntt_forward([i % Q for i in range(N)]))
    rt = [(rt_raw[i] * N_INV) % Q for i in range(N)]
    assert rt[:10] == list(range(10)), f"Round-trip FAILED: {rt[:10]}"

    print("Round-trip OK ✓")
    print("NTT golden model matches naive convolution ✓")

    # Write hex files for testbench
    base = os.path.dirname(__file__)
    write_hex(os.path.join(base, "..", "sim", "tv_a.hex"), a)
    write_hex(os.path.join(base, "..", "sim", "tv_b.hex"), b)
    write_hex(os.path.join(base, "..", "sim", "tv_exp.hex"), c_ntt)
    print("Test vector hex files written ✓")
