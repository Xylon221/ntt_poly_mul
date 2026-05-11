`timescale 1ns / 1ps
// Twiddle factor ROM — stores pre-computed constants for NTT
//
// Address map (4096 entries, 12-bit address):
//   0x000-0x3FE (0-1022):    Forward NTT twiddles (1023 entries)
//   0x3FF-0x7FD (1023-2045): Inverse NTT twiddles (1023 entries)
//   0x7FE-0xBFD (2046-3069): Pre-twist table ψ^j   (1024 entries)
//   0xBFE-0xFFD (3070-4093): Post-twist table ψ^(-j)*N^(-1) (1024 entries)
//
// Forward twiddle layout: stage 0 (512 values), stage 1 (256), ..., stage 9 (1)
// Inverse twiddle layout: stage 0 (1 value),   stage 1 (2),   ..., stage 9 (512)

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
