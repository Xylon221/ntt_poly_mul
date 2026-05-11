# 基于 NTT 数论变换的多项式乘法工程

## 项目概述

本项目实现了一个基于 **NTT (Number Theoretic Transform，数论变换)** 的硬件多项式乘法器，支持 **1024 点** 变换，适用于后量子密码学（如 Kyber、Dilithium、NewHope 等）、同态加密等场景的硬件加速。

### 核心参数

| 参数 | 值 | 说明 |
|------|-----|------|
| N (点数) | 1024 | 多项式最大次数 |
| Q (模数) | 12289 | 14 位素数，Q = 12×1024 + 1 |
| ψ (本原根) | 7 | 本原 2048 次单位根 |
| N⁻¹ (逆元) | 12277 | 1024⁻¹ mod 12289 |
| 数据位宽 | 14 bits | 覆盖 [0, 12288] |

### 数学原理

**NTT** 是有限域上的快速傅里叶变换。对于素数模数 Q 和多项式长度 N（满足 N | Q-1），存在本原 N 次单位根 ω，使得：

```
X_k = Σ x_j · ω^(j·k)  mod Q    (正向 NTT)
x_j = N⁻¹ · Σ X_k · ω^(-j·k)  mod Q    (逆向 NTT)
```

**多项式乘法的 NTT 加速：**

```
c(x) = a(x) · b(x)  mod (x^N + 1)

步骤：
1. A = NTT(a)     // 正向变换
2. B = NTT(b)     // 正向变换
3. C = A ⊙ B      // 逐点模乘
4. c = INTT(C)    // 逆向变换 + 缩放
```

将 O(N²) 的朴素卷积降至 O(N log N)。

---

## 目录结构

```
ntt_poly_mul/
├── README.md                  # 项目文档
├── rtl/                       # RTL 设计文件
│   ├── ntt_top.v              # 顶层模块（相位控制 + 存储管理）
│   ├── ntt_core.v             # NTT 核心控制器（FSM + 地址生成）
│   ├── butterfly.v            # 蝴蝶运算单元（3 级流水线）
│   ├── mod_mult.v             # Barrett 模乘器
│   ├── mod_addsub.v           # 模加减法器
│   └── twiddle_rom.v          # 旋转因子 ROM
├── tb/
│   ├── tb_ntt_top.v           # 自检验证 testbench
│   └── testvec.vh             # 测试向量（自动生成）
├── sim/
│   ├── Makefile               # Icarus Verilog 仿真脚本
│   └── twiddle.hex            # 旋转因子 ROM 数据（自动生成）
├── scripts/
│   ├── gen_twiddle.py         # 旋转因子生成脚本
│   └── golden_model.py        # Python 黄金参考模型
└── doc/
    └── (设计文档)
```

---

## 硬件架构

### 整体架构

```
┌──────────────────────────────────────────────────────────┐
│                        ntt_top                            │
│  ┌─────────┐   ┌──────────┐   ┌────────────┐            │
│  │  Host   │──▶│   3072    │◀──│   Phase    │            │
│  │   I/F   │   │  × 14b   │   │ Controller │            │
│  │         │   │   MEM     │   │            │            │
│  └─────────┘   │ A B  C   │   └─────┬──────┘            │
│                └────┬─────┘         │                    │
│                     │               │                    │
│                ┌────▼─────┐   ┌─────▼──────┐            │
│                │ ntt_core │◀──│  twiddle   │            │
│                │  (FSM)   │   │    ROM     │            │
│                └────┬─────┘   └────────────┘            │
│                     │                                    │
│                ┌────▼─────┐                              │
│                │ butterfly │                              │
│                │ (3-stage) │                              │
│                └──────────┘                              │
└──────────────────────────────────────────────────────────┘
```

### 存储布局（3072 × 14 bits）

| 地址范围 | 区域 | 用途 |
|---------|------|------|
| 0x000–0x3FF | A 区 | 多项式 a 的存储及正向 NTT 工作区 |
| 0x400–0x7FF | B 区 | 多项式 b 的存储及正向 NTT 工作区 |
| 0x800–0xBFF | C 区 | 逐点乘积及逆向 NTT 工作区 |

### 蝶形运算单元（3 级流水线）

**正向 NTT (DIF / Gentleman-Sande 蝶形)：**
```
a' = a + b       (mod Q)
b' = (a - b) · w (mod Q)
```

**逆向 NTT (DIT / Cooley-Tukey 蝶形)：**
```
a' = a + b · w   (mod Q)
b' = a - b · w   (mod Q)
```

### 模乘器（Barrett 约简）

对于 Q = 12289，预计算 μ = ⌊2²⁸/Q⌋ = 21843：

```
t = a · b                  (28 bits)
m = (t · μ) >> 28          (高位截取)
r = t - m · Q              (约简)
if r ≥ Q: r = r - Q        (最终修正)
```

---

## 计算流程

1. **Host 加载** — 通过 host 接口向 MEM[0x000] 和 MEM[0x400] 分别写入多项式 a 和 b
2. **NTT(a)** — 对 A 区执行正向 DIF NTT（10 级，每级 512 次蝶形）
3. **NTT(b)** — 对 B 区执行正向 DIF NTT
4. **逐点乘** — C[i] = A[i] × B[i] mod Q（2 周期/元素）
5. **INTT(C)** — 对 C 区执行逆向 DIT NTT
6. **缩放** — C[i] = C[i] × N⁻¹ mod Q
7. **Host 读取** — 从 MEM[0x800] 读取最终结果

---

## 仿真与验证

### 环境要求

- **Icarus Verilog** (`iverilog` + `vvp`)
- **Python 3**（用于生成旋转因子和测试向量）
- **GTKWave**（可选，查看波形）

### 运行仿真

```bash
cd sim
make twiddle.hex        # 生成旋转因子 ROM
make testvec.vh         # 生成测试向量
make compile            # 编译
make run                # 运行仿真
make view               # 查看波形
# 或一键运行
make all
```

### 验证方法

- **Python 黄金模型** (`scripts/golden_model.py`)：实现与 RTL 完全一致的算法，同时提供朴素 O(N²) 卷积作为交叉验证
- **自检 Testbench**：自动加载测试向量、运行计算、逐点比对结果
- 测试用例：A[i]=i+1, B[i]=1024-i，预期输出由 Python 模型预计算

---

## 性能指标

| 指标 | 数值 |
|------|------|
| 正向 NTT 周期 | ~25,600 cycles |
| 逆向 NTT 周期 | ~25,600 cycles |
| 逐点乘法 | 2,048 cycles |
| 总计算周期 | ~53,250 cycles |
| 时钟频率 (估) | 100 MHz |
| NTT 延迟 | ~0.26 ms |
| 总延迟 | ~0.53 ms |

---

## 扩展方向

- **流水线化**：多蝶形单元并行，提升吞吐量
- **大模数支持**：替换 Q 和 μ 参数以支持更大的模数（需重新生成旋转因子）
- **AXI-Stream 接口**：添加标准总线接口便于 SoC 集成
- **侧信道防护**：添加随机化掩码等防护措施
- **NTT 友好素数**：支持 q = 3329 (Kyber), q = 8380417 (Dilithium) 等标准参数

---

## 参考资料

- [NTT in Post-Quantum Cryptography](https://eprint.iacr.org/2016/504)
- [Kyber Algorithm Specification](https://pq-crystals.org/kyber/)
- [Barrett Reduction](https://en.wikipedia.org/wiki/Barrett_reduction)
