`timescale 1ns / 1ps
// Barrett 模乘器  — 计算 a * b mod 12289 (14-bit 素数)
// Barrett 参数 mu = floor(2^28 / 12289) = 21843

module mod_mult (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire [13:0] a,
    input  wire [13:0] b,
    output reg  [13:0] result,
    output reg         valid_out
);
    localparam Q   = 14'd12289;
    localparam MU  = 15'd21843;

    // Stage 0: 乘法
    reg [27:0] prod_r;
    reg        valid_r0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_r   <= 28'd0;
            valid_r0 <= 1'b0;
        end else begin
            valid_r0 <= valid_in;
            if (valid_in)
                prod_r <= a * b;
        end
    end

    // Stage 1: Barrett 约简
    wire [42:0] t_ext = prod_r * MU;       // 28 * 15 = 43 bits
    wire [13:0] t     = t_ext[41:28];       // t = (prod * MU) >> 28
    wire [27:0] r1    = prod_r - t * Q;     // r = prod - t * Q
    wire [13:0] r2    = (r1 >= Q) ? (r1[13:0] - Q) : r1[13:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result    <= 14'd0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_r0;
            if (valid_r0)
                result <= r2;
        end
    end

endmodule
