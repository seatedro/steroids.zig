const std = @import("std");
const math = std.math;
const CustomAllocator = @import("allocator.zig").CustomAllocator;
const rl = @import("raylib");
const rlm = rl.math;
const Vector2 = rl.Vector2;

const THICKNESS = 2.5;
const SCREEN_SIZE = rl.Vector2.init(800, 600);
const SCALE = 24.0;

const HighScore = struct {
    name: [6]u8,
    score: u32,
};

const State = struct {
    allocator: std.mem.Allocator,
    ship: Ship,
    now: f32,
    delta: f32,
    stage_start: f32 = 0.0,
    aliens: std.ArrayList(Alien),
    asteroids: std.ArrayList(Asteroid),
    particles: std.ArrayList(Particle),
    asteroids_q: std.ArrayList(Asteroid),
    projectiles: std.ArrayList(Projectile),
    rand: std.rand.Random,
    lives: u32 = 3,
    last_score: u32 = 0,
    score: u32 = 0,
    high_score: u32 = 0,
    //TODO: disable getting shot by yourself.
    hard_mode: bool = true,
    bloop: usize = 0,
    last_bloop: usize = 0,
    bloop_intensity: usize = 0,
    frame: usize = 0,
    game_started: bool = false,
    game_over: bool = false,
    player_name: [6]u8 = [_]u8{0} ** 6, // 5 chars + null terminator
    name_length: u8 = 0,
    name_input_active: bool = false,
    name_entered: bool = false,
    viewing_high_scores: bool = false,
    high_scores: [3]HighScore = [_]HighScore{.{ .name = [_]u8{0} ** 6, .score = 0 }} ** 3,
};

var state: State = undefined;

extern fn js_save_high_score(score: u32, name_ptr: [*]u8, name_len: u8) void;
extern fn js_load_high_scores(high_scores: [*]HighScore) void;
extern fn js_load_player_name(name_ptr: [*]u8) u8;

export fn wasm_save_high_score(score: u32) void {
    state.high_score = score;
}

const Sound = struct {
    asteroid: rl.Sound,
    bloop_lo: rl.Sound,
    bloop_hi: rl.Sound,
    explode: rl.Sound,
    shoot: rl.Sound,
    thrust: rl.Sound,
};

var sound: Sound = undefined;

const Transform = struct {
    origin: Vector2,
    scale: f32,
    rot: f32,
    fn apply(self: Transform, pos: Vector2) Vector2 {
        return rlm.vector2Add(
            self.origin,
            rlm.vector2Rotate(
                rlm.vector2Scale(pos, self.scale),
                self.rot,
            ),
        );
    }
};

const Ship = struct {
    pos: Vector2,
    vel: Vector2,
    rot: f32,
    death_time: f32 = 0.0,

    fn isDead(self: Ship) bool {
        return self.death_time > 0.0;
    }
};

const Asteroid = struct {
    pos: Vector2,
    vel: Vector2,
    size: AsteroidSize,
    seed: u64,
    remove: bool = false,
};

const AlienSize = enum {
    BIG,
    SMALL,

    fn size(self: AlienSize) f32 {
        return switch (self) {
            .BIG => SCALE * 4.0,
            .SMALL => SCALE * 2.0,
        };
    }

    fn dirChangeTime(self: AlienSize) f32 {
        return switch (self) {
            .BIG => 0.65,
            .SMALL => 0.25,
        };
    }

    fn shotTime(self: AlienSize) f32 {
        return switch (self) {
            .BIG => 1.25,
            .SMALL => 0.75,
        };
    }

    fn speed(self: AlienSize) f32 {
        return switch (self) {
            .BIG => 2,
            .SMALL => 4,
        };
    }
};

const Alien = struct {
    pos: Vector2,
    dir: Vector2,
    size: AlienSize,
    last_shot: f32 = 0.0,
    last_dir: f32 = 0.0, // last time direction was changed
    remove: bool = false,
};

const ParticleType = enum {
    LINE,
    DOT,
};

const Particle = struct {
    pos: Vector2,
    vel: Vector2,
    ttl: f32,

    values: union(ParticleType) {
        LINE: struct {
            rot: f32,
            len: f32,
        },
        DOT: struct {
            radius: f32,
        },
    },
};

const Projectile = struct {
    pos: Vector2,
    vel: Vector2,
    ttl: f32,
    spawn: f32,
    remove: bool = false,
};

fn drawNumber(n: usize, pos: Vector2) !void {
    const NUMBER_LINES = [10][]const [2]f32{
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0 } },
        &.{ .{ 0.5, 0 }, .{ 0.5, 1 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0 }, .{ 1, 0 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 } },
        &.{ .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 1 }, .{ 1, 0 } },
        &.{ .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 1, 0 }, .{ 0, 0 } },
        &.{ .{ 0, 1 }, .{ 0, 0 }, .{ 1, 0 }, .{ 1, 0.5 }, .{ 0, 0.5 } },
        &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } },
        &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 }, .{ 0, 0.5 }, .{ 0, 0 } },
        &.{ .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 0, 0.5 }, .{ 1, 0.5 } },
    };

    var pos2 = pos;

    var val = n;
    var digits: usize = 0;
    while (val >= 0) {
        digits += 1;
        val /= 10;
        if (val == 0) {
            break;
        }
    }

    val = n;
    while (val >= 0) {
        var points = try std.BoundedArray(Vector2, 16).init(0);
        for (NUMBER_LINES[val % 10]) |p| {
            try points.append(Vector2.init(p[0] - 0.5, (1.0 - p[1]) - 0.5));
        }

        drawLines(pos2, SCALE * 0.8, 0, points.slice(), false);
        pos2.x -= SCALE;
        val /= 10;
        if (val == 0) {
            break;
        }
    }
}

fn drawLines(origin: Vector2, scale: f32, rot: f32, lines: []const Vector2, connect: bool) void {
    const transform = Transform{
        .origin = origin,
        .scale = scale,
        .rot = rot,
    };

    const bound = if (connect) lines.len else lines.len - 1;
    for (0..bound) |i| {
        rl.drawLineEx(
            transform.apply(lines[i]),
            transform.apply(lines[(i + 1) % lines.len]),
            THICKNESS,
            rl.Color.white,
        );
    }
}

fn drawAlien(pos: Vector2, size: f32) void {
    drawLines(pos, size, 0, &.{
        Vector2.init(-0.5, 0.0),
        Vector2.init(-0.3, 0.3),
        Vector2.init(0.3, 0.3),
        Vector2.init(0.5, 0.0),
        Vector2.init(0.3, -0.3),
        Vector2.init(-0.3, -0.3),
        Vector2.init(-0.5, 0.0),
        Vector2.init(0.5, 0.0),
    }, false);

    drawLines(pos, size, 0, &.{
        Vector2.init(-0.2, -0.3),
        Vector2.init(-0.1, -0.5),
        Vector2.init(0.1, -0.5),
        Vector2.init(0.2, -0.3),
    }, false);
}

const AsteroidSize = enum {
    BIG,
    MEDIUM,
    SMALL,

    fn size(self: AsteroidSize) f32 {
        return switch (self) {
            .BIG => SCALE * 3.0,
            .MEDIUM => SCALE * 1.5,
            .SMALL => SCALE * 1.0,
        };
    }

    fn score(self: AsteroidSize) u32 {
        return switch (self) {
            .BIG => 20,
            .MEDIUM => 50,
            .SMALL => 100,
        };
    }

    fn collisionScale(self: AsteroidSize) f32 {
        return switch (self) {
            .BIG => 0.4,
            .MEDIUM => 0.7,
            .SMALL => 1.0,
        };
    }

    fn velocityScale(self: AsteroidSize) f32 {
        return switch (self) {
            .BIG => 0.6,
            .MEDIUM => 1.0,
            .SMALL => 1.4,
        };
    }
};

fn drawAsteroid(a: Asteroid) !void {
    var prng = std.rand.Xoshiro256.init(a.seed);
    var random = prng.random();

    var points = try std.BoundedArray(Vector2, 16).init(0);
    const n = random.intRangeLessThan(usize, 6, 15);

    for (0..n) |i| {
        var radius = 0.5 + (0.2 * random.float(f32));
        if (random.float(f32) < 0.2) {
            radius -= 0.3;
        }
        const angle: f32 = (@as(
            f32,
            @floatFromInt(i),
        ) * (math.tau / @as(
            f32,
            @floatFromInt(n),
        )) + (math.pi * 0.125 * random.float(
            f32,
        )));

        try points.append(
            rlm.vector2Scale(Vector2.init(math.cos(angle), math.sin(angle)), radius),
        );
    }

    drawLines(
        a.pos,
        a.size.size(),
        0.0,
        points.slice(),
        true,
    );
}

fn splatLines(pos: Vector2, n: usize) !void {
    const particle_angle = math.tau * state.rand.float(f32);
    for (0..n) |_| {
        try state.particles.append(.{
            .pos = rlm.vector2Add(pos, Vector2.init(
                state.rand.float(f32) * 3,
                state.rand.float(f32) * 3,
            )),
            .vel = rlm.vector2Scale(Vector2.init(
                math.cos(particle_angle),
                math.sin(particle_angle),
            ), 2.0 * state.rand.float(f32)),
            .ttl = 2.0 + state.rand.float(f32),
            .values = .{
                .LINE = .{
                    .len = SCALE * (0.5 + (0.4 * state.rand.float(f32))),
                    .rot = state.rand.float(f32) * math.tau,
                },
            },
        });
    }
}

fn splatDots(pos: Vector2, n: usize) !void {
    for (0..n) |_| {
        const particle_angle = math.tau * state.rand.float(f32);
        try state.particles.append(.{
            .pos = rlm.vector2Add(pos, Vector2.init(
                state.rand.float(f32) * 3,
                state.rand.float(f32) * 3,
            )),
            .vel = rlm.vector2Scale(Vector2.init(
                math.cos(particle_angle),
                math.sin(particle_angle),
            ), 0.3 + (0.5 * state.rand.float(f32))),
            .ttl = 0.3 + (0.4 * state.rand.float(f32)),
            .values = .{
                .DOT = .{
                    .radius = SCALE * 0.025,
                },
            },
        });
    }
}

fn hitAsteroid(a: *Asteroid, impact: ?Vector2) !void {
    rl.playSound(sound.asteroid);
    state.score += a.size.score();
    a.remove = true;

    try splatDots(a.pos, 10);

    if (a.size == .SMALL) {
        return;
    }

    for (0..2) |_| {
        const dir = rlm.vector2Normalize(a.vel);
        const size: AsteroidSize = switch (a.size) {
            .BIG => .MEDIUM,
            .MEDIUM => .SMALL,
            else => unreachable,
        };

        try state.asteroids_q.append(Asteroid{
            .pos = Vector2.init(
                a.pos.x + state.rand.float(f32) * 1.2,
                a.pos.y + state.rand.float(f32) * 1.2,
            ),
            .vel = rlm.vector2Add(
                rlm.vector2Scale(
                    dir,
                    size.velocityScale() * 1.2 * state.rand.float(f32),
                ),
                if (impact) |i| rlm.vector2Scale(i, 0.9) else Vector2.init(0, 0),
            ),
            .size = size,
            .seed = state.rand.int(u64),
        });
    }
}

fn resetGame() !void {
    state.lives = 3;
    state.score = 0;
    state.game_over = false;
    state.name_input_active = false;

    if (!state.name_entered) {
        state.name_length = js_load_player_name(&state.player_name);
        if (state.name_length == 0) {
            state.name_input_active = true;
        } else {
            state.name_entered = true;
        }
    }

    try resetStage();
    try resetAsteroids();
}
fn resetStage() !void {
    if (state.ship.isDead()) {
        if (state.lives != 0) {
            state.lives -= 1;
        } else {
            state.game_over = true;
            if (state.score > state.high_score) {
                state.high_score = state.score;
            }
        }
    }
    state.ship.death_time = 0.0;
    state.ship = .{
        .pos = rlm.vector2Scale(SCREEN_SIZE, 0.5),
        .vel = rl.Vector2.init(0, 0),
        .rot = 0,
    };

    try state.aliens.append(Alien{
        .pos = Vector2.init(
            if (state.rand.boolean()) 0 else SCREEN_SIZE.x - SCALE,
            state.rand.float(f32) * SCALE,
        ),
        .dir = Vector2.init(0, 0),
        .size = .BIG,
    });
    state.stage_start = state.now;
}

fn resetAsteroids() !void {
    try state.asteroids.resize(0);

    for (0..(10 + state.score / 1500)) |_| {
        const angle = math.tau * std.Random.float(state.rand, f32);
        const size = state.rand.enumValue(AsteroidSize);
        try state.asteroids_q.append(Asteroid{
            .pos = Vector2.init(
                state.rand.float(f32) * SCREEN_SIZE.x,
                state.rand.float(f32) * SCREEN_SIZE.y,
            ),
            .vel = rlm.vector2Scale(
                Vector2.init(math.cos(angle), math.sin(angle)),
                size.velocityScale() * 1.0 * state.rand.float(f32),
            ),
            .size = size,
            .seed = state.rand.int(u64),
        });
    }
}

fn update() !void {
    const ROT_SPEED = 1;
    const SPEED = 10;

    if (!state.ship.isDead()) {
        if (rl.isKeyDown(.key_d) or rl.isKeyDown(.key_l) or rl.isKeyDown(.key_right)) {
            state.ship.rot += ROT_SPEED * math.tau * state.delta;
        }

        if (rl.isKeyDown(.key_a) or rl.isKeyDown(.key_j) or rl.isKeyDown(.key_left)) {
            state.ship.rot -= ROT_SPEED * math.tau * state.delta;
        }

        const angle = state.ship.rot + math.pi / 2.0;
        const dir = Vector2.init(math.cos(angle), math.sin(angle));
        if (rl.isKeyDown(.key_w) or rl.isKeyDown(.key_i) or rl.isKeyDown(.key_up)) {
            state.ship.vel = rlm.vector2Subtract(state.ship.vel, rlm.vector2Scale(dir, state.delta * SPEED));
            rl.playSound(sound.thrust);
        }

        const DRAG = 0.02;
        state.ship.vel = rlm.vector2Scale(state.ship.vel, 1.0 - DRAG);
        state.ship.pos = rlm.vector2Add(state.ship.pos, state.ship.vel);
        // modulo the ship's position to keep it within the screen
        state.ship.pos = Vector2.init(
            @mod(state.ship.pos.x, SCREEN_SIZE.x),
            @mod(state.ship.pos.y, SCREEN_SIZE.y),
        );

        if (rl.isKeyPressed(.key_space) or rl.isMouseButtonPressed(.mouse_button_left)) {
            try state.projectiles.append(.{
                .pos = rlm.vector2Add(rlm.vector2Scale(dir, SCALE * 0.55), state.ship.pos),
                .vel = rlm.vector2Scale(dir, -SCALE * 0.8),
                .ttl = 1.25,
                .spawn = state.now,
            });
            rl.playSound(sound.shoot);

            state.ship.vel = rlm.vector2Add(state.ship.vel, rlm.vector2Scale(dir, 0.5));
        }

        // projectile vs ship collision
        if (state.hard_mode) {
            for (state.projectiles.items) |*p| {
                if (!p.remove and (state.now - p.spawn) > 0.05 and rlm.vector2Distance(state.ship.pos, p.pos) < (SCALE * 0.75)) {
                    p.remove = true;
                    state.ship.death_time = state.now;
                }
            }
        }
    }

    for (state.asteroids_q.items) |a| {
        try state.asteroids.append(a);
    }
    try state.asteroids_q.resize(0);

    {
        var i: usize = 0;
        while (i < state.asteroids.items.len) {
            var a = &state.asteroids.items[i];
            a.pos = rlm.vector2Add(a.pos, a.vel);
            a.pos = Vector2.init(
                @mod(a.pos.x, SCREEN_SIZE.x),
                @mod(a.pos.y, SCREEN_SIZE.y),
            );

            // asteroid ship collision
            if (!state.ship.isDead() and rlm.vector2Distance(a.pos, state.ship.pos) < a.size.size() / 2.0) {
                state.ship.death_time = state.now;
                a.remove = true;
                try hitAsteroid(a, rlm.vector2Normalize(state.ship.vel));
            }

            // aliens asteroid collision
            for (state.aliens.items) |*al| {
                if (!al.remove and rlm.vector2Distance(al.pos, a.pos) < a.size.size() / 2.0) {
                    al.remove = true;
                    try hitAsteroid(a, rlm.vector2Normalize(al.pos));
                }
            }

            // projectile asteroids collision
            for (state.projectiles.items) |*p| {
                if (!p.remove and rlm.vector2Distance(a.pos, p.pos) < a.size.size() * a.size.collisionScale()) {
                    p.remove = true;
                    try hitAsteroid(a, rlm.vector2Normalize(p.vel));
                }
            }

            if (a.remove) {
                _ = state.asteroids.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    {
        var i: usize = 0;
        while (i < state.particles.items.len) {
            var p = &state.particles.items[i];
            p.pos = rlm.vector2Add(p.pos, p.vel);
            p.pos = Vector2.init(
                @mod(p.pos.x, SCREEN_SIZE.x),
                @mod(p.pos.y, SCREEN_SIZE.y),
            );
            p.ttl -= state.delta;
            if (p.ttl <= 0) {
                _ = state.particles.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    {
        var i: usize = 0;
        while (i < state.projectiles.items.len) {
            var p = &state.projectiles.items[i];
            p.pos = rlm.vector2Add(p.pos, p.vel);
            p.ttl -= state.delta;
            // if (state.hard_mode) {
            // p.pos = Vector2.init(
            //     @mod(p.pos.x, SCREEN_SIZE.x),
            //     @mod(p.pos.y, SCREEN_SIZE.y),
            // );
            // }
            if (p.ttl <= 0 or p.remove) {
                _ = state.projectiles.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    {
        var i: usize = 0;
        while (i < state.aliens.items.len) {
            var al = &state.aliens.items[i];

            // projectile alien collision
            for (state.projectiles.items) |*p| {
                if (!p.remove and (state.now - p.spawn) > 0.25 and rlm.vector2Distance(al.pos, p.pos) < al.size.size()) {
                    p.remove = true;
                    al.remove = true;
                }
            }

            // ship alien collision
            if (!state.ship.isDead() and !al.remove and rlm.vector2Distance(al.pos, state.ship.pos) < al.size.size() / 2.0) {
                state.ship.death_time = state.now;
                al.remove = true;
            }

            if (!al.remove) {
                if ((state.now - al.last_dir) > al.size.dirChangeTime()) {
                    al.last_dir = state.now;
                    const angle = math.tau * std.Random.float(state.rand, f32);
                    al.dir = Vector2.init(math.cos(angle), math.sin(angle));
                }

                al.pos = rlm.vector2Add(al.pos, rlm.vector2Scale(al.dir, al.size.speed()));
                al.pos = Vector2.init(
                    @mod(al.pos.x, SCREEN_SIZE.x),
                    @mod(al.pos.y, SCREEN_SIZE.y),
                );

                if ((state.now - al.last_shot) > al.size.shotTime()) {
                    al.last_shot = state.now;
                    const dir = rlm.vector2Normalize(rlm.vector2Subtract(state.ship.pos, al.pos));

                    try state.projectiles.append(.{
                        .pos = rlm.vector2Add(rlm.vector2Scale(dir, SCALE * 0.55), al.pos),
                        .vel = rlm.vector2Scale(dir, SCALE * 0.25),
                        .ttl = 1.25,
                        .spawn = state.now,
                    });
                    rl.playSound(sound.shoot);
                }
            }

            if (al.remove) {
                rl.playSound(sound.asteroid);
                try splatDots(al.pos, 20);
                try splatLines(al.pos, 5);

                _ = state.aliens.swapRemove(i);
                continue;
            }
            i += 1;
        }
    }

    if (state.ship.death_time == state.now) {
        rl.playSound(sound.explode);
        try splatDots(state.ship.pos, 20);
        try splatLines(state.ship.pos, 5);
    }

    if (state.ship.isDead() and (state.now - state.ship.death_time) >= 3.0) {
        try resetStage();
    }

    if (state.asteroids.items.len == 0) {
        try resetAsteroids();
    }

    const bloop_intensity: usize = @min(@as(usize, @intFromFloat(state.now - state.stage_start)) / 16, 4);
    const bloop_mod: usize = 60;
    const adjusted_bloop_mod: usize = @max(1, bloop_mod >> @intCast(bloop_intensity));

    if (state.frame % adjusted_bloop_mod == 0) {
        state.bloop += 1;
    }

    if (!state.ship.isDead() and state.bloop != state.last_bloop) {
        rl.playSound(if (state.bloop % 2 == 0) sound.bloop_hi else sound.bloop_lo);
    }
    state.last_bloop = state.bloop;

    if (state.asteroids.items.len == 0 and state.aliens.items.len == 0) {
        try resetAsteroids();
    }

    if ((state.last_score / 500) != state.score / 500) {
        try state.aliens.append(Alien{
            .pos = Vector2.init(
                if (state.rand.boolean()) 0 else SCREEN_SIZE.x - SCALE,
                state.rand.float(f32) * SCALE,
            ),
            .dir = Vector2.init(0, 0),
            .size = .BIG,
        });
    }
    if ((state.last_score / 1000) != state.score / 1000) {
        try state.aliens.append(Alien{
            .pos = Vector2.init(
                if (state.rand.boolean()) 0 else SCREEN_SIZE.x - SCALE,
                state.rand.float(f32) * SCALE,
            ),
            .dir = Vector2.init(0, 0),
            .size = .SMALL,
        });
    }

    state.last_score = state.score;
}

const SHIP_LINES = [_]Vector2{
    rl.Vector2.init(-0.4, 0.5), // Bottom left
    rl.Vector2.init(0, -0.5), // Top middle
    rl.Vector2.init(0.4, 0.5), // Bottom right
    rl.Vector2.init(0.3, 0.4), // Bottom right ish
    rl.Vector2.init(-0.3, 0.4), // Bottom left ish
};

fn render() !void {
    if (state.game_over) {
        if (state.viewing_high_scores) {
            renderHighScores();
        } else {
            renderGameOver();
        }
        return;
    }
    // remaining lives
    for (0..state.lives) |i| {
        drawLines(
            Vector2.init(40.0 + (@as(f32, @floatFromInt(i)) * SCALE), SCALE),
            SCALE,
            0,
            &SHIP_LINES,
            true,
        );
    }

    try drawNumber(state.score, Vector2.init(SCREEN_SIZE.x - SCALE, SCALE));

    if (!state.ship.isDead()) {
        drawLines(
            state.ship.pos,
            SCALE,
            state.ship.rot,
            &SHIP_LINES,
            true,
        );

        // draw the thruster
        const thruster_flash: i32 = @intFromFloat(state.now * 20);
        if (rl.isKeyDown(.key_w) and @mod(thruster_flash, 2) == 0) {
            drawLines(
                state.ship.pos,
                SCALE,
                state.ship.rot,
                &[_]Vector2{
                    rl.Vector2.init(-0.3, 0.4),
                    rl.Vector2.init(0.0, 0.8),
                    rl.Vector2.init(0.3, 0.4),
                },
                true,
            );
        }
    }
    for (state.asteroids.items) |a| {
        try drawAsteroid(a);
    }

    for (state.aliens.items) |a| {
        drawAlien(a.pos, a.size.size());
    }

    for (state.particles.items) |p| {
        switch (p.values) {
            .LINE => |line| {
                drawLines(p.pos, line.len, line.rot, &.{ Vector2.init(-0.5, 0.0), Vector2.init(0.5, 0.0) }, true);
            },
            .DOT => |dot| {
                rl.drawCircleV(p.pos, dot.radius, rl.Color.white);
            },
        }
    }

    for (state.projectiles.items) |p| {
        rl.drawCircleV(p.pos, SCALE * 0.08, rl.Color.white);
    }
}

fn renderTitle() void {
    const text = "steroids.zig";
    const subtitle = "press SPACE to start";
    const title_font_size = 60;
    const subtitle_font_size = 20;
    const movement_help_text = "movement: wasd/ijkl/arrows";
    const shoot_help_text = "shoot: space/lmb";

    const title_width = rl.measureText(text, title_font_size);
    const subtitle_width = rl.measureText(subtitle, subtitle_font_size);
    const movement_help_width = rl.measureText(movement_help_text, subtitle_font_size);
    const shoot_help_width = rl.measureText(shoot_help_text, subtitle_font_size);

    const title_x = (@as(f32, @floatFromInt(rl.getScreenWidth())) - @as(f32, @floatFromInt(title_width))) / 2;
    const title_y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2 - 40;

    const subtitle_x = (@as(f32, @floatFromInt(rl.getScreenWidth())) - @as(f32, @floatFromInt(subtitle_width))) / 2;
    const subtitle_y = title_y + 80;

    const movement_help_x = (@as(f32, @floatFromInt(rl.getScreenWidth())) - @as(f32, @floatFromInt(movement_help_width))) / 2;
    // place help text at the bottom of the screen
    const movement_help_y = @as(f32, @floatFromInt(rl.getScreenHeight())) - subtitle_font_size - 5;

    const shoot_help_x = (@as(f32, @floatFromInt(rl.getScreenWidth())) - @as(f32, @floatFromInt(shoot_help_width))) / 2;
    const shoot_help_y = movement_help_y - subtitle_font_size;

    rl.drawText(text, @intFromFloat(title_x), @intFromFloat(title_y), title_font_size, rl.Color.white);
    rl.drawText(subtitle, @intFromFloat(subtitle_x), @intFromFloat(subtitle_y), subtitle_font_size, rl.Color.white);
    rl.drawText(movement_help_text, @intFromFloat(movement_help_x), @intFromFloat(movement_help_y), subtitle_font_size, rl.Color.white);
    rl.drawText(shoot_help_text, @intFromFloat(shoot_help_x), @intFromFloat(shoot_help_y), subtitle_font_size, rl.Color.white);
}

fn renderHighScores() void {
    const title_text = "HIGH SCORES";
    const instruction_text = "Press SPACE to return";

    const font_size = 40;
    const small_font_size = 20;

    const title_width = rl.measureText(title_text, font_size);
    const instruction_width = rl.measureText(instruction_text, small_font_size);

    const center_x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
    const center_y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;

    rl.drawText(
        title_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(title_width)) / 2),
        @intFromFloat(center_y - 100),
        font_size,
        rl.Color.white,
    );

    for (state.high_scores, 0..) |high_score, i| {
        if (high_score.score == 0) break;
        const score_text = std.fmt.allocPrintZ(
            state.allocator,
            "{d}. {s}: {d}",
            .{ i + 1, high_score.name[0..5], high_score.score },
        ) catch "ERROR";
        defer state.allocator.free(score_text);
        const score_width = rl.measureText(score_text, small_font_size);
        rl.drawText(
            score_text,
            @intFromFloat(center_x - @as(f32, @floatFromInt(score_width)) / 2),
            @intFromFloat(center_y - 20 + @as(f32, @floatFromInt(i)) * 30),
            small_font_size,
            rl.Color.white,
        );
    }

    rl.drawText(
        instruction_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(instruction_width)) / 2),
        @intFromFloat(center_y + 100),
        small_font_size,
        rl.Color.white,
    );
}

fn renderGameOver() void {
    const game_over_text = "GAME OVER";
    const score_text = std.fmt.allocPrintZ(
        state.allocator,
        "SCORE: {d}",
        .{state.score},
    ) catch "SCORE: ERROR";
    defer state.allocator.free(score_text);
    const high_score_text = std.fmt.allocPrintZ(
        state.allocator,
        "HIGH SCORE: {d}",
        .{state.high_scores[0].score},
    ) catch "HIGH SCORE: ERROR";
    defer state.allocator.free(high_score_text);
    const instruction_text = if (state.name_input_active)
        "Enter your name (max 5 letters) and press ENTER"
    else
        "Press SPACE to play again or H to view high scores";

    const font_size = 40;
    const small_font_size = 20;

    const game_over_width = rl.measureText(game_over_text, font_size);
    const score_width = rl.measureText(score_text, small_font_size);
    const high_score_width = rl.measureText(high_score_text, small_font_size);
    const instruction_width = rl.measureText(instruction_text, small_font_size);

    const center_x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2;
    const center_y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2;

    rl.drawText(
        game_over_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(game_over_width)) / 2),
        @intFromFloat(center_y - 100),
        font_size,
        rl.Color.white,
    );
    rl.drawText(
        score_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(score_width)) / 2),
        @intFromFloat(center_y),
        small_font_size,
        rl.Color.white,
    );
    rl.drawText(
        high_score_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(high_score_width)) / 2),
        @intFromFloat(center_y + 30),
        small_font_size,
        rl.Color.white,
    );
    rl.drawText(
        instruction_text,
        @intFromFloat(center_x - @as(f32, @floatFromInt(instruction_width)) / 2),
        @intFromFloat(center_y + 80),
        small_font_size,
        rl.Color.white,
    );

    if (state.name_input_active) {
        const name_text = std.fmt.allocPrintZ(state.allocator, "{s}", .{state.player_name[0..state.name_length]}) catch "ERROR";
        defer state.allocator.free(name_text);
        const name_width = rl.measureText(name_text, small_font_size);
        rl.drawText(
            name_text,
            @intFromFloat(center_x - @as(f32, @floatFromInt(name_width)) / 2),
            @intFromFloat(center_y + 120),
            small_font_size,
            rl.Color.yellow,
        );
    }
}

pub fn main() anyerror!void {
    // Initialization
    //--------------------------------------------------------------------------------------
    var gpa = CustomAllocator{};
    const allocator = gpa.allocator();

    const screenWidth = 800;
    const screenHeight = 600;

    rl.initWindow(screenWidth, screenHeight, "steroids");
    defer rl.closeWindow(); // Close window and OpenGL context

    // imagine running at 60fps, cringe.
    rl.setTargetFPS(60);

    var prng = std.rand.Xoshiro256.init(@bitCast(std.time.timestamp()));

    state = State{
        .allocator = allocator,
        .delta = 0,
        .now = 0,
        .ship = Ship{
            .pos = rlm.vector2Scale(SCREEN_SIZE, 0.5),
            .vel = rl.Vector2.init(0, 0),
            .rot = 0,
        },
        .aliens = std.ArrayList(Alien).init(allocator),
        .asteroids = std.ArrayList(Asteroid).init(allocator),
        .asteroids_q = std.ArrayList(Asteroid).init(allocator),
        .particles = std.ArrayList(Particle).init(allocator),
        .projectiles = std.ArrayList(Projectile).init(allocator),
        .rand = prng.random(),
    };

    rl.initAudioDevice();
    defer rl.closeAudioDevice();
    sound = Sound{
        .asteroid = rl.loadSound("assets/asteroid.wav"),
        .bloop_lo = rl.loadSound("assets/bloop_lo.wav"),
        .bloop_hi = rl.loadSound("assets/bloop_hi.wav"),
        .explode = rl.loadSound("assets/explode.wav"),
        .shoot = rl.loadSound("assets/shoot.wav"),
        .thrust = rl.loadSound("assets/thrust.wav"),
    };

    rl.setSoundVolume(sound.explode, 0.5);

    defer inline for (std.meta.fields(Sound)) |f| {
        rl.unloadSound(@field(sound, f.name));
    };

    defer state.asteroids.deinit();
    defer state.asteroids_q.deinit();
    defer state.particles.deinit();
    defer state.projectiles.deinit();
    defer state.aliens.deinit();

    // Main game loop
    while (!rl.windowShouldClose()) { // Detect window close button or ESC key
        state.delta = rl.getFrameTime();
        state.now += state.delta;
        defer state.frame += 1;

        if (!state.game_started) {
            if (rl.isKeyPressed(.key_space)) {
                try resetGame();
                state.game_started = true;
            }
        } else if (state.game_over) {
            if (state.name_input_active) {
                const key = rl.getCharPressed();
                if (key >= 32 and key <= 125 and state.name_length < 5) {
                    state.player_name[state.name_length] = @intCast(key);
                    state.name_length += 1;
                }
                if (rl.isKeyPressed(.key_backspace) and state.name_length > 0) {
                    state.name_length -= 1;
                    state.player_name[state.name_length] = 0;
                }
                if (rl.isKeyPressed(.key_enter) and state.name_length > 0) {
                    state.name_entered = true;
                    state.name_input_active = false;
                    js_save_high_score(state.score, &state.player_name, state.name_length);
                    js_load_high_scores(&state.high_scores);
                }
            } else if (state.viewing_high_scores) {
                if (rl.isKeyPressed(.key_space)) {
                    state.viewing_high_scores = false;
                }
            } else if (rl.isKeyPressed(.key_h)) {
                state.viewing_high_scores = true;
            } else if (rl.isKeyPressed(.key_space)) {
                try resetGame();
            }
        } else {
            try update();
        }

        rl.beginDrawing();

        defer rl.endDrawing();

        rl.clearBackground(rl.Color.black);

        if (state.game_started) {
            try render();
        } else {
            renderTitle();
        }

        rl.drawText(
            rl.textFormat("fps: %i", .{rl.getFPS()}),
            rl.getScreenWidth() - 80,
            rl.getScreenHeight() - 20,
            10,
            rl.Color.yellow,
        );
    }
}
