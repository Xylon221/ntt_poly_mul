`timescale 1ns / 1ps
// NTT Core Controller — iterative radix-2 DIF/DIT with single butterfly
//
// DIF forward NTT (mode=0): uses omega = 49 as primitive N-th root
// DIT inverse NTT (mode=1): uses omega^(-1) as root
//
// Memory addresses are 12-bit: {base_sel, inner_addr[9:0]}

module ntt_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        mode,           // 0=forward, 1=inverse
    input  wire [1:0]  base_sel,       // memory region
    output reg         done,

    output reg  [11:0] mem_addr_a,
    output reg         mem_we_a,
    output reg  [13:0] mem_wdata_a,
    input  wire [13:0] mem_rdata_a,

    output reg  [11:0] mem_addr_b,
    output reg         mem_we_b,
    output reg  [13:0] mem_wdata_b,
    input  wire [13:0] mem_rdata_b,

    output reg  [11:0] twiddle_addr,
    input  wire [13:0] twiddle_data,

    output reg         bf_valid,
    output reg         bf_mode,
    output reg  [13:0] bf_a,
    output reg  [13:0] bf_b,
    output reg  [13:0] bf_w,
    input  wire [13:0] bf_res_a,
    input  wire [13:0] bf_res_b,
    input  wire        bf_valid_out
);
    localparam N  = 11'd1024;
    localparam LG = 4'd10;

    localparam S_IDLE     = 3'd0;
    localparam S_READ     = 3'd1;
    localparam S_ISSUE    = 3'd2;
    localparam S_PIPE     = 3'd3;
    localparam S_WRITE    = 3'd4;
    localparam S_NEXT     = 3'd5;
    localparam S_DONE     = 3'd6;

    reg [2:0]  state;
    reg [3:0]  stage;
    reg [9:0]  stride;
    reg [9:0]  group;
    reg [9:0]  offset;
    reg [1:0]  pipe_cnt;     // pipeline wait counter
    reg [13:0] bf_res_a_r, bf_res_b_r;

    // Inner address computation (0..1023)
    wire [9:0] group_size = stride << 1;
    wire [9:0] group_base = group * group_size;
    wire [9:0] inner_a    = group_base + offset;
    wire [9:0] inner_b    = inner_a + stride;

    // Full 12-bit memory addresses
    wire [11:0] full_a = {base_sel, inner_a};
    wire [11:0] full_b = {base_sel, inner_b};

    // ---- Forward twiddle stage base ----
    function [10:0] stage_base_fw;
        input [3:0] s;
        begin
            case (s)
                4'd0:  stage_base_fw = 11'd0;
                4'd1:  stage_base_fw = 11'd512;
                4'd2:  stage_base_fw = 11'd768;
                4'd3:  stage_base_fw = 11'd896;
                4'd4:  stage_base_fw = 11'd960;
                4'd5:  stage_base_fw = 11'd992;
                4'd6:  stage_base_fw = 11'd1008;
                4'd7:  stage_base_fw = 11'd1016;
                4'd8:  stage_base_fw = 11'd1020;
                4'd9:  stage_base_fw = 11'd1022;
                default: stage_base_fw = 11'd0;
            endcase
        end
    endfunction

    // ---- Inverse twiddle stage base ----
    function [10:0] stage_base_inv;
        input [3:0] s;
        begin
            case (s)
                4'd0:  stage_base_inv = 11'd0;
                4'd1:  stage_base_inv = 11'd1;
                4'd2:  stage_base_inv = 11'd3;
                4'd3:  stage_base_inv = 11'd7;
                4'd4:  stage_base_inv = 11'd15;
                4'd5:  stage_base_inv = 11'd31;
                4'd6:  stage_base_inv = 11'd63;
                4'd7:  stage_base_inv = 11'd127;
                4'd8:  stage_base_inv = 11'd255;
                4'd9:  stage_base_inv = 11'd511;
                default: stage_base_inv = 11'd0;
            endcase
        end
    endfunction

    // Twiddle ROM address
    wire [11:0] fw_idx  = 12'd0     + {1'b0, stage_base_fw(stage)}  + {2'b0, offset};
    wire [11:0] inv_idx = 12'd1023  + {1'b0, stage_base_inv(stage)} + {2'b0, offset};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            done     <= 1'b0;
            stage    <= 4'd0;
            stride   <= 10'd512;
            group    <= 10'd0;
            offset   <= 10'd0;
            pipe_cnt <= 2'd0;
            {mem_we_a, mem_we_b} <= 2'b00;
            bf_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (start) begin
                        stage    <= 4'd0;
                        stride   <= mode ? 10'd1 : 10'd512;
                        group    <= 10'd0;
                        offset   <= 10'd0;
                        pipe_cnt <= 2'd0;
                        {mem_we_a, mem_we_b} <= 2'b00;
                        bf_valid <= 1'b0;
                        state    <= S_READ;
                    end
                end

                // Set addresses and twiddle
                S_READ: begin
                    mem_addr_a   <= full_a;
                    mem_addr_b   <= full_b;
                    mem_we_a     <= 1'b0;
                    mem_we_b     <= 1'b0;
                    twiddle_addr <= mode ? inv_idx : fw_idx;
                    state <= S_ISSUE;
                end

                // Issue butterfly
                S_ISSUE: begin
                    bf_valid <= 1'b1;
                    bf_mode  <= mode;
                    bf_a     <= mem_rdata_a;
                    bf_b     <= mem_rdata_b;
                    bf_w     <= twiddle_data;
                    pipe_cnt <= 2'd0;
                    state    <= S_PIPE;
                end

                // Wait for pipeline (3 cycles of bf_valid high + 1 extra for valid_out)
                S_PIPE: begin
                    pipe_cnt <= pipe_cnt + 1;
                    if (pipe_cnt == 2'd3) begin
                        bf_valid   <= 1'b0;
                        bf_res_a_r <= bf_res_a;
                        bf_res_b_r <= bf_res_b;
                        state      <= S_WRITE;
                    end
                end

                // Write back results
                S_WRITE: begin
                    mem_addr_a  <= full_a;
                    mem_we_a    <= 1'b1;
                    mem_wdata_a <= bf_res_a_r;
                    mem_addr_b  <= full_b;
                    mem_we_b    <= 1'b1;
                    mem_wdata_b <= bf_res_b_r;
                    state <= S_NEXT;
                end

                // Advance to next butterfly
                S_NEXT: begin
                    {mem_we_a, mem_we_b} <= 2'b00;
                    if (mode) begin
                        // Inverse: stride grows (1, 2, 4, ..., 512)
                        if (offset + 1 < stride) begin
                            offset <= offset + 1;
                            state  <= S_READ;
                        end else begin
                            offset <= 10'd0;
                            if (group + 1 < (N / (stride * 2))) begin
                                group <= group + 1;
                                state <= S_READ;
                            end else begin
                                group <= 10'd0;
                                if (stage + 1 < LG) begin
                                    stage  <= stage + 1;
                                    stride <= stride << 1;
                                    state  <= S_READ;
                                end else begin
                                    state <= S_DONE;
                                end
                            end
                        end
                    end else begin
                        // Forward: stride shrinks (512, 256, ..., 1)
                        if (offset + 1 < stride) begin
                            offset <= offset + 1;
                            state  <= S_READ;
                        end else begin
                            offset <= 10'd0;
                            if (group + 1 < (N / group_size)) begin
                                group <= group + 1;
                                state <= S_READ;
                            end else begin
                                group <= 10'd0;
                                if (stage + 1 < LG) begin
                                    stage  <= stage + 1;
                                    stride <= stride >> 1;
                                    state  <= S_READ;
                                end else begin
                                    state <= S_DONE;
                                end
                            end
                        end
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
