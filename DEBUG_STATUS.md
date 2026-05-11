# NTT 多项式乘法器 — 调试状态

> 日期：2026-05-11
> 目标：修复仿真错误，使 RTL 输出与 Python 黄金模型一致

## 当前状态

- **固定结果**: C[0]=4549 ✓, C[511]=? ✓ (2/1024 正确)
- **剩余错误**: 1022/1024 输出错误
- **Python RTL 模拟**: 0 错误（算法级别验证通过）

## 项目结构

```
rtl/
├── ntt_top.v        # 顶层（相位 FSM + 内存 + 扭乘/逐点乘）
├── ntt_core.v       # NTT 核心（迭代 FSM + 地址生成）
├── butterfly.v      # 蝶形运算（DIF/DIT，3 级流水线）
└── twiddle_rom.v    # 旋转因子 ROM（4096×14bit）
scripts/
├── gen_twiddle.py   # 旋转因子 ROM 生成
└── golden_model.py  # Python 黄金参考模型
```

## 快速启动

```bash
cd /home/wsluser/temp/ntt_poly_mul/sim
python3 ../scripts/gen_twiddle.py
python3 ../scripts/golden_model.py
make compile
make run
```

## 已修复的 Bug

### Bug 1: 逐点乘法读到错误内存区域 (已修复)
- **文件**: `rtl/ntt_top.v` — `PH_PW_WRITE` 状态
- **原因**: 在写入 C 区域的同一周期内，又试图从 `mem_rdata_a * mem_rdata_b` 读取下一个乘积
- **修复**: 改为纯交替：PH_PW_READ → PH_PW_WRITE → PH_PW_READ → ...

### Bug 2: 逆 NTT 旋转因子 ROM 布局错误 (已修复)
- **文件**: `scripts/gen_twiddle.py`
- **原因**: ROM 按 stride 从大到小存储，但 RTL 逆 NTT 按 stride 从小到大访问
- **修复**: 改为按 stride=1,2,4,...,512 的顺序生成逆 NTT 旋转因子

### Bug 3: ROM 同步读导致首蝶形运算读到 x (已修复)
- **文件**: `rtl/twiddle_rom.v`
- **原因**: `always @(posedge clk) data <= rom[addr]` 带来 1 周期读延迟
- **修复**: 改为组合读 `assign data = rom[addr]`

### Bug 4: Barrett 约简参数 MU 错误 (已修复)
- **文件**: `rtl/ntt_top.v`, `rtl/butterfly.v`, `rtl/mod_mult.v`
- **原因**: MU = 21839，但 floor(2^28 / 12289) = 21843。差值为 4，导致约简后的余数可达 ~5×Q
- **修复**: 所有 MU 改为 15'd21843

### Bug 5: 逆 NTT 蝶形运算使用了错误的 a 输入 (已修复)
- **文件**: `rtl/butterfly.v`
- **原因**: 逆 DIT 模式使用 `add_red_r` (= a+b) 代替 `a`，
  计算公式为 `(a+b) + b×w` 和 `(a+b) - b×w`，但正确公式为 `a + b×w` 和 `a - b×w`
- **修复**: 在 stage 0 中捕获 `a_r`，通过流水线传递至 stage 2，逆 DIT 模式下使用 `a_r_r` 代替 `add_red_r`。同时添加 `w_r_r` 流水线寄存器确保前向模式中 w 与 sub_red_r 对齐

### Bug 6: 逆 NTT stride 初始化错误 (已修复)
- **文件**: `rtl/ntt_core.v`
- **原因**: S_IDLE 中 `stride <= 10'd512` 对所有模式统一初始化，逆 NTT 应从 stride=1 开始
- **修复**: 改为 `stride <= mode ? 10'd1 : 10'd512`

### Bug 7: ntt_core FSM 流水线延迟不可靠 (已优化)
- **文件**: `rtl/ntt_core.v`
- **原因**: S_WAIT/S_WAIT2/S_WAIT3 依赖 bf_valid_out 信号，存在潜在时序问题
- **修复**: 替换为基于计数器的 S_PIPE 状态，等待固定 4 个周期后捕获蝶形运算结果

## 已验证通过的部分

1. **蝶形运算单元**: 前向 DIF 模式对 (a=1, b=3191, w=1) 产生正确的 (3192, 9099) ✓
2. **逆 DIT 蝶形**: 对 (a=320, b=4043, w=1) 产生正确的 (4363, 8566) ✓
3. **Barrett 约简**: MU=21843 在 500K 随机样本中 0 错误 ✓
4. **旋转因子 ROM**: 全部 2046 个旋转变因子（前向+逆向）与 Python 模型完全一致 ✓
5. **逐点乘法**: C[0]=320, C[1]=4043, C[2]=1271 均正确 ✓
6. **前向 NTT**: 首个蝶形运算 B 区结果 (a=1024,b=4670→5694,8643) 正确 ✓
7. **Python RTL 模拟**: 使用 RTL ROM 数据进行端到端模拟，结果 0 错误 ✓

## 待解决问题

逆 NTT 各阶段（s=2至s=9）的蝶形运算结果可能存在系统性误差。
错误呈对称模式：仅 C[0] 和 C[511] 正确，其他 1022 个输出均错误。
可能的根本原因：
- Icarus Verilog 仿真器特定的时序或位宽问题
- 内存读写竞争
- 需要外部仿真器（如 Verilator/Xcelium）进一步验证

## 修改文件汇总

1. `rtl/ntt_top.v` — Bug 1 (逐点乘), Bug 4 (MU), 移除调试打印
2. `scripts/gen_twiddle.py` — Bug 2 (逆 NTT ROM 排序)
3. `rtl/twiddle_rom.v` — Bug 3 (组合读)
4. `rtl/butterfly.v` — Bug 4 (MU), Bug 5 (逆 DIT 公式修复)
5. `rtl/mod_mult.v` — Bug 4 (MU)
6. `rtl/ntt_core.v` — Bug 6 (逆 NTT stride), Bug 7 (FSM 简化)
