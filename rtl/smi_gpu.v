`timescale 1ns / 1ps
`default_nettype none
//
// Write-only 16-bit SMI ingress for TangNanoGPU.
//
// SMI_A0=1 writes form a three-word packet header:
//   1) {8'hA5, opcode}
//   2) payload byte count [15:0]
//   3) payload byte count [31:16]
// SMI_A0=0 writes then carry the payload, two bytes per SMI word. The low
// data byte is emitted first, then the high byte. If the byte count is odd,
// the high byte of the final word is ignored. The opcode and payload are
// converted to the byte stream consumed by gpu_exec through cmd_push/data.
//
// RESET (opcode 0x02, zero payload) is handled here. PING, STATUS, READ_DATA,
// and READ_RECT require a read path and are intentionally unsupported by this
// initial wiring. BUSY is asserted before the command FIFO or ingress FIFO
// runs out of room; the host must split long payload bursts and check BUSY
// between bursts.
//
module smi_gpu #(
    parameter integer BUSY_FREE = 1024
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        smi_swe_n,
    input  wire        smi_a0,
    input  wire [15:0] smi_data,

    output reg         cmd_push,
    output reg  [7:0]  cmd_data,
    input  wire        cmd_full,
    input  wire [15:0] cmd_free,

    output reg         soft_reset,
    output reg         overflow,
    output wire        busy
);

  localparam [7:0] FRAME_MAGIC = 8'hA5;
  localparam [7:0] OP_RESET = 8'h02;
  localparam [7:0] OP_PING = 8'h01;
  localparam [7:0] OP_STATUS = 8'h03;
  localparam [7:0] OP_READ_DATA = 8'h51;
  localparam [7:0] OP_READ_RECT = 8'h50;

  // SWE_N is active-low. Invert it so the FIFO's rising write-clock edge is
  // the falling edge of SWE_N, when the SMI word is captured.
  wire smi_wclk = ~smi_swe_n;
  wire word_full, word_empty;
  wire [16:0] word_dout;
  wire word_pop;
  reg  input_overflow = 1'b0;

  async_fifo #(.W(17), .AW(4)) u_smi_words (
      .rst(rst),
      .wclk(smi_wclk), .we(1'b1), .wdata({smi_a0, smi_data}), .full(word_full),
      .rclk(clk), .re(word_pop), .rdata(word_dout), .empty(word_empty)
  );

  always @(posedge smi_wclk or posedge rst) begin
    if (rst) input_overflow <= 1'b0;
    else if (word_full) input_overflow <= 1'b1;
  end

  reg input_overflow_s1, input_overflow_s2;
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      input_overflow_s1 <= 1'b0;
      input_overflow_s2 <= 1'b0;
    end else begin
      input_overflow_s1 <= input_overflow;
      input_overflow_s2 <= input_overflow_s1;
    end
  end

  localparam [2:0] S_HEADER = 3'd0, S_LENGTH_LO = 3'd1,
                   S_LENGTH_HI = 3'd2, S_EMIT_OPCODE = 3'd3,
                   S_PAYLOAD = 3'd4, S_DISCARD = 3'd5;
  reg [2:0] state = S_HEADER;
  reg [7:0] opcode;
  reg [15:0] length_lo;
  reg [31:0] remaining;
  reg [15:0] pending_word;
  reg pending_high;
  reg drop_frame;

  wire word_valid = !word_empty;
  wire word_is_addr = word_dout[16];
  wire [15:0] word_data = word_dout[15:0];
  wire waiting_for_word = (state == S_HEADER) || (state == S_LENGTH_LO) ||
                          (state == S_LENGTH_HI) || (state == S_PAYLOAD) ||
                          (state == S_DISCARD);
  wire accept_word = word_valid && waiting_for_word &&
                     ((state == S_PAYLOAD || state == S_DISCARD) ? !pending_high : 1'b1) &&
                     ((state != S_PAYLOAD) || pending_high || !cmd_full);

  assign word_pop = accept_word;
  // Leave room for one complete three-word command header and for the SMI
  // clock-domain synchronizer latency before declaring the link unavailable.
  assign busy = rst || (cmd_free < BUSY_FREE) || (word_full && smi_swe_n);

  always @(posedge clk) begin
    cmd_push   <= 1'b0;
    soft_reset <= 1'b0;

    if (rst) begin
      state      <= S_HEADER;
      opcode     <= 8'd0;
      length_lo  <= 16'd0;
      remaining  <= 32'd0;
      pending_word <= 16'd0;
      pending_high <= 1'b0;
      drop_frame <= 1'b0;
      overflow   <= 1'b0;
    end else begin
      if (input_overflow_s2) overflow <= 1'b1;

      case (state)
        S_HEADER: begin
          if (accept_word) begin
            if (word_is_addr && word_data[15:8] == FRAME_MAGIC) begin
              opcode <= word_data[7:0];
              state <= S_LENGTH_LO;
            end else begin
              overflow <= 1'b1;
            end
          end
        end

        S_LENGTH_LO: begin
          if (accept_word) begin
            if (word_is_addr) begin
              length_lo <= word_data;
              state <= S_LENGTH_HI;
            end else begin
              overflow <= 1'b1;
              state <= S_HEADER;
            end
          end
        end

        S_LENGTH_HI: begin
          if (accept_word) begin
            if (word_is_addr) begin
              remaining <= {word_data, length_lo};
              drop_frame <= (opcode == OP_PING) || (opcode == OP_STATUS) ||
                            (opcode == OP_READ_DATA) || (opcode == OP_READ_RECT);
              if ((opcode == OP_PING) || (opcode == OP_STATUS) ||
                  (opcode == OP_READ_DATA) || (opcode == OP_READ_RECT))
                overflow <= 1'b1;
              state <= S_EMIT_OPCODE;
            end else begin
              overflow <= 1'b1;
              state <= S_HEADER;
            end
          end
        end

        S_EMIT_OPCODE: begin
          if (opcode == OP_RESET) begin
            if (remaining == 0) soft_reset <= 1'b1;
            else overflow <= 1'b1;
            state <= S_HEADER;
          end else if (drop_frame) begin
            if (remaining == 0) state <= S_HEADER;
            else state <= S_DISCARD;
          end else if (!cmd_full) begin
            cmd_push <= 1'b1;
            cmd_data <= opcode;
            if (remaining == 0) state <= S_HEADER;
            else begin
              pending_high <= 1'b0;
              state <= S_PAYLOAD;
            end
          end
        end

        S_PAYLOAD: begin
          if (pending_high) begin
            if (!cmd_full) begin
              cmd_push <= 1'b1;
              cmd_data <= pending_word[15:8];
              remaining <= remaining - 1'b1;
              pending_high <= 1'b0;
              if (remaining == 1) state <= S_HEADER;
            end
          end else if (accept_word) begin
            if (!word_is_addr) begin
              pending_word <= word_data;
              cmd_push <= 1'b1;
              cmd_data <= word_data[7:0];
              remaining <= remaining - 1'b1;
              if (remaining == 1) state <= S_HEADER;
              else if (remaining > 1) pending_high <= 1'b1;
            end else begin
              overflow <= 1'b1;
              state <= S_HEADER;
            end
          end
        end

        S_DISCARD: begin
          if (pending_high) begin
            remaining <= remaining - 1'b1;
            pending_high <= 1'b0;
            if (remaining == 1) state <= S_HEADER;
          end else if (accept_word) begin
            if (!word_is_addr) begin
              remaining <= remaining - 1'b1;
              if (remaining == 1) state <= S_HEADER;
              else if (remaining > 1) begin
                pending_word <= word_data;
                pending_high <= 1'b1;
              end
            end else begin
              overflow <= 1'b1;
              state <= S_HEADER;
            end
          end
        end

        default: state <= S_HEADER;
      endcase
    end
  end

endmodule
`default_nettype wire
