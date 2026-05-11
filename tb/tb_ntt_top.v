// NTT Polynomial Multiplication Testbench
// Loads test vectors from hex files, runs computation, checks result

`timescale 1ns / 1ps

module tb_ntt_top;

    reg        clk;
    reg        rst_n;
    reg        start;
    wire       done;
    wire       busy;

    reg  [11:0] host_addr;
    reg  [13:0] host_wdata;
    reg         host_we;
    wire [13:0] host_rdata;

    ntt_top u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .done       (done),
        .busy       (busy),
        .host_addr  (host_addr),
        .host_wdata (host_wdata),
        .host_we    (host_we),
        .host_rdata (host_rdata)
    );

    localparam N = 1024;
    localparam Q = 14'd12289;

    // Test data arrays
    reg [13:0] tv_a    [0:N-1];
    reg [13:0] tv_b    [0:N-1];
    reg [13:0] tv_exp  [0:N-1];

    // Load test vectors from hex files
    initial begin
        $readmemh("tv_a.hex", tv_a);
        $readmemh("tv_b.hex", tv_b);
        $readmemh("tv_exp.hex", tv_exp);
    end

    // Clock: 100 MHz
    always #5 clk = ~clk;

    integer i, errors;
    reg [13:0] result;
    reg [31:0] cycle_cnt;

    initial begin
        clk       = 0;
        rst_n     = 0;
        start     = 0;
        host_addr = 0;
        host_wdata = 0;
        host_we   = 0;
        errors    = 0;
        cycle_cnt = 0;

        $display("=== NTT Polynomial Multiplication Testbench ===");
        $display("Q=%0d, N=%0d", Q, N);

        // Reset
        repeat(5) @(posedge clk);
        rst_n <= 1;
        repeat(2) @(posedge clk);

        // ----- Load A into memory (addr 0x000..0x3FF) -----
        $display("[%0t] Loading polynomial A...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr  <= i;
            host_wdata <= tv_a[i];
            host_we    <= 1;
        end

        // ----- Load B into memory (addr 0x400..0x7FF) -----
        $display("[%0t] Loading polynomial B...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr  <= {2'b01, i[9:0]};
            host_wdata <= tv_b[i];
            host_we    <= 1;
        end

        @(posedge clk);
        host_we <= 0;

        // ----- Start computation -----
        $display("[%0t] Starting NTT computation...", $time);
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // ----- Wait for done -----
        wait (done);
        $display("[%0t] Computation complete! Cycles: %0d", $time, cycle_cnt);

        // ----- Verify results (C region: 0x800..0xBFF) -----
        $display("[%0t] Verifying results...", $time);
        for (i = 0; i < N; i = i + 1) begin
            @(posedge clk);
            host_addr <= {2'b10, i[9:0]};
        end
        @(posedge clk);  // extra cycle for read

        for (i = 0; i < N; i = i + 1) begin
            host_addr <= {2'b10, i[9:0]};
            #1;
            result = host_rdata;
            if (result !== tv_exp[i]) begin
                if (errors < 20) begin
                    $display("ERROR: C[%0d] = %0d, expected %0d", i, result, tv_exp[i]);
                end
                errors = errors + 1;
            end
        end

        // ----- Report -----
        if (errors == 0) begin
            $display("=== ALL %0d TESTS PASSED ===", N);
        end else begin
            $display("=== TEST FAILED: %0d errors ===", errors);
        end
        $display("Total cycles: %0d", cycle_cnt);
        $finish;
    end

    // Cycle counter
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_cnt <= 0;
        else if (!done)
            cycle_cnt <= cycle_cnt + 1;
    end

    // Timeout
    initial begin
        #10000000;
        $display("TIMEOUT: Simulation did not complete");
        $finish;
    end

    // Waveform dump
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, tb_ntt_top);
    end

endmodule
