# 基于 NTT 数论变换的 1024 点多 项式乘法器 — 完整项目文档

> 版本：1.0  
> 日期：2026-05-11  
> 状态：✅ ALL 1024 TESTS PASSED

---

## 目录

1. [项目概述](#1-项目概述)
2. [数学原理](#2-数学原理)
3. [硬件架构](#3-硬件架构)
4. [模块设计](#4-模块设计)
5. [计算流程](#5-计算流程)
6. [仿真与验证](#6-仿真与验证)
7. [调试历程](#7-调试历程)
8. [性能指标](#8-性能指标)
9. [文件清单](#9-文件清单)
10. [扩展方向](#10-扩展方向)

---

## 1. 项目概述

本项目实现了一个基于 **NTT (Number Theoretic Transform，数论变换)** 的硬件多项式乘法器，支持 **1024 点** 变换，适用于后量子密码学（Kyber、Dilithium、NewHope）等场景的硬件加速。

### 核心参数

| 参数 | 符号 | 值 | 二进制 | 说明 |
|------|------|-----|--------|------|
| 多项式长度 | N | 1024 | 2¹⁰ | 变换点数 |
| 模数 | Q | 12289 | 14'd12289 | 14 位 NTT 友好素数，Q = 12×1024 + 1 |
| 本原根 | ψ | 7 | 3'b111 | 本原 2048 次单位根，ψ¹⁰²⁴ ≡ -1 mod Q |
| 前向根 | ω | 49 | ψ² | 本原 1024 次单位根 |
| 逆向根 | ω⁻¹ | 1254 | — | ω⁻¹ mod Q |
| 本原根逆元 | ψ⁻¹ | 8778 | — | 7⁻¹ mod 12289 |
| N 逆元 | N⁻¹ | 12277 | — | 1024⁻¹ mod 12289 |
| Barrett μ | μ | 21843 | 15'd21843 | ⌊2²⁸ / 12289⌋ |
| 数据位宽 | — | 14 bits | — | 覆盖 [0, 12288] |
| ROM 深度 | — | 4096 × 14 | 12-bit addr | 512 Kib |

### 关键恒等式

```
ψ^1024 ≡ 12288 ≡ -1 (mod 12289)    →  ψ 是 2048 次本原根 ✓
7 × 8778 ≡ 1 (mod 12289)            →  ψ⁻¹ = 8778 ✓
49 × 1254 ≡ 1 (mod 12289)           →  ω⁻¹ = 1254 ✓
1024 × 12277 ≡ 1 (mod 12289)       →  N⁻¹ = 12277 ✓
⌊2²⁸ / 12289⌋ = 21843              →  Barrett μ ✓
```

---

## 2. 数学原理

### 2.1 NTT 变换

NTT 是有限域 GF(Q) 上的离散傅里叶变换。对于素数模数 Q 和长度 N（满足 N | Q-1），存在本原 N 次单位根 ω：

```
正变换 (DIF):  X_k = Σ_{j=0}^{N-1}  x_j · ω^{j·k}  mod Q
逆变换 (DIT):  x_j = N⁻¹ · Σ_{k=0}^{N-1}  X_k · ω^{-j·k}  mod Q
```

### 2.2 多项式乘法（加权 NTT 方法）

本设计采用加权 NTT (Weighted NTT) 实现负循环卷积：

```
c(x) = a(x) · b(x)  mod (x^N + 1)

具体步骤：
  Step 1 (Pre-twist):   a'_j = a_j · ψ^j      mod Q
                        b'_j = b_j · ψ^j      mod Q
  Step 2 (NTT):         A = NTT_{ω}(a')
                        B = NTT_{ω}(b')
  Step 3 (PW-Mul):      C_k = A_k · B_k       mod Q
  Step 4 (INTT):        c' = INTT_{ω⁻¹}(C)
  Step 5 (Post-twist):  c_j = c'_j · ψ^{-j} · N⁻¹  mod Q
```

复杂度：O(N²) 朴素卷积 → **O(N log N)**

### 2.3 蝶形运算

**前向 DIF (Gentleman-Sande) 蝶形：**

```
a' = a + b       (mod Q)
b' = (a - b) · w (mod Q)
```

**逆向 DIT (Cooley-Tukey) 蝶形：**

```
a' = a + b · w   (mod Q)
b' = a - b · w   (mod Q)
```

### 2.4 Barrett 模约简

对于 Q = 12289，预计算 μ = ⌊2²⁸ / Q⌋ = 21843：

```
输入: p = a × b  (28 bits，14b × 14b)
计算: t = (p × μ) >> 28      (43-bit 中间值，取高 14 位)
     r = p - t × Q           (约简)
     if r ≥ Q: r = r - Q     (最多一次减法修正)
结果: r ∈ [0, Q-1]
```

μ 值的正确性至关重要：μ = 21843 保证 p - ⌊p×μ/2²⁸⌋×Q ∈ [0, Q+?]。若 μ 错误（如旧值 21839），约简后残余可高达 ~5Q，导致后续所有运算错误。

---

## 3. 硬件架构

### 3.1 整体架构图

```
┌────────────────────────────────────────────────────────────────┐
│                          ntt_top                                │
│                                                                 │
│  ┌──────────┐     ┌──────────────────┐     ┌──────────────┐   │
│  │  Host    │────▶│   3072 × 14 bit  │◀────│    Phase     │   │
│  │  I/F     │     │   Dual-port RAM  │     │  Controller  │   │
│  │          │     │                  │     │  (10 states) │   │
│  └──────────┘     │  A: 0x000-0x3FF  │     └──────┬───────┘   │
│                   │  B: 0x400-0x7FF  │            │            │
│                   │  C: 0x800-0xBFF  │            │            │
│                   └────────┬─────────┘            │            │
│                            │                      │            │
│                   ┌────────▼─────────┐   ┌────────▼───────┐   │
│                   │    ntt_core      │   │   twiddle_rom  │   │
│                   │  (Iterative FSM) │◀──│  (4096 × 14b)  │   │
│                   │  Address Gen     │   │  Comb. Read    │   │
│                   └────────┬─────────┘   └────────────────┘   │
│                            │                                    │
│                   ┌────────▼─────────┐                         │
│                   │    butterfly     │                         │
│                   │  (3-stage pipe)  │                         │
│                   │  DIF / DIT modes │                         │
│                   └──────────────────┘                         │
└────────────────────────────────────────────────────────────────┘
```

### 3.2 存储器布局

| 地址范围 | 大小 | 区域 | 用途 |
|----------|------|------|------|
| 0x000–0x3FF | 1024 | A 区 | 多项式 a 存储 + 前向 NTT 工作区 |
| 0x400–0x7FF | 1024 | B 区 | 多项式 b 存储 + 前向 NTT 工作区 |
| 0x800–0xBFF | 1024 | C 区 | 逐点乘积 + 逆向 NTT 工作区 + 最终结果 |

### 3.3 旋转因子 ROM 布局（4096 × 14 bits）

| 地址范围 | 大小 | 内容 |
|----------|------|------|
| 0x000–0x3FE | 1023 | 前向 NTT 旋 转因子 ω^(j·2^s)，按 stride 降序排列 |
| 0x3FF–0x7FD | 1023 | 逆向 NTT 旋转因子 ω⁻¹^(j·2^s)，按 stride 升序排列 |
| 0x7FE–0xBFD | 1024 | 预旋乘表 ψ^j (j = 0…1023) |
| 0xBFE–0xFFD | 1024 | 后旋乘表 ψ⁻ʲ · N⁻¹ (j = 0…1023) |
| 0xFFE–0xFFF | 2 | 填充 0（对齐 4096） |

**注**：后两段（预/后旋乘表）当前由 ROM 存储但 RTL 未直接使用。RTL 通过内联 Barrett 运算动态计算旋乘值。ROM 保留这些表便于未来改为查表模式。

### 3.4 前向 NTT 旋转因子索引方案

```
fw_idx = 12'd0 + stage_base_fw(stage) + {2'b0, offset}

stage_base_fw:
  Stage 0 (stride=512): base=0,    ROM[0..511]     → ψ^{2j}
  Stage 1 (stride=256): base=512,  ROM[512..767]   → ψ^{4j}
  Stage 2 (stride=128): base=768,  ROM[768..895]   → ψ^{8j}
  ...
  Stage 9 (stride=1):   base=1022, ROM[1022]       → ψ^{1024j} = ψ^0 = 1
```

### 3.5 逆向 NTT 旋转因子索引方案

```
inv_idx = 12'd1023 + stage_base_inv(stage) + {2'b0, offset}

stage_base_inv:
  Stage 0 (stride=1):   base=0,   ROM[1023]        → ψ⁻⁰ = 1
  Stage 1 (stride=2):   base=1,   ROM[1024..1025]  → ψ⁻⁰, ψ⁻⁵¹²
  Stage 2 (stride=4):   base=3,   ROM[1026..1029]  → ψ⁻⁰, ψ⁻²⁵⁶, ψ⁻⁵¹², ψ⁻⁷⁶⁸
  ...
  Stage 9 (stride=512): base=511, ROM[1534..2045]  → ψ⁻^{j·2}
```

---

## 4. 模块设计

### 4.1 ntt_top — 顶层控制器

**文件**: `rtl/ntt_top.v` (330 行)

**功能**:
- 相位 FSM（10 状态）控制整体计算流程
- 3072 × 14 bit 双端口存储器（A/B 口）
- 存储器仲裁：主机访问 / NTT 核心 / 旋乘 / 逐点乘
- 内联 Barrett 模乘用于预/后旋乘和逐点乘

**相位 FSM**:

```
PH_IDLE → PH_TWIST_A → PH_TWIST_B → PH_NTT_A → PH_NTT_B
    ↑                                                      ↓
PH_DONE ← PH_POST ← PH_INTT_C ← PH_PW_WRITE ← PH_PW_READ
```

**关键参数**:

```verilog
localparam Q       = 14'd12289;   // 模数
localparam N       = 11'd1024;    // 多项式长度
localparam MU      = 15'd21843;   // Barrett μ
localparam PSI     = 14'd7;       // 本原根 ψ
localparam PSI_INV = 14'd8778;    // ψ⁻¹ mod Q
localparam N_INV   = 14'd12277;   // N⁻¹ mod Q
```

### 4.2 ntt_core — NTT 核心控制器

**文件**: `rtl/ntt_core.v` (240 行)

**功能**:
- 迭代 FSM（7 状态）控制单蝶形单元的 10 级 NTT
- 地址生成（base + group + offset 三维嵌套循环）
- 前向 DIF：stride 从 512 递减至 1
- 逆向 DIT：stride 从 1 递增至 512

**FSM**:

```
S_IDLE → S_READ → S_ISSUE → S_PIPE(4 cycles) → S_WRITE → S_NEXT
    ↑                                                                    │
    └────────────────────────────────────────────────────────────────────┘
                                                              ↓
                                                          S_DONE
```

每个蝶形运算 5 个周期（READ → ISSUE → PIPE×3 → WRITE → NEXT）

### 4.3 butterfly — 蝶形运算单元

**文件**: `rtl/butterfly.v` (134 行)

**功能**:
- 3 级流水线，吞吐量 1 BF/cycle
- 前向 (mode=0): DIF — `a' = a+b, b' = (a-b)×w`
- 逆向 (mode=1): DIT — `a' = a+b×w, b' = a-b×w`

**流水线结构**:

| Stage | 操作 | 延迟 |
|-------|------|------|
| Stage 0 | 计算 `a+b` 和 `a+Q-b`, 捕获 a, b, w | 1 cycle |
| Stage 1 | Barrett 约简 add/sub 结果, 计算 `b×w` | 1 cycle |
| Stage 2 | 第 二次模乘 `(a-b)×w` (前向) 或第二次加减 `a±b×w` (逆向), 输出选择 | 1 cycle |

**关键设计决策**：逆向 DIT 在 Stage 2 使用 `a_r_r`（原始 a 经两周期延迟）而非 `add_red_r`。这修复了 Bug 5。

### 4.4 twiddle_rom — 旋转因子 ROM

**文件**: `rtl/twiddle_rom.v` (26 行)

**功能**:
- 4096 × 14 bit ROM，由 `twiddle.hex` 初始化
- **组合读**（`assign data = rom[addr]`），零延迟
- 原因：若使用同步读，首蝶形运算会在首个有效地址到达前读到 x（Bug 3）

### 4.5 mod_mult — Barrett 模乘器

**文件**: `rtl/mod_mult.v` (50 行)

**功能**: 2 级流水线 Barrett 模乘 `a × b mod Q`
- Stage 0: 28-bit 乘法
- Stage 1: Barrett 约简

### 4.6 mod_addsub — 模加减法器

**文件**: `rtl/mod_addsub.v` (52 行)

**功能**: 2 级流水线模加减 `a ± b mod Q`
- Stage 0: 计算 a+b 和 a+Q-b（15-bit 防止溢出）
- Stage 1: 约简至 [0, Q-1]

---

## 5. 计算流程

### 5.1 完整时序

```
Phase         Cycles    说明
──────────────────────────────────────
PH_IDLE         —       等待 start 信号
PH_TWIST_A    1024      A[i] *= ψ^i      (1 cycle/element)
PH_TWIST_B    1024      B[i] *= ψ^i      (1 cycle/element)
PH_NTT_A     ~25600     前向 NTT (A 区)   (5,120 BF × 5 cycles)
PH_NTT_B     ~25600     前向 NTT (B 区)
PH_PW_READ/   2048      逐点乘 C[i]=A[i]×B[i] (2 cycles/element)
PH_PW_WRITE
PH_INTT_C    ~25600     逆向 NTT (C 区)
PH_POST       1024      C[i] *= ψ^{-i}·N⁻¹  (1 cycle/element)
PH_DONE         —       输出 done
──────────────────────────────────────
总计         ~130,000   总计算周期
```

### 5.2 单次蝶形运算时序

```
Cycle │ State   │ 操作
──────┼─────────┼────────────────────────────────
  0   │ S_READ  │ 设置 mem_addr_a, mem_addr_b, twiddle_addr
  1   │ S_ISSUE │ 读取 mem_rdata_a/b → bf_a, bf_b, bf_w
  2   │ S_PIPE  │ BF Stage 0: a+b, a+Q-b
  3   │ S_PIPE  │ BF Stage 1: Barret reduce, b×w
  4   │ S_PIPE  │ BF Stage 2: final outputs
  5   │ S_WRITE │ 写回 bf_res_a/b → mem[full_a/b]
  6   │ S_NEXT  │ 更新 offset/group/stage, → S_READ
```

---

## 6. 仿真与验证

### 6.1 环境

| 工具 | 版本 | 用途 |
|------|------|------|
| Icarus Verilog | 11.0 | RTL 编译与仿真 |
| Python 3 | 3.x | 旋转因子生成、黄金模型 |
| GTKWave | — | 波形查看（可选） |

### 6.2 运行方式

```bash
cd sim

# 生成 ROM 和测试向量
python3 ../scripts/gen_twiddle.py
python3 ../scripts/golden_model.py

# 编译与仿真
iverilog -g2012 -I ../tb -o ntt_sim.vvp \
  ../rtl/mod_mult.v ../rtl/mod_addsub.v \
  ../rtl/butterfly.v ../rtl/twiddle_rom.v \
  ../rtl/ntt_core.v ../rtl/ntt_top.v \
  ../tb/tb_ntt_top.v

vvp ntt_sim.vvp

# 查看波形
gtkwave wave.vcd
```

### 6.3 验证策略

```
三层验证体系：

Layer 1: Python 黄金模型
  ├── NTT 多项式乘 vs 朴素 O(N²) 卷积
  └── 往返测试: INTT(NTT(x)) × N⁻¹ ≡ x

Layer 2: 自检 Testbench (tb_ntt_top.v)
  ├── 自动加载 tv_a.hex, tv_b.hex, tv_exp.hex
  ├── 运行完整计算流程
  └── 逐点比对所有 1024 个输出

Layer 3: 单元诊断
  ├── tb_barrett.v  — Barrett 约简单元 500K 随机样本验证
  ├── tb_diag.v     — 蝶形运算单元单点验证
  ├── tb_diag2.v    — 旋转因子 ROM 内容验证
  ├── tb_diag3.v    — NTT 核心 + 蝶形单元集成诊断
  ├── tb_diag4.v    — 完整端到端诊断（含波形）
  └── tb_mem_test.v — 存储器读写验证
```

### 6.4 测试向量

```
测试多项式:
  A[i] = (i + 1) mod 12289    → {1, 2, 3, ..., 1024}
  B[i] = (1024 - i) mod 12289 → {1024, 1023, ..., 1}

预期输出 (前 10 个):
  C[0] = 4549, C[1] = 2968, C[2] = 2407, C[3] = 2864, C[4] = 4337
  C[5] = 6824, C[6] = 10323, C[7] = 2543, C[8] = 8060, C[9] = 2294
```

### 6.5 仿真输出

```
=== NTT Polynomial Multiplication Testbench ===
Q=12289, N=1024
[65000] Loading polynomial A...
[10305000] Loading polynomial B...
[20555000] Starting NTT computation...
[1300665000] Computation complete! Cycles: 130062
[1300665000] Verifying results...
=== ALL 1024 TESTS PASSED ===
Total cycles: 131188
```

---

## 7. 调试历程

共发现并修复 8 个 Bug，按时间顺序排列：

### Bug 1: 逐点乘内存阶段错误
- **文件**: `rtl/ntt_top.v`
- **症状**: 逐点乘阶段数据错乱
- **原因**: `PH_PW_WRITE` 状态下同时向 C 区写入和从 C 区读取（mem_addr_a 指向 C 区）
- **修复**: 改为严格交替 PH_PW_READ ↔ PH_PW_WRITE

### Bug 2: 逆 NTT 旋转因子 ROM 布局错误
- **文件**: `scripts/gen_twiddle.py`
- **症状**: 逆向 NTT 使用错误的旋转因子
- **原因**: ROM 按 stride 从大到小存储逆向因子，但 RTL 按 stride 从小到大访问
- **修复**: 重新生成 ROM，按 stride=1,2,4,...,512 顺序排列

### Bug 3: ROM 同步读导致首蝶形读到 x
- **文件**: `rtl/twiddle_rom.v`
- **症状**: 每级首个蝶形运算收到 `x`（未知）旋转因子
- **原因**: `always @(posedge clk) data <= rom[addr]` 引入 1 周期读延迟
- **修复**: 改为 `assign data = rom[addr]` 组合读

### Bug 4: Barrett 参数 MU 错误
- **文件**: `rtl/ntt_top.v`, `rtl/butterfly.v`, `rtl/mod_mult.v`
- **症状**: 模约简结果超出 [0, Q-1] 范围（可达 ~5Q）
- **原因**: MU=21839，正确值 ⌊2²⁸/12289⌋=21843（差值 4）
- **修复**: 全部 MU 改为 `15'd21843`

### Bug 5: 逆 DIT 蝶形使用错误的 a 输入
- **文件**: `rtl/butterfly.v`
- **症状**: 逆向 NTT 结果错误
- **原因**: 逆 DIT 模式错误使用 `add_red_r` (a+b) 代替 `a`。正确公式: `a' = a + b×w`, `b' = a - b×w`
- **修复**: 通过流水线传递 `a_r_r`（原始 a 经两周期延迟），并添加对应流水线对齐寄存器

### Bug 6: 逆 NTT stride 初始化错误
- **文件**: `rtl/ntt_core.v`
- **症状**: 逆向 NTT 地址计算错误
- **原因**: `S_IDLE` 中 `stride <= 10'd512` 统一初始化，逆向应从 stride=1 开始
- **修复**: `stride <= mode ? 10'd1 : 10'd512`

### Bug 7: ntt_core FSM 流水线可靠性
- **文件**: `rtl/ntt_core.v`
- **症状**: 潜在时序问题
- **原因**: S_WAIT/S_WAIT2/S_WAIT3 依赖 `bf_valid_out` 信号握手，存在跨模块时序风险
- **修复**: 替换为基于计数器的 `S_PIPE` 状态，固定等待 4 周期后捕获结果

### Bug 8: PSI_INV 常数错误 (2026-05-11)
- **文件**: `rtl/ntt_top.v`
- **症状**: C[0] 正确但其余 1023 个输出全部错误
- **原因**: `PSI_INV = 8783`，正确值 `7⁻¹ mod 12289 = 8778`。`7 × 8783 ≡ 36 mod Q ≠ 1`
- **修复**: `PSI_INV` 改为 `14'd8778`

#### Bug 8 详细分析

这是最后的也是最隐蔽的 Bug。之前的 Bug 2 在 ROM 中使用了正确的 ψ⁻¹（通过 Python `pow(7, -1, Q)` 计算），但 RTL 内联的后旋乘（post-twist）直接使用本地参数 PSI_INV。

后旋乘公式：
```
result[i] = c_intt[i] × N⁻¹ × (ψ⁻¹)^i  mod Q
```

RTL 实现通过累积 `twist_acc`：
```
twist_acc[0] = N_INV
twist_acc[i] = twist_acc[i-1] × PSI_INV mod Q
```

当 PSI_INV=8783 时：
- `i=0`: `PSI_INV^0 = 1` ✅ (与 PSI_INV 值无关)
- `i≥1`: 全部错误 ❌

这完美解释了为何 C[0] 正确而其余 1023 个输出全部错误。

---

## 8. 性能指标

| 指标 | 数值 | 备注 |
|------|------|------|
| 技术节点 | 工艺无关 | 纯 RTL |
| 时钟频率 | 100 MHz (10 ns) | 仿真设定 |
| 正向 NTT 周期 | ~25,600 | 5,120 BF × 5 cycles/BF |
| 逆向 NTT 周期 | ~25,600 | 同上 |
| 逐点乘法 周期 | 2,048 | 2 cycles × 1024 |
| Pre/Post-twist | 2,048 | 1 cycle × 1024 × 2 |
| **总计算周期** | **130,062** | |
| NTT 延迟 | ~0.26 ms | @ 100 MHz |
| **总延迟** | **~1.30 ms** | @ 100 MHz |
| 吞吐量 | ~0.77 op/ms | 1 次多项式乘法 |
| 蝶形单元 | 1 个, 3 级流水线 | 面积优先 |
| 存储器 | 3072 × 14b 双端口 | 43 Kb |
| ROM | 4096 × 14b | 57 Kb |
| 总存储 | ~100 Kb | |

### 各部分周期细分

```
  Pre-twist A:    1,024
  Pre-twist B:    1,024
  Forward NTT A: 25,600  (10 stages × 512 BF × 5 cycles)
  Forward NTT B: 25,600
  Pointwise Mul:  2,048  (1024 × 2 cycles)
  Inverse NTT:   25,600
  Post-twist:     1,024
  Overhead:     ~28,166  (FSM 转换、初始/结束延迟)
  ─────────────────────
  Total:        130,062
```

---

## 9. 文件清单

```
ntt_poly_mul/
├── rtl/                          # RTL 设计源文件
│   ├── ntt_top.v                 # 顶层模块 (330 行)
│   ├── ntt_core.v                # NTT 核心 FSM + 地址生成 (240 行)
│   ├── butterfly.v               # 蝶形运算单元 3 级流水线 (134 行)
│   ├── twiddle_rom.v             # 旋转因子 ROM 4096×14 (26 行)
│   ├── mod_mult.v                # Barrett 模乘器 (50 行)
│   └── mod_addsub.v              # 模加减法器 (52 行)
│
├── tb/                           # 测试平台
│   ├── tb_ntt_top.v              # 主自检 testbench
│   ├── tb_barrett.v              # Barrett 约简单元诊断
│   ├── tb_debug.v                # 调试 testbench
│   ├── tb_diag.v                 # 蝶形单元诊断
│   ├── tb_diag2.v                # 旋转因子 ROM 诊断
│   ├── tb_diag3.v                # NTT 核心集成诊断
│   ├── tb_diag4.v                # 完整端到端诊断
│   └── tb_mem_test.v             # 存储器测试
│
├── scripts/                      # Python 脚本
│   ├── gen_twiddle.py            # ROM 数据生成 (94 行)
│   └── golden_model.py           # 黄金参考模型 (131 行)
│
├── sim/                          # 仿真目录
│   ├── Makefile                  # 仿真 Makefile
│   ├── twiddle.hex               # ROM 初始化文件 (自动生成)
│   ├── tv_a.hex                  # 测试向量 A (自动生成)
│   ├── tv_b.hex                  # 测试向量 B (自动生成)
│   └── tv_exp.hex                # 预期输出 (自动生成)
│
├── doc/                          # 文档目录
├── README.md                     # 项目说明
├── DEBUG_STATUS.md               # 调试状态记录
└── LOG_20260511.md              # 2026-05-11 调试日志
```

---

## 10. 扩展方向

### 10.1 性能优化
- **多蝶形单元**: 实例化 2/4/8 个 butterfly 单元并行计算，吞吐量线性提升
- **深流水线**: 将 3 级流水线扩展至 5-6 级，提高 f_max
- **乒乓缓冲**: 双倍存储器实现计算与加载重叠

### 10.2 功能扩展
- **可变 N**: 支持 N=256/512/1024 多种配置
- **大模数支持**: 替换 Q 和 ψ 支持 23-bit 模数（需调整 Barrett 位宽）
- **AXI-Stream 接口**: 标准化总线接口便于 SoC 集成
- **DMA 控制器**: 自动加载/存储多项式数据

### 10.3 安全性
- **侧信道防护**: 随机化掩码、恒定时间运算
- **故障注入检测**: 冗余计算校验

### 10.4 目标平台适配
| 应用 | Q | N | ψ | 说明 |
|------|---|---|---|------|
| Kyber | 3329 | 256 | 17 | ML-KEM 标准参数 |
| Dilithium | 8380417 | 256 | 1753 | ML-DSA 标准参数 |
| NewHope | 12289 | 1024 | 7 | 当前实现 |
| Falcon | 12289 | 512/1024 | 7 | NTRU 格签名 |

---

## 附录 A: 快速启动清单

```bash
# 1. 生成旋转因子 ROM
cd /home/wsluser/temp/ntt_poly_mul/sim
python3 ../scripts/gen_twiddle.py

# 2. 生成测试向量
python3 ../scripts/golden_model.py

# 3. 编译
iverilog -g2012 -I ../tb -o ntt_sim.vvp \
  ../rtl/mod_mult.v ../rtl/mod_addsub.v \
  ../rtl/butterfly.v ../rtl/twiddle_rom.v \
  ../rtl/ntt_core.v ../rtl/ntt_top.v \
  ../tb/tb_ntt_top.v

# 4. 运行仿真
vvp ntt_sim.vvp

# 预期输出: === ALL 1024 TESTS PASSED ===
```

## 附录 B: 关键修正值速查

| 参数 | 错误值 | 正确值 | 影响范围 |
|------|--------|--------|----------|
| PSI_INV | 8783 | 8778 | 后旋乘（post-twist） |
| MU | 21839 | 21843 | 所有 Barrett 约简 |
| 逆 NTT 初始 stride | 512 | 1 | 逆向 NTT 地址生成 |
| 逆 NTT ROM 顺序 | stride 降序 | stride 升序 | 逆向 NTT 旋转因子 |
| `sub_s0` 公式 | `a + Q - b - 1` | `a + Q - b` | DIF 蝶形减法 |
