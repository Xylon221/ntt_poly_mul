// Simple memory access test for C region
`timescale 1ns / 1ps

module tb_mem_test;
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
    integer i, errors;

    initial begin
        clk = 0; rst_n = 0; start = 0;
        host_addr = 0; host_wdata = 0; host_we = 0;
        errors = 0;

        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // Write to C region (0x800-0xBFF)
        $display("Writing to C region...");
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            host_addr  <= 2048 + i;   // 0x800 + i
            host_wdata <= 100 + i;
            host_we    <= 1;
        end
        @(posedge clk);
        host_we <= 0;

        // Read back C region
        $display("Reading back C region...");
        for (i = 0; i < 10; i = i + 1) begin
            @(posedge clk);
            host_addr <= 2048 + i;
            @(posedge clk); #1;
            if (host_rdata !== (100 + i)) begin
                $display("ERROR: C[%0d] = %0d, expected %0d", i, host_rdata, 100+i);
                errors = errors + 1;
            end else begin
                $display("OK: C[%0d] = %0d", i, host_rdata);
            end
        end

        if (errors == 0)
            $display("MEMORY TEST PASSED");
        else
            $display("MEMORY TEST FAILED: %0d errors", errors);

        $finish;
    end

    initial begin
        $dumpfile("mem_test.vcd");
        $dumpvars(0, tb_mem_test);
    end
endmodule
