`timescale 1ns / 1ps
// 旋转因子 ROM — 存储预计算的 NTT 常数
//
// 地址映射 (4096 项, 12-bit 地址):
//   0x000-0x3FE (0-1022):    正向 NTT 旋转因子 (1023 项)
//   0x3FF-0x7FD (1023-2045): 逆向 NTT 旋转因子 (1023 项)
//   0x7FE-0xBFD (2046-3069): 预旋乘表 ψ^j       (1024 项)
//   0xBFE-0xFFD (3070-4093): 后旋乘表 ψ^(-j)*N^(-1) (1024 项)
//
// 正向: stage 0(512值) → stage 1(256) → ... → stage 9(1)
// 逆向: stage 0(1值)   → stage 1(2)   → ... → stage 9(512)

module twiddle_rom (
    input  wire        clk,
    input  wire [11:0] addr,
    output wire [13:0] data
);
    reg [13:0] rom [0:4095];

    initial begin
        $readmemh("twiddle.hex", rom);
    end

    assign data = rom[addr];

endmodule
