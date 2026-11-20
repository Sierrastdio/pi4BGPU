module top (
    input  logic clk,
    output logic [5:0] led_n
);
    logic [24:0] heartbeat_counter = '0;

    always_ff @(posedge clk) begin
        heartbeat_counter <= heartbeat_counter + 1'b1;
    end

    // Tang Nano 20K LEDs are active-low. Blink LED0 as a toolchain bring-up check.
    always_comb begin
        led_n = 6'b111111;
        led_n[0] = ~heartbeat_counter[24];
    end
endmodule
