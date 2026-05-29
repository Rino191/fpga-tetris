module VGA #(
    // Display parameters
    parameter H_DISPLAY = 640, V_DISPLAY = 480,
    parameter H_TOTAL = 800, V_TOTAL = 525,
    parameter H_SYNC_START = 656, H_SYNC_END = 752,
    parameter V_SYNC_START = 490, V_SYNC_END = 492,
    
    // Game parameters
    parameter GAME_WIDTH = 20, GAME_HEIGHT = 15,
    parameter BLOCKS_WIDE = 20, BLOCKS_HIGH = 15,
    parameter BITS_PER_BLOCK = 4,
    parameter BITS_X_POS = 5, BITS_Y_POS = 4,
    parameter BITS_ROT = 2,
    parameter BITS_BLK_POS = 9, BITS_BLK_SIZE = 5,
    parameter TOP_ROW = BLOCKS_WIDE - 1
)(
    input wire clk, left, right, down, rotate, reset, drop_button,
    output wire vga_hsync, vga_vsync,
    output reg vga_r, vga_g, vga_b
);

    // Constants
    localparam H_SCALE = (GAME_WIDTH << 10) / H_DISPLAY;
    localparam V_SCALE = (GAME_HEIGHT << 10) / V_DISPLAY;

    // Game state registers
    reg [27:0] drop_timer = 0;
    reg [27:0] drop_interval = 25_000_000;
    reg [(BLOCKS_WIDE*BLOCKS_HIGH)-1:0] fallen_pieces;
    reg [BITS_PER_BLOCK-1:0] cur_piece;
    reg [BITS_X_POS-1:0] cur_pos_x;
    reg [BITS_Y_POS-1:0] cur_pos_y;
    reg [BITS_ROT-1:0] cur_rot;
    reg game_over = 1'b0;

    // Current block calculation wires
    wire [BITS_BLK_POS-1:0] cur_blk_1, cur_blk_2, cur_blk_3, cur_blk_4;
    wire [BITS_BLK_SIZE-1:0] cur_width, cur_height;
    wire top_row_occupied;

    // Game logic registers
    reg left_prev = 0, right_prev = 0, rotate_prev = 0;
    reg [4:0] new_x;
    reg can_move;
    reg [9:0] h_counter = 0, v_counter = 0;
    reg [19:0] move_timer = 0;
    reg [4:0] drop_distance;
    reg [BITS_Y_POS-1:0] check_row;
    reg check_rows;
    reg [1:0] clear_state;

    // VGA timing
    reg clk25 = 0;

    // Random number generation
    reg [31:0] random_seed = 32'hACE1_2468;
    wire random_bit;

    // Game over pattern
    reg [GAME_WIDTH*GAME_HEIGHT-1:0] game_over_pattern = {
        20'b00000000000000000000, 
        20'b00000000000000000000, 
        20'b00010101110010011100, 
        20'b00010100010101010100, 
        20'b00001101110101010100, 
        20'b00010100010101010100, 
        20'b00011101110101011100, 
        20'b00000000000000000000, 
        20'b00011101010101011100, 
        20'b00000101010101010100, 
        20'b00011101010111000100, 
        20'b00000101110101000100, 
        20'b00011101110111011100, 
        20'b00000000000000000000, 
        20'b00000000000000000000
    };

    // State parameters
    parameter IDLE = 2'b00, CHECK = 2'b01, CLEAR = 2'b10, NEXT = 2'b11;

    // Assignments
    assign top_row_occupied = |fallen_pieces[TOP_ROW:0];
    assign random_bit = random_seed[0];
    assign vga_hsync = (h_counter >= H_SYNC_START && h_counter < H_SYNC_END);
    assign vga_vsync = (v_counter >= V_SYNC_START && v_counter < V_SYNC_END);

    // Block calculation modules
    calc_cur_blk calc_cur_blk_ (
        .piece(cur_piece), .pos_x(cur_pos_x), .pos_y(cur_pos_y), .rot(cur_rot),
        .blk_1(cur_blk_1), .blk_2(cur_blk_2), .blk_3(cur_blk_3), .blk_4(cur_blk_4),
        .width(cur_width), .height(cur_height)
    );

    reg [BITS_ROT-1:0] test_rot;
    wire [BITS_BLK_POS-1:0] test_blk_1, test_blk_2, test_blk_3, test_blk_4;
    wire [BITS_BLK_SIZE-1:0] test_width, test_height;

    calc_cur_blk calc_test_blk (
        .piece(cur_piece), .pos_x(cur_pos_x), .pos_y(cur_pos_y), .rot(test_rot),
        .blk_1(test_blk_1), .blk_2(test_blk_2), .blk_3(test_blk_3), .blk_4(test_blk_4),
        .width(test_width), .height(test_height)
    );

    // Functions and tasks
    function can_rotate_func;
        input [1:0] new_rot;
        begin
            test_rot = new_rot;
            can_rotate_func = (cur_pos_x + test_width <= GAME_WIDTH) && 
                              (cur_pos_y + test_height <= GAME_HEIGHT) && 
                              (fallen_pieces[test_blk_1] == 1'b0) && 
                              (fallen_pieces[test_blk_2] == 1'b0) && 
                              (fallen_pieces[test_blk_3] == 1'b0) && 
                              (fallen_pieces[test_blk_4] == 1'b0);
        end
    endfunction

    task spawn_new_block;
        begin
            cur_pos_x <= GAME_WIDTH / 2 - 1;
            cur_pos_y <= 0;
            cur_rot <= 0;
            cur_piece <= random_seed[2:0];
            
            if (fallen_pieces[cur_blk_1] | fallen_pieces[cur_blk_2] | 
                fallen_pieces[cur_blk_3] | fallen_pieces[cur_blk_4]) begin
                game_over <= 1'b1;
            end
        end
    endtask

    task freeze_block;
        begin
            fallen_pieces[cur_blk_1] <= 1'b1;
            fallen_pieces[cur_blk_2] <= 1'b1;
            fallen_pieces[cur_blk_3] <= 1'b1;
            fallen_pieces[cur_blk_4] <= 1'b1;
            spawn_new_block();
        end
    endtask

    function should_freeze;
        input dummy;
        begin
            should_freeze = (cur_pos_y + cur_height >= GAME_HEIGHT) ||
                            (fallen_pieces[cur_blk_1 + BLOCKS_WIDE] == 1'b1) ||
                            (fallen_pieces[cur_blk_2 + BLOCKS_WIDE] == 1'b1) ||
                            (fallen_pieces[cur_blk_3 + BLOCKS_WIDE] == 1'b1) ||
                            (fallen_pieces[cur_blk_4 + BLOCKS_WIDE] == 1'b1);
        end
    endfunction

    task clear_row;
        input [BITS_Y_POS-1:0] row_to_clear;
        reg [(BLOCKS_WIDE*BLOCKS_HIGH)-1:0] upper_part, lower_part, cleared_board;
        begin
            upper_part = fallen_pieces & ({(BLOCKS_WIDE*BLOCKS_HIGH){1'b1}} << ((row_to_clear + 1) * BLOCKS_WIDE));
            lower_part = fallen_pieces & ({(BLOCKS_WIDE*BLOCKS_HIGH){1'b1}} >> ((BLOCKS_HIGH - row_to_clear) * BLOCKS_WIDE));
            lower_part = lower_part << BLOCKS_WIDE;
            cleared_board = lower_part | upper_part;
            cleared_board[(BLOCKS_WIDE*BLOCKS_HIGH)-1-:BLOCKS_WIDE] = {BLOCKS_WIDE{1'b0}};
            fallen_pieces <= cleared_board;
        end
    endtask

    // Random number generation
    always @(posedge clk) begin
        random_seed <= {random_seed[30:0],
                        random_seed[31] ^ random_seed[21] ^ random_seed[1] ^ random_seed[0]};
    end

    // VGA timing generation
    always @(posedge clk) begin
        clk25 <= ~clk25;
    end

    always @(posedge clk25) begin
        if (h_counter == H_TOTAL - 1) begin
            h_counter <= 0;
            v_counter <= (v_counter == V_TOTAL - 1) ? 0 : v_counter + 1;
        end else begin
            h_counter <= h_counter + 1;
        end
    end

   // Game logic
always @(posedge clk25) begin
    if (reset) begin
        // Reset game state
        fallen_pieces <= {(BLOCKS_WIDE*BLOCKS_HIGH){1'b0}};
        game_over <= 1'b0;
        drop_timer <= 0;
        move_timer <= 0;
        check_rows <= 0;
        clear_state <= IDLE;
        spawn_new_block();
    end else begin
        // Input handling and timers
        {left_prev, right_prev, rotate_prev} <= {left, right, rotate};
        drop_interval <= drop_button ? 1_000_000 : 25_000_000;

        // Dropping logic
        if (drop_timer < drop_interval) begin
            drop_timer <= drop_timer + 1;
        end else begin
            drop_timer <= 0;
            if (!should_freeze(1'b0)) begin
                cur_pos_y <= cur_pos_y + 1;
            end else begin
                freeze_block();
                check_rows <= 1;
                clear_state <= IDLE;
                game_over <= top_row_occupied;
            end
        end

        // Movement logic
        if (move_timer > 0) begin
            move_timer <= move_timer - 1;
        end else if ((left && !left_prev) || (right && !right_prev)) begin
            move_timer <= 20'hFFFFF;
            new_x = left && !left_prev ? cur_pos_x - 1 : cur_pos_x + 1;
            can_move = 1;
            if (new_x < 0 || new_x + cur_width > GAME_WIDTH ||
                fallen_pieces[cur_blk_1 + (left ? -1 : 1)] ||
                fallen_pieces[cur_blk_2 + (left ? -1 : 1)] ||
                fallen_pieces[cur_blk_3 + (left ? -1 : 1)] ||
                fallen_pieces[cur_blk_4 + (left ? -1 : 1)]) begin
                can_move = 0;
            end
            if (can_move) begin
                cur_pos_x <= new_x;
            end
        end

        // Rotation logic
        if (rotate && !rotate_prev) begin
            if (can_rotate_func((cur_rot + 1) % 4)) begin
                cur_rot <= (cur_rot + 1) % 4;
            end
        end

        // Down button logic
        if (down) begin
            drop_distance = 0;
            while (!should_freeze(1'b0) && drop_distance < GAME_HEIGHT) begin
                drop_distance = drop_distance + 1;
            end
            cur_pos_y <= cur_pos_y + drop_distance - 1;
            freeze_block();
            check_rows <= 1;
            clear_state <= IDLE;
        end

        // Row clearing state machine
        case (clear_state)
            IDLE: if (check_rows) begin
                check_row <= BLOCKS_HIGH - 1;
                clear_state <= CHECK;
            end
            CHECK: begin
                if (fallen_pieces[check_row * BLOCKS_WIDE +: BLOCKS_WIDE] == {BLOCKS_WIDE{1'b1}}) begin
                    clear_state <= CLEAR;
                end else if (check_row > 0) begin
                    check_row <= check_row - 1;
                end else begin
                    check_rows <= 0;
                    clear_state <= IDLE;
                end
            end
            CLEAR: begin
                clear_row(check_row);
                clear_state <= NEXT;
            end
            NEXT: begin
                if (check_row > 0) begin
                    check_row <= check_row - 1;
                    clear_state <= CHECK;
                end else begin
                    check_rows <= 0;
                    clear_state <= IDLE;
                end
            end
        endcase
    end
end

    // VGA display logic
    wire [4:0] game_x = (h_counter * H_SCALE) >> 10;
    wire [3:0] game_y = (v_counter * V_SCALE) >> 10;
    
    // VGA display logic
always @(posedge clk25) begin
    if (h_counter < H_DISPLAY && v_counter < V_DISPLAY) begin
        if (game_over) begin
            if (game_x < GAME_WIDTH && game_y < GAME_HEIGHT) begin
                if (game_over_pattern[game_y * GAME_WIDTH + game_x]) begin
                    {vga_r, vga_g, vga_b} <= 3'b100; // Red for "GAME OVER" text
                end else begin
                    {vga_r, vga_g, vga_b} <= 3'b000; // Black for background
                end
            end else begin
                {vga_r, vga_g, vga_b} <= 3'b000; // Black for area outside the game grid
            end
        end else begin
            {vga_r, vga_g, vga_b} <= 3'b000; // Black background
				if(h_counter[4:0] == 0 || v_counter[4:0] == 0) begin // pokusaj odvajanja blokova
					{vga_r, vga_g, vga_b} <= 3'b000; 
				end
            else if (fallen_pieces[game_y * GAME_WIDTH + game_x]) begin
                {vga_r, vga_g, vga_b} <= 3'b111; // White for fallen pieces
            end
            else if ((cur_blk_1 == (game_y * GAME_WIDTH + game_x)) ||
                     (cur_blk_2 == (game_y * GAME_WIDTH + game_x)) ||
                     (cur_blk_3 == (game_y * GAME_WIDTH + game_x)) ||
                     (cur_blk_4 == (game_y * GAME_WIDTH + game_x))) begin
                case (cur_piece) // Color based on piece type
                    3'b000: {vga_r, vga_g, vga_b} <= 3'b100; // I-piece (red)
                    3'b001: {vga_r, vga_g, vga_b} <= 3'b010; // L-piece (green)
                    3'b010: {vga_r, vga_g, vga_b} <= 3'b110; // S-piece (yellow)
                    3'b011: {vga_r, vga_g, vga_b} <= 3'b001; // Z-piece (blue)
                    3'b100: {vga_r, vga_g, vga_b} <= 3'b101; // T-piece (purple)
                    3'b101: {vga_r, vga_g, vga_b} <= 3'b100; // J-piece (red)
                    3'b110: {vga_r, vga_g, vga_b} <= 3'b011; // O-piece (cyan)
                    default: {vga_r, vga_g, vga_b} <= 3'b011; // Default (cyan)
                endcase
            end
        end
    end else begin
        {vga_r, vga_g, vga_b} <= 3'b000; // Black outside display area
    end
end

// Initialization
initial begin
    fallen_pieces = {(BLOCKS_WIDE*BLOCKS_HIGH){1'b0}};
    spawn_new_block();
end

endmodule


module calc_cur_blk #(
    parameter GAME_WIDTH = 20
)(
    input [2:0] piece,   // Changed to 3 bits
    input [4:0] pos_x, 
    input [3:0] pos_y, 
    input [1:0] rot, 
    output reg [8:0] blk_1, 
    output reg [8:0] blk_2, 
    output reg [8:0] blk_3, 
    output reg [8:0] blk_4, 
    output reg [4:0] width, 
    output reg [4:0] height
);

always @* begin
    case (piece)
        3'b000: begin // I-block
             case (rot)
                2'b00, 2'b10: begin // Vertical
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
                    blk_4 = ((pos_y + 3) * GAME_WIDTH) + pos_x;
                    width = 1;
                    height = 4;
                end
                2'b01, 2'b11: begin // Horizontal
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = (pos_y * GAME_WIDTH) + pos_x + 2;
                    blk_4 = (pos_y * GAME_WIDTH) + pos_x + 3;
                    width = 4;
                    height = 1;
                end
            endcase
        end
        3'b001: begin // L-block
            case (rot)
                2'b00: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x + 1;
                    width = 2;
                    height = 3;
                end
                2'b01: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = (pos_y * GAME_WIDTH) + pos_x + 2;
                    blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    width = 3;
                    height = 2;
                end
                2'b10: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x + 1;
                    width = 2;
                    height = 3;
                end
                2'b11: begin
                    blk_1 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 2;
                    blk_4 = (pos_y * GAME_WIDTH) + pos_x + 2;
                    width = 3;
                    height = 2;
                end
            endcase
        end
		  3'b010: begin // S-block
    case (rot)
        2'b00, 2'b10: begin 
            blk_1 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
            blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
            blk_3 = (pos_y * GAME_WIDTH) + pos_x + 1;
            blk_4 = (pos_y * GAME_WIDTH) + pos_x + 2;
            width = 3;
            height = 2;
        end
        2'b01, 2'b11: begin 
            blk_1 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
            blk_2 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
            blk_3 = ((pos_y + 2) * GAME_WIDTH) + pos_x + 1;
            blk_4 = ((pos_y + 3) * GAME_WIDTH) + pos_x + 1;
            width = 2;
            height = 3;
        end
    endcase
end

3'b011: begin // Z-block
    case (rot)
        2'b00, 2'b10: begin 
            blk_1 = (pos_y * GAME_WIDTH) + pos_x;
            blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
            blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
            blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 2;
            width = 3;
            height = 2;
        end
        2'b01, 2'b11: begin 
            blk_1 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
            blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
            blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
            blk_4 = (pos_y * GAME_WIDTH) + pos_x + 1;
            width = 2;
            height = 3;
        end
    endcase
end
      
        3'b100: begin // T-block
            case (rot)
                2'b00: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 2;
                    width = 3;
                    height = 2;
                end
                2'b01: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
                    width = 2;
                    height = 3;
                end
                2'b10: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = (pos_y * GAME_WIDTH) + pos_x + 2;
                    blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    width = 3;
                    height = 2;
                end
                2'b11: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x + 1;
                    width = 2;
                    height = 3;
                end
            endcase
        end
        3'b101: begin // J-block
            case (rot)
                2'b00: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_3 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x + 1;
                    width = 2;
                    height = 3;
                end
                2'b01: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = (pos_y * GAME_WIDTH) + pos_x + 2;
                    blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 2;
                    width = 3;
                    height = 2;
                end
                2'b10: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_4 = ((pos_y + 2) * GAME_WIDTH) + pos_x;
                    width = 2;
                    height = 3;
                end
                2'b11: begin
                    blk_1 = (pos_y * GAME_WIDTH) + pos_x;
                    blk_2 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
                    blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
                    blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 2;
                    width = 3;
                    height = 2;
                end
            endcase
        end
        3'b110: begin // O-block
            blk_1 = (pos_y * GAME_WIDTH) + pos_x;
            blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
            blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
            blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
            width = 2;
            height = 2;
        end
        default: begin // Default to O-block
             blk_1 = (pos_y * GAME_WIDTH) + pos_x;
            blk_2 = (pos_y * GAME_WIDTH) + pos_x + 1;
            blk_3 = ((pos_y + 1) * GAME_WIDTH) + pos_x;
            blk_4 = ((pos_y + 1) * GAME_WIDTH) + pos_x + 1;
            width = 2;
            height = 2;
        end
    endcase
end

endmodule
