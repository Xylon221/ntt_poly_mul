// Quick debug: compare first BF operation with Python
`timescale 1ns / 1ps

module tb_debug;
    reg clk, rst_n, start;
    wire done, busy;
    reg [11:0] host_addr;
    reg [13:0] host_wdata;
    reg host_we;
    wire [13:0] host_rdata;

    ntt_top u_dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .done(done), .busy(busy),
        .host_addr(host_addr), .host_wdata(host_wdata),
        .host_we(host_we), .host_rdata(host_rdata)
    );

    always #5 clk = ~clk;
    integer i;
    reg [13:0] tv_a [0:1023];
    reg [13:0] tv_b [0:1023];

    initial begin
        $readmemh("tv_a.hex", tv_a);
        $readmemh("tv_b.hex", tv_b);
    end

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Load A
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= tv_a[i];
            host_we    <= 1;
        end
        // Load B
        for (i = 0; i < 1024; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= tv_b[i];
            host_we    <= 1;
        end
        @(posedge clk); host_we <= 0;

        // Start
        @(posedge clk); start <= 1;
        @(posedge clk); start <= 0;

        // Wait for NTT A first butterfly, capture signals
        // Phase 3 = PH_NTT_A. Monitor first BF
        wait(u_dut.phase == 3);
        // Wait a few cycles for core to start
        repeat(10) @(posedge clk);

        // Now probe the first BF inputs/outputs
        $display("=== First Butterfly Debug ===");
        $display("Phase=%0d, core state=%0d", u_dut.phase, u_dut.u_ntt_core.state);
        $display("twiddle_addr=%0d, twiddle_data=%0d", 
                 u_dut.u_ntt_core.twiddle_addr, u_dut.u_ntt_core.twiddle_data);
        $display("bf_valid=%b, bf_mode=%b, bf_a=%0d, bf_b=%0d, bf_w=%0d",
                 u_dut.u_ntt_core.bf_valid, u_dut.u_ntt_core.bf_mode,
                 u_dut.u_ntt_core.bf_a, u_dut.u_ntt_core.bf_b,
                 u_dut.u_ntt_core.bf_w);

        // Wait for BF output
        repeat(15) @(posedge clk);
        $display("BF results: res_a=%0d, res_b=%0d, valid_out=%b",
                 u_dut.u_ntt_core.bf_res_a, u_dut.u_ntt_core.bf_res_b,
                 u_dut.u_ntt_core.bf_valid_out);

        $finish;
    end

    initial begin
        $dumpfile("debug_wave.vcd");
        $dumpvars(0, tb_debug);
    end
endmodule
