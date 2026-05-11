// Minimal diagnostic testbench for NTT top module
`timescale 1ns / 1ps

module tb_diag;

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

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Write test value to A[0]
        @(posedge clk);
        host_addr <= 12'd0;
        host_wdata <= 14'd1234;
        host_we <= 1;
        $display("[%0t] Writing 1234 to mem[0]", $time);

        // Write test value to B[0]
        @(posedge clk);
        host_addr <= 12'd1024;
        host_wdata <= 14'd5678;
        $display("[%0t] Writing 5678 to mem[1024]", $time);

        @(posedge clk);
        host_we <= 0;

        // Read back
        @(posedge clk);
        host_addr <= 12'd0;
        $display("[%0t] Reading mem[0]...", $time);

        @(posedge clk);
        #1;
        $display("[%0t] mem[0] = %0d (expected 1234)", $time, host_rdata);

        host_addr <= 12'd1024;
        @(posedge clk);
        #1;
        $display("[%0t] mem[1024] = %0d (expected 5678)", $time, host_rdata);

        // Check internal state
        $display("[%0t] Phase = %0d", $time, u_dut.phase);
        $display("[%0t] mem_we_a = %b, mem_we_b = %b", $time, u_dut.mem_we_a, u_dut.mem_we_b);
        $display("[%0t] host_active = %b", $time, u_dut.host_active);

        // Now try pre-twist by starting computation
        $display("[%0t] Starting computation...", $time);
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Wait a few cycles and check phase
        repeat(5) @(posedge clk);
        $display("[%0t] Phase = %0d, cnt = %0d, twist_acc = %0d",
                 $time, u_dut.phase, u_dut.cnt, u_dut.twist_acc);

        repeat(10) @(posedge clk);
        $display("[%0t] Phase = %0d, cnt = %0d",
                 $time, u_dut.phase, u_dut.cnt);

        $finish;
    end

    initial begin
        $dumpfile("diag_wave.vcd");
        $dumpvars(0, tb_diag);
    end

endmodule
