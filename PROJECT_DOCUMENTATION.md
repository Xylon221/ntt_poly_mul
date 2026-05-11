# NTT 多项式乘法器 — 详细设计文档

> 版本：1.0 | 日期：2026-05-11 | 状态：✅ 全部 1024 项测试通过

## 1. 数学原理

### 1.1 NTT 变换

NTT 是有限域 GF(Q) 上的离散傅里叶变换，将 O(N²) 朴素卷积降至 **O(N log N)**。

```
正变换 (DIF):  X_k = Σ x_j · ω^{j·k} mod Q
逆变换 (DIT):  x_j = N⁻¹ · Σ X_k · ω^{-j·k} mod Q
```

### 1.2 加权 NTT 实现负循环卷积

本设计通过预/后旋乘 (twist) 实现 `c(x) = a(x)·b(x) mod (x^N + 1)`：

```
Step 1 (预旋乘):  a'_j = a_j · ψ^j,  b'_j = b_j · ψ^j
Step 2 (NTT):     A = NTT_ω(a'),    B = NTT_ω(b')
Step 3 (逐点乘):  C_k = A_k · B_k mod Q
Step 4 (INTT):    c' = INTT(C)
Step 5 (后旋乘):  c_j = c'_j · ψ^{-j} · N⁻¹ mod Q
```

### 1.3 蝶形运算公式

**前向 DIF (Gentleman-Sande):**
```
a' = a + b       (mod Q)
b' = (a - b) · w (mod Q)
```

**逆向 DIT (Cooley-Tukey):**
```
a' = a + b · w   (mod Q)
b' = a - b · w   (mod Q)
```

### 1.4 Barrett 模约简

对于 Q=12289，预计算 μ = ⌊2²⁸/Q⌋ = 21843：

```
t = (a·b × μ) >> 28
r = a·b - t × Q
if r ≥ Q: r = r - Q
```

μ=21843 时约简残余在 [0, Q+?] 内，最多一次减法修正。若 μ 值错误，约简后残余可达 ~5Q。

## 2. 模块设计

### 2.1 ntt_top — 顶层控制器 (330 行)

**相位 FSM (10 状态):**

```
PH_IDLE → PH_TWIST_A → PH_TWIST_B → PH_NTT_A → PH_NTT_B
    ↑                                                      ↓
PH_DONE ← PH_POST ← PH_INTT_C ← PH_PW_WRITE ← PH_PW_READ
```

- 3072×14bit 双端口存储器（A/B 口）
- 存储器仲裁：主机访问 / NTT 核心 / 旋乘 / 逐点乘
- 内联 Barrett 模乘用于预/后旋乘和逐点乘

### 2.2 ntt_core — NTT 核心控制器 (240 行)

**迭代 FSM (7 状态):**

```
S_IDLE → S_READ → S_ISSUE → S_PIPE(4 cycles) → S_WRITE → S_NEXT
    ↑                                                                    │
    └────────────────────────────────────────────────────────────────────┘
                                                              ↓
                                                          S_DONE
```

- 地址生成：base + group + offset 三维嵌套循环
- 正向 DIF：stride 从 512 递减至 1
- 逆向 DIT：stride 从 1 递增至 512
- 每蝶形 5 周期 (READ → ISSUE → PIPE×3 → WRITE → NEXT)，无气泡

### 2.3 butterfly — 蝶形运算单元 (134 行)

**3 级流水线结构：**

| Stage | 操作 | 延迟 |
|-------|------|------|
| Stage 0 | 计算 a+b 和 a+Q-b，捕获 a,b,w | 1 cycle |
| Stage 1 | Barrett 约简 add/sub 结果，计算 b×w | 1 cycle |
| Stage 2 | 正向: (a-b)×w / 逆向: a±b×w，输出选择 | 1 cycle |

**关键设计**：逆向 DIT 在 Stage 2 使用 `a_r_r`（原始 a 经两周期延迟），而非 `add_red_r`（a+b 约简值）。

### 2.4 twiddle_rom — 旋转因子 ROM (26 行)

4096×14bit ROM，由 `twiddle.hex` 初始化。**组合读** (`assign data = rom[addr]`)，零延迟。

| 地址范围 | 内容 |
|----------|------|
| 0x000–0x3FE | 正向 NTT 旋转因子 (1023 项，按 stride 降序) |
| 0x3FF–0x7FD | 逆向 NTT 旋转因子 (1023 项，按 stride 升序) |
| 0x7FE–0xBFD | 预旋乘表 ψ^j (1024 项) |
| 0xBFE–0xFFD | 后旋乘表 ψ^(-j)·N^(-1) (1024 项) |

### 2.5 mod_mult / mod_addsub

- `mod_mult.v` (50 行): 2 级流水线 Barrett 模乘
- `mod_addsub.v` (52 行): 2 级流水线模加减

## 3. 旋转因子索引

### 正向 NTT (stride 降序)

```
fw_idx = 0 + stage_base_fw(stage) + offset

Stage 0 (stride=512): ROM[0..511]
Stage 1 (stride=256): ROM[512..767]
...
Stage 9 (stride=1):   ROM[1022]
```

### 逆向 NTT (stride 升序)

```
inv_idx = 1023 + stage_base_inv(stage) + offset

Stage 0 (stride=1):   ROM[1023]
Stage 1 (stride=2):   ROM[1024..1025]
...
Stage 9 (stride=512): ROM[1534..2045]
```

## 4. 单次蝶形运算时序

```
Cycle │ State   │ 操作
──────┼─────────┼────────────────────
  0   │ S_READ  │ 设置 mem_addr_a/b, twiddle_addr
  1   │ S_ISSUE │ 读取 mem_rdata → bf_a, bf_b, bf_w
  2   │ S_PIPE  │ BF Stage 0: a+b, a+Q-b
  3   │ S_PIPE  │ BF Stage 1: Barrett 约简, b×w
  4   │ S_PIPE  │ BF Stage 2: 最终输出
  5   │ S_WRITE │ 写回 bf_res_a/b → mem
  6   │ S_NEXT  │ 更新 offset/group/stage → S_READ
```

## 5. 验证体系

三层验证：

```
Layer 1: Python 黄金模型
  ├── NTT 往返: INTT(NTT(x)) × N⁻¹ ≡ x
  └── 交叉验证: NTT 多项式乘 vs 朴素 O(N²) 卷积

Layer 2: 自检 Testbench (tb_ntt_top.v)
  ├── 自动加载 tv_a.hex, tv_b.hex, tv_exp.hex
  ├── 运行完整计算流程
  └── 逐点比对 1024 个输出

Layer 3: 单元诊断
  ├── tb_barrett.v — Barrett 约简 500K 随机验证
  ├── tb_diag.v    — 蝶形单元单点验证
  ├── tb_diag2.v   — ROM 内容验证
  ├── tb_diag3.v   — Core + BF 集成诊断
  ├── tb_diag4.v   — 完整端到端诊断
  └── tb_mem_test.v — 存储器读写验证
```

### 测试向量

```
A[i] = (i + 1) mod 12289    → {1, 2, 3, ..., 1024}
B[i] = (1024 - i) mod 12289 → {1024, 1023, ..., 1}
```

## 6. 文件清单

```
ntt_poly_mul/
├── README.md                     # 项目总览 + 实验结果
├── PROJECT_DOCUMENTATION.md      # 本详细设计文档
├── .gitignore
├── rtl/
│   ├── ntt_top.v                 # 顶层模块 (330 行)
│   ├── ntt_core.v                # NTT 核心 FSM (240 行)
│   ├── butterfly.v               # 蝶形单元 (134 行)
│   ├── twiddle_rom.v             # 旋转因子 ROM (26 行)
│   ├── mod_mult.v                # Barrett 模乘器 (50 行)
│   └── mod_addsub.v              # 模加减法器 (52 行)
├── tb/
│   ├── tb_ntt_top.v              # 主自检测试
│   ├── tb_barrett.v              # Barrett 单元测试
│   ├── tb_debug.v                # 调试 testbench
│   ├── tb_diag.v ~ tb_diag4.v   # 逐级诊断
│   └── tb_mem_test.v             # 存储器测试
└── scripts/
    ├── gen_twiddle.py             # ROM 生成 (94 行)
    └── golden_model.py            # 黄金模型 (131 行)
```

## 7. 目标平台适配

| 应用 | Q | N | ψ | 说明 |
|------|---|---|---|------|
| Kyber | 3329 | 256 | 17 | ML-KEM |
| Dilithium | 8380417 | 256 | 1753 | ML-DSA |
| NewHope | 12289 | 1024 | 7 | 当前实现 |
| Falcon | 12289 | 512/1024 | 7 | NTRU 格签名 |
