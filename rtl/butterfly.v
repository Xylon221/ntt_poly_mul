`timescale 1ns / 1ps
// NTT 蝶形运算单元 (3 级流水线)
//
// mode=0: 正向 NTT (DIF, Gentleman-Sande 蝶形)
//   a' =  a + b  (mod Q)
//   b' = (a - b) * w  (mod Q)
// mode=1: 逆向 NTT (DIT, Cooley-Tukey 蝶形)
//   a' =  a + b * w  (mod Q)
//   b' =  a - b * w  (mod Q)

module butterfly (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire        mode,
    input  wire [13:0] a,
    input  wire [13:0] b,
    input  wire [13:0] w,
    output wire [13:0] res_a,
    output wire [13:0] res_b,
    output wire        valid_out
);
    localparam Q  = 14'd12289;
    localparam MU = 15'd21843;

    // ---- Stage 0: 加减法, 捕获 a, b, w ----
    reg [14:0] add_s0;
    reg [14:0] sub_s0;
    reg [13:0] a_r, b_r, w_r;
    reg        mode_r0;
    reg        valid_r0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_s0   <= 15'd0;
            sub_s0   <= 15'd0;
            a_r      <= 14'd0;
            b_r      <= 14'd0;
            w_r      <= 14'd0;
            mode_r0  <= 1'b0;
            valid_r0 <= 1'b0;
        end else begin
            valid_r0 <= valid_in;
            if (valid_in) begin
                mode_r0 <= mode;
                a_r     <= a;
                b_r     <= b;
                w_r     <= w;
                add_s0  <= {1'b0, a} + {1'b0, b};
                sub_s0  <= {1'b0, a} + Q - {1'b0, b};
            end
        end
    end

    // ---- Stage 1: 模约简, 计算 b*w 供逆 NTT 使用 ----
    wire [13:0] add_red = (add_s0 >= Q) ? (add_s0[13:0] - Q) : add_s0[13:0];
    wire [13:0] sub_red = (sub_s0 >= Q) ? (sub_s0[13:0] - Q) : sub_s0[13:0];

    wire [27:0] bw_prod = b_r * w_r;
    wire [42:0] bw_wide = bw_prod * MU;
    wire [13:0] bw_t    = bw_wide[41:28];
    wire [27:0] bw_r1   = bw_prod - bw_t * Q;
    wire [13:0] bw_red  = (bw_r1 >= Q) ? (bw_r1[13:0] - Q) : bw_r1[13:0];

    reg [13:0] add_red_r, sub_red_r, bw_red_r;
    reg [13:0] a_r_r, w_r_r;
    reg        mode_r1;
    reg        valid_r1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            add_red_r <= 14'd0;
            sub_red_r <= 14'd0;
            bw_red_r  <= 14'd0;
            a_r_r     <= 14'd0;
            w_r_r     <= 14'd0;
            mode_r1   <= 1'b0;
            valid_r1  <= 1'b0;
        end else begin
            valid_r1 <= valid_r0;
            mode_r1  <= mode_r0;
            if (valid_r0) begin
                add_red_r <= add_red;
                sub_red_r <= sub_red;
                bw_red_r  <= bw_red;
                a_r_r     <= a_r;
                w_r_r     <= w_r;
            end
        end
    end

    // ---- Stage 2: 最终输出 ----
    // 正向: (a - b) * w
    wire [27:0] sw_prod = sub_red_r * w_r_r;
    wire [42:0] sw_wide = sw_prod * MU;
    wire [13:0] sw_t    = sw_wide[41:28];
    wire [27:0] sw_r1   = sw_prod - sw_t * Q;
    wire [13:0] sw_red  = (sw_r1 >= Q) ? (sw_r1[13:0] - Q) : sw_r1[13:0];

    // 逆向: a + b*w 和 a - b*w
    wire [14:0] inv_sum  = {1'b0, a_r_r} + {1'b0, bw_red_r};
    wire [14:0] inv_diff = {1'b0, a_r_r} + Q - {1'b0, bw_red_r};
    wire [13:0] inv_a    = (inv_sum  >= Q) ? (inv_sum[13:0]  - Q) : inv_sum[13:0];
    wire [13:0] inv_b    = (inv_diff >= Q) ? (inv_diff[13:0] - Q) : inv_diff[13:0];

    reg [13:0] res_a_r, res_b_r;
    reg        valid_out_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            res_a_r     <= 14'd0;
            res_b_r     <= 14'd0;
            valid_out_r <= 1'b0;
        end else begin
            valid_out_r <= valid_r1;
            if (valid_r1) begin
                if (mode_r1) begin
                    res_a_r <= inv_a;
                    res_b_r <= inv_b;
                end else begin
                    res_a_r <= add_red_r;
                    res_b_r <= sw_red;
                end
            end
        end
    end

    assign res_a     = res_a_r;
    assign res_b     = res_b_r;
    assign valid_out = valid_out_r;

endmodule
