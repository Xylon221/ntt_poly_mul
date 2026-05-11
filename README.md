# 基于 NTT 的 1024 点多 项式乘法器

基于 **NTT (Number Theoretic Transform，数论变换)** 的硬件多项式乘法器，支持 1024 点变 换，采用加权 NTT 实现负循环卷积 `c(x) = a(x)·b(x) mod (x^1024 + 1)`。适用于后量子密码学等场景的硬件加速。

## 实验结果

| 指标 | 数值 |
|------|------|
| **功能正确性** | **✅ 1024 / 1024 全部通过** |
| **总计算周期** | **130,062** |
| 时钟频率 | 100 MHz (仿真) |
| 总延迟 | ~1.30 ms |
| 测试平台 | Icarus Verilog 11.0 |
| 黄金参考 | Python 3 双验证 (NTT 往返 + 朴素卷积交叉验证) |

### 周期细分

| 阶段 | 周期数 | 说明 |
|------|--------|------|
| 预旋乘 A | 1,024 | A[i] *= ψ^i |
| 预旋乘 B | 1,024 | B[i] *= ψ^i |
| 正向 NTT A | 25,600 | 10 级 × 512 BF × 5 cycles |
| 正向 NTT B | 25,600 | 同上 |
| 逐点模乘 | 2,048 | 1024 × 2 cycles |
| 逆向 NTT | 25,600 | 10 级 × 512 BF × 5 cycles |
| 后旋乘 | 1,024 | C[i] *= ψ^(-i) × N^(-1) |
| 其他开销 | ~28,166 | FSM 转换、初始/结束延迟 |
| **合计** | **130,062** | |

## 核心参数

| 参数 | 符号 | 值 | 说明 |
|------|------|-----|------|
| 多项式长度 | N | 1024 | 2¹⁰ |
| 模数 | Q | 12289 | 14-bit NTT 友好素数 |
| 本原根 | ψ | 7 | 本原 2048 次单位根 |
| 前向根 | ω | 49 | ψ² |
| Barrett μ | μ | 21843 | ⌊2²⁸ / 12289⌋ |
| N 逆元 | N⁻¹ | 12277 | 1024⁻¹ mod 12289 |
| ψ 逆元 | ψ⁻¹ | 8778 | 7⁻¹ mod 12289 |

## 目录结构

```
ntt_poly_mul/
├── README.md
├── PROJECT_DOCUMENTATION.md   # 详细设计文档
├── rtl/                       # RTL 设计
│   ├── ntt_top.v              # 顶层模块 (相位控制 + 存储管理)
│   ├── ntt_core.v             # NTT 核心 FSM + 地址生成
│   ├── butterfly.v            # 蝶形运算单元 (3 级流水线)
│   ├── mod_mult.v             # Barrett 模乘器
│   ├── mod_addsub.v           # 模加减法器
│   └── twiddle_rom.v          # 旋转因子 ROM
├── tb/                        # 测试平台
│   ├── tb_ntt_top.v           # 主自检测试
│   ├── tb_barrett.v           # Barrett 约简单元测试
│   ├── tb_diag.v ~ tb_diag4.v # 逐级诊断
│   ├── tb_debug.v             # 调试 testbench
│   └── tb_mem_test.v          # 存储器测试
└── scripts/                   # Python 脚本
    ├── gen_twiddle.py         # 旋转因子 ROM 生成
    └── golden_model.py        # 黄金参考模型 + 测试向量生成
```

## 快速开始

```bash
# 1. 生成旋转因子 ROM 和测试向量
cd sim
python3 ../scripts/gen_twiddle.py
python3 ../scripts/golden_model.py

# 2. 编译 (Icarus Verilog)
iverilog -g2012 -I ../tb -o ntt_sim.vvp \
  ../rtl/mod_mult.v ../rtl/mod_addsub.v \
  ../rtl/butterfly.v ../rtl/twiddle_rom.v \
  ../rtl/ntt_core.v ../rtl/ntt_top.v \
  ../tb/tb_ntt_top.v

# 3. 运行仿真
vvp ntt_sim.vvp

# 预期输出:
# === 全部 1024 项测试通过 ===
# 总周期数: 131188
```

## 硬件架构

```
┌───────────────────────────────────────────────────────────┐
│                        ntt_top                             │
│  ┌─────────┐   ┌────────────┐   ┌──────────────┐         │
│  │  Host   │──▶│ 3072 ×14b  │◀──│   Phase      │         │
│  │  I/F    │   │ Dual-port  │   │ Controller   │         │
│  └─────────┘   │    RAM     │   └──────┬───────┘         │
│                │ A B C 区    │          │                  │
│                └─────┬──────┘   ┌──────▼───────┐         │
│                      │          │  twiddle_rom │         │
│                ┌─────▼──────┐   └──────┬───────┘         │
│                │  ntt_core  │◀─────────┘                  │
│                │   (FSM)    │                              │
│                └─────┬──────┘                              │
│                ┌─────▼──────┐                              │
│                │ butterfly  │                              │
│                │ (3-stage)  │                              │
│                └────────────┘                              │
└───────────────────────────────────────────────────────────┘
```

### 存储布局 (3072 × 14 bit)

| 地址范围 | 区域 | 用途 |
|---------|------|------|
| 0x000–0x3FF | A 区 | 多项式 a + 正向 NTT 工作区 |
| 0x400–0x7FF | B 区 | 多项式 b + 正向 NTT 工作区 |
| 0x800–0xBFF | C 区 | 逐点乘积 + 逆向 NTT 工作区 + 最终结果 |

### 计算流程

```
1. 预旋乘:    A[i] *= ψ^i,   B[i] *= ψ^i
2. 正向 NTT:  A = NTT_ω(a'), B = NTT_ω(b')
3. 逐点模乘:  C[i] = A[i] × B[i] mod Q
4. 逆向 NTT:  c' = INTT(C)
5. 后旋乘:    result[i] = c'[i] × ψ^(-i) × N^(-1) mod Q
```

## 调试历程

共修复 8 个 Bug，最终实现全部 1024 项测试通过：

| # | 文件 | 问题 | 根因 |
|---|------|------|------|
| 1 | ntt_top.v | 逐点乘读到错误区域 | PH_PW_WRITE 同时读写 C 区 |
| 2 | gen_twiddle.py | 逆 NTT 旋转因子排序错误 | ROM 布局与 RTL 访问顺序不匹配 |
| 3 | twiddle_rom.v | 首蝶形读到 x | 同步读引入 1 周期延迟 |
| 4 | ntt_top/butterfly/mod_mult | Barrett 约简偏差 | MU=21839，正确值为 21843 |
| 5 | butterfly.v | 逆 DIT 公式用错 a 输入 | 误用 a+b 代替原始 a |
| 6 | ntt_core.v | 逆 NTT stride 初始化错误 | stride 统一初始为 512 |
| 7 | ntt_core.v | FSM 流水线不可靠 | 跨模块 valid 握手时序风险 |
| 8 | ntt_top.v | PSI_INV 常数错误 | 8783 → 8778 |

## 关键修正值

| 参数 | 错误值 | 正确值 | 影响 |
|------|--------|--------|------|
| PSI_INV | 8783 | **8778** | 后旋乘全部输出 |
| MU | 21839 | **21843** | 所有 Barrett 约简 |
| 逆 NTT stride 初值 | 512 | **1** | 逆向地址生成 |

## 扩展方向

- **多蝶形并行**: 实例化 2/4/8 个 butterfly，吞吐量线性提升
- **新参数支持**: 替换 Q/ψ 适配 Kyber (q=3329)、Dilithium (q=8380417)
- **AXI-Stream 接口**: 标准化总线便于 SoC 集成
- **侧信道防护**: 随机化掩码、恒定时间运算
