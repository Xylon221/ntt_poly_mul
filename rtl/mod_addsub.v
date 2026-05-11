`timescale 1ns / 1ps
// Modular adder / subtractor for Q = 12289
// Uses clean arithmetic with explicit width extensions

module mod_addsub (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        valid_in,
    input  wire        sub,           // 0=add, 1=subtract
    input  wire [13:0] a,
    input  wire [13:0] b,
    output reg  [13:0] result,
    output reg         valid_out
);
    localparam Q = 14'd12289;

    // Stage 0: compute a+b and a+Q-b (15 bits to avoid overflow)
    reg [14:0] sum_r, diff_r;
    reg        sub_r, valid_r0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r    <= 15'd0;
            diff_r   <= 15'd0;
            sub_r    <= 1'b0;
            valid_r0 <= 1'b0;
        end else begin
            valid_r0 <= valid_in;
            sub_r    <= sub;
            if (valid_in) begin
                sum_r  <= {1'b0, a} + {1'b0, b};
                diff_r <= {1'b0, a} + Q - {1'b0, b};
            end
        end
    end

    // Stage 1: modular reduction
    wire [13:0] sum_red  = (sum_r  >= Q) ? (sum_r[13:0]  - Q) : sum_r[13:0];
    wire [13:0] diff_red = (diff_r >= Q) ? (diff_r[13:0] - Q) : diff_r[13:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result    <= 14'd0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= valid_r0;
            if (valid_r0)
                result <= sub_r ? diff_red : sum_red;
        end
    end

endmodule
