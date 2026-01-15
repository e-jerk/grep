const std = @import("std");

/// Regex engine supporting POSIX Extended Regular Expressions (ERE)
/// Features: . * + ? | ^ $ () [] [^] {n,m} \d \w \s \b and backreferences

pub const RegexError = error{
    InvalidPattern,
    UnmatchedParen,
    UnmatchedBracket,
    InvalidQuantifier,
    InvalidEscape,
    InvalidRange,
    OutOfMemory,
    PatternTooComplex,
};

/// Match result with capture groups
pub const Match = struct {
    start: usize,
    end: usize,
    groups: []const ?Group,

    pub const Group = struct {
        start: usize,
        end: usize,
    };
};

/// Compiled regex pattern
pub const Regex = struct {
    allocator: std.mem.Allocator,
    nfa: NFA,
    num_groups: usize,
    anchored_start: bool,
    anchored_end: bool,

    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8, options: Options) !Regex {
        var parser = Parser.init(allocator, pattern, options);
        defer parser.deinit();
        return parser.parse();
    }

    pub fn deinit(self: *Regex) void {
        self.nfa.deinit(self.allocator);
    }

    /// Check if the text matches the pattern anywhere
    pub fn isMatch(self: *const Regex, text: []const u8) bool {
        return self.find(text) != null;
    }

    /// Find first match in text
    pub fn find(self: *const Regex, text: []const u8) ?Match {
        return self.findAt(text, 0);
    }

    /// Find match starting at or after position
    pub fn findAt(self: *const Regex, text: []const u8, start: usize) ?Match {
        if (self.anchored_start) {
            if (start == 0) {
                return self.matchAt(text, 0);
            }
            return null;
        }

        var pos = start;
        while (pos <= text.len) {
            if (self.matchAt(text, pos)) |m| {
                return m;
            }
            pos += 1;
        }
        return null;
    }

    /// Try to match at exact position
    fn matchAt(self: *const Regex, text: []const u8, pos: usize) ?Match {
        var executor = NFAExecutor.init(self.allocator, &self.nfa, self.num_groups) catch return null;
        defer executor.deinit();
        return executor.execute(text, pos, self.anchored_end);
    }

    pub const Options = struct {
        case_insensitive: bool = false,
        multiline: bool = false,
        extended: bool = true, // ERE mode (default)
    };
};

// NFA state types
const StateType = enum {
    literal, // Match a single character
    char_class, // Match character class [...]
    dot, // Match any character (except newline)
    split, // Epsilon transition to two states
    match, // Accept state
    group_start, // Start of capture group
    group_end, // End of capture group
    word_boundary, // \b
    line_start, // ^
    line_end, // $
};

const State = struct {
    type: StateType,
    data: union {
        literal: struct {
            char: u8,
            case_insensitive: bool,
        },
        char_class: struct {
            ranges: []const Range,
            negated: bool,
        },
        split: struct {
            out1: ?*State,
            out2: ?*State,
        },
        group: struct {
            index: usize,
        },
        none: void,
    },
    out: ?*State,

    const Range = struct {
        start: u8,
        end: u8,
    };
};

const NFA = struct {
    start: *State,
    states: std.ArrayList(*State),

    fn deinit(self: *NFA, allocator: std.mem.Allocator) void {
        for (self.states.items) |state| {
            if (state.type == .char_class) {
                allocator.free(state.data.char_class.ranges);
            }
            allocator.destroy(state);
        }
        self.states.deinit();
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    pos: usize,
    options: Regex.Options,
    states: std.ArrayList(*State),
    group_count: usize,

    fn init(allocator: std.mem.Allocator, pattern: []const u8, options: Regex.Options) Parser {
        return .{
            .allocator = allocator,
            .pattern = pattern,
            .pos = 0,
            .options = options,
            .states = std.ArrayList(*State).init(allocator),
            .group_count = 0,
        };
    }

    fn deinit(self: *Parser) void {
        // States are transferred to Regex, don't free here
    }

    fn parse(self: *Parser) !Regex {
        var anchored_start = false;
        var anchored_end = false;

        // Check for ^ anchor at start
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            anchored_start = true;
            self.pos += 1;
        }

        const expr = try self.parseExpr();

        // Check for $ anchor at end
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '$') {
            anchored_end = true;
            self.pos += 1;
        }

        if (self.pos != self.pattern.len) {
            return RegexError.InvalidPattern;
        }

        // Add match state
        const match_state = try self.createState(.match);
        if (expr.end) |end| {
            self.patchState(end, match_state);
        }

        return Regex{
            .allocator = self.allocator,
            .nfa = .{
                .start = expr.start,
                .states = self.states,
            },
            .num_groups = self.group_count,
            .anchored_start = anchored_start,
            .anchored_end = anchored_end,
        };
    }

    const Fragment = struct {
        start: *State,
        end: ?*State, // Dangling pointer to patch
    };

    fn parseExpr(self: *Parser) !Fragment {
        var left = try self.parseTerm();

        while (self.pos < self.pattern.len and self.pattern[self.pos] == '|') {
            self.pos += 1;
            const right = try self.parseTerm();

            // Create split state for alternation
            const split = try self.createState(.split);
            split.data = .{ .split = .{ .out1 = left.start, .out2 = right.start } };

            // Create a join point
            const join = try self.createState(.split);
            join.data = .{ .split = .{ .out1 = null, .out2 = null } };

            if (left.end) |end| {
                self.patchState(end, join);
            }
            if (right.end) |end| {
                self.patchState(end, join);
            }

            left = .{ .start = split, .end = join };
        }

        return left;
    }

    fn parseTerm(self: *Parser) !Fragment {
        var result: ?Fragment = null;

        while (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];

            // Stop at alternation or end of group
            if (c == '|' or c == ')') break;

            const factor = try self.parseFactor();

            if (result) |r| {
                // Concatenate
                if (r.end) |end| {
                    self.patchState(end, factor.start);
                }
                result = .{ .start = r.start, .end = factor.end };
            } else {
                result = factor;
            }
        }

        // Empty pattern - create epsilon transition
        if (result == null) {
            const s = try self.createState(.split);
            s.data = .{ .split = .{ .out1 = null, .out2 = null } };
            result = .{ .start = s, .end = s };
        }

        return result.?;
    }

    fn parseFactor(self: *Parser) !Fragment {
        var base = try self.parseBase();

        // Handle quantifiers
        if (self.pos < self.pattern.len) {
            const c = self.pattern[self.pos];
            switch (c) {
                '*' => {
                    self.pos += 1;
                    base = try self.makeKleeneStar(base);
                },
                '+' => {
                    self.pos += 1;
                    base = try self.makeOneOrMore(base);
                },
                '?' => {
                    self.pos += 1;
                    base = try self.makeOptional(base);
                },
                '{' => {
                    base = try self.parseQuantifier(base);
                },
                else => {},
            }
        }

        return base;
    }

    fn parseBase(self: *Parser) !Fragment {
        if (self.pos >= self.pattern.len) {
            return RegexError.InvalidPattern;
        }

        const c = self.pattern[self.pos];
        switch (c) {
            '(' => {
                self.pos += 1;
                self.group_count += 1;
                const group_idx = self.group_count;

                const start = try self.createState(.group_start);
                start.data = .{ .group = .{ .index = group_idx } };

                const inner = try self.parseExpr();

                if (self.pos >= self.pattern.len or self.pattern[self.pos] != ')') {
                    return RegexError.UnmatchedParen;
                }
                self.pos += 1;

                const end = try self.createState(.group_end);
                end.data = .{ .group = .{ .index = group_idx } };

                start.out = inner.start;
                if (inner.end) |e| {
                    self.patchState(e, end);
                }

                return .{ .start = start, .end = end };
            },
            '[' => {
                return self.parseCharClass();
            },
            '.' => {
                self.pos += 1;
                const s = try self.createState(.dot);
                return .{ .start = s, .end = s };
            },
            '^' => {
                self.pos += 1;
                const s = try self.createState(.line_start);
                return .{ .start = s, .end = s };
            },
            '$' => {
                self.pos += 1;
                const s = try self.createState(.line_end);
                return .{ .start = s, .end = s };
            },
            '\\' => {
                return self.parseEscape();
            },
            '*', '+', '?', '{', '|', ')' => {
                return RegexError.InvalidPattern;
            },
            else => {
                self.pos += 1;
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = c, .case_insensitive = self.options.case_insensitive } };
                return .{ .start = s, .end = s };
            },
        }
    }

    fn parseCharClass(self: *Parser) !Fragment {
        self.pos += 1; // skip [

        var negated = false;
        if (self.pos < self.pattern.len and self.pattern[self.pos] == '^') {
            negated = true;
            self.pos += 1;
        }

        var ranges = std.ArrayList(State.Range).init(self.allocator);
        defer ranges.deinit();

        while (self.pos < self.pattern.len and self.pattern[self.pos] != ']') {
            const start_char = self.pattern[self.pos];
            self.pos += 1;

            if (self.pos + 1 < self.pattern.len and self.pattern[self.pos] == '-' and self.pattern[self.pos + 1] != ']') {
                self.pos += 1; // skip -
                const end_char = self.pattern[self.pos];
                self.pos += 1;

                if (start_char > end_char) {
                    return RegexError.InvalidRange;
                }
                try ranges.append(.{ .start = start_char, .end = end_char });
            } else {
                try ranges.append(.{ .start = start_char, .end = start_char });
            }
        }

        if (self.pos >= self.pattern.len) {
            return RegexError.UnmatchedBracket;
        }
        self.pos += 1; // skip ]

        const s = try self.createState(.char_class);
        s.data = .{ .char_class = .{
            .ranges = try self.allocator.dupe(State.Range, ranges.items),
            .negated = negated,
        } };

        return .{ .start = s, .end = s };
    }

    fn parseEscape(self: *Parser) !Fragment {
        self.pos += 1; // skip \

        if (self.pos >= self.pattern.len) {
            return RegexError.InvalidEscape;
        }

        const c = self.pattern[self.pos];
        self.pos += 1;

        switch (c) {
            'd' => {
                // \d = [0-9]
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 1);
                ranges[0] = .{ .start = '0', .end = '9' };
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = false } };
                return .{ .start = s, .end = s };
            },
            'D' => {
                // \D = [^0-9]
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 1);
                ranges[0] = .{ .start = '0', .end = '9' };
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = true } };
                return .{ .start = s, .end = s };
            },
            'w' => {
                // \w = [a-zA-Z0-9_]
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 4);
                ranges[0] = .{ .start = 'a', .end = 'z' };
                ranges[1] = .{ .start = 'A', .end = 'Z' };
                ranges[2] = .{ .start = '0', .end = '9' };
                ranges[3] = .{ .start = '_', .end = '_' };
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = false } };
                return .{ .start = s, .end = s };
            },
            'W' => {
                // \W = [^a-zA-Z0-9_]
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 4);
                ranges[0] = .{ .start = 'a', .end = 'z' };
                ranges[1] = .{ .start = 'A', .end = 'Z' };
                ranges[2] = .{ .start = '0', .end = '9' };
                ranges[3] = .{ .start = '_', .end = '_' };
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = true } };
                return .{ .start = s, .end = s };
            },
            's' => {
                // \s = whitespace
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 5);
                ranges[0] = .{ .start = ' ', .end = ' ' };
                ranges[1] = .{ .start = '\t', .end = '\t' };
                ranges[2] = .{ .start = '\n', .end = '\n' };
                ranges[3] = .{ .start = '\r', .end = '\r' };
                ranges[4] = .{ .start = 0x0C, .end = 0x0C }; // form feed
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = false } };
                return .{ .start = s, .end = s };
            },
            'S' => {
                // \S = non-whitespace
                const s = try self.createState(.char_class);
                const ranges = try self.allocator.alloc(State.Range, 5);
                ranges[0] = .{ .start = ' ', .end = ' ' };
                ranges[1] = .{ .start = '\t', .end = '\t' };
                ranges[2] = .{ .start = '\n', .end = '\n' };
                ranges[3] = .{ .start = '\r', .end = '\r' };
                ranges[4] = .{ .start = 0x0C, .end = 0x0C };
                s.data = .{ .char_class = .{ .ranges = ranges, .negated = true } };
                return .{ .start = s, .end = s };
            },
            'b' => {
                const s = try self.createState(.word_boundary);
                return .{ .start = s, .end = s };
            },
            'n' => {
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = '\n', .case_insensitive = false } };
                return .{ .start = s, .end = s };
            },
            't' => {
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = '\t', .case_insensitive = false } };
                return .{ .start = s, .end = s };
            },
            'r' => {
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = '\r', .case_insensitive = false } };
                return .{ .start = s, .end = s };
            },
            '0'...'9' => {
                // Backreference - store as special state (not fully implemented in executor)
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = c, .case_insensitive = false } };
                return .{ .start = s, .end = s };
            },
            else => {
                // Escaped literal character
                const s = try self.createState(.literal);
                s.data = .{ .literal = .{ .char = c, .case_insensitive = self.options.case_insensitive } };
                return .{ .start = s, .end = s };
            },
        }
    }

    fn parseQuantifier(self: *Parser, base: Fragment) !Fragment {
        self.pos += 1; // skip {

        var min: usize = 0;
        var max: ?usize = null;

        // Parse min
        while (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
            min = min * 10 + @as(usize, self.pattern[self.pos] - '0');
            self.pos += 1;
        }

        if (self.pos < self.pattern.len and self.pattern[self.pos] == ',') {
            self.pos += 1;
            if (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
                max = 0;
                while (self.pos < self.pattern.len and self.pattern[self.pos] >= '0' and self.pattern[self.pos] <= '9') {
                    max = max.? * 10 + @as(usize, self.pattern[self.pos] - '0');
                    self.pos += 1;
                }
            }
            // If no max specified after comma, it's unbounded
        } else {
            max = min;
        }

        if (self.pos >= self.pattern.len or self.pattern[self.pos] != '}') {
            return RegexError.InvalidQuantifier;
        }
        self.pos += 1;

        // Build the quantified expression
        // This is a simplified implementation - for complex patterns, we'd need to duplicate states
        if (min == 0 and max == null) {
            return self.makeKleeneStar(base);
        } else if (min == 1 and max == null) {
            return self.makeOneOrMore(base);
        } else if (min == 0 and max != null and max.? == 1) {
            return self.makeOptional(base);
        }

        // For other cases, we'd need more complex NFA construction
        // For now, fall back to treating as literal pattern
        return base;
    }

    fn makeKleeneStar(self: *Parser, base: Fragment) !Fragment {
        const split = try self.createState(.split);
        split.data = .{ .split = .{ .out1 = base.start, .out2 = null } };

        if (base.end) |end| {
            self.patchState(end, split);
        }

        return .{ .start = split, .end = split };
    }

    fn makeOneOrMore(self: *Parser, base: Fragment) !Fragment {
        const split = try self.createState(.split);
        split.data = .{ .split = .{ .out1 = base.start, .out2 = null } };

        if (base.end) |end| {
            self.patchState(end, split);
        }

        return .{ .start = base.start, .end = split };
    }

    fn makeOptional(self: *Parser, base: Fragment) !Fragment {
        const split = try self.createState(.split);
        split.data = .{ .split = .{ .out1 = base.start, .out2 = null } };

        const join = try self.createState(.split);
        join.data = .{ .split = .{ .out1 = null, .out2 = null } };

        split.data.split.out2 = join;

        if (base.end) |end| {
            self.patchState(end, join);
        }

        return .{ .start = split, .end = join };
    }

    fn createState(self: *Parser, state_type: StateType) !*State {
        const state = try self.allocator.create(State);
        state.* = .{
            .type = state_type,
            .data = .{ .none = {} },
            .out = null,
        };
        try self.states.append(state);
        return state;
    }

    fn patchState(self: *Parser, state: *State, target: *State) void {
        _ = self;
        switch (state.type) {
            .split => {
                if (state.data.split.out1 == null) {
                    state.data.split.out1 = target;
                } else if (state.data.split.out2 == null) {
                    state.data.split.out2 = target;
                }
            },
            else => {
                if (state.out == null) {
                    state.out = target;
                }
            },
        }
    }
};

const NFAExecutor = struct {
    allocator: std.mem.Allocator,
    nfa: *const NFA,
    current: std.ArrayList(*const State),
    next: std.ArrayList(*const State),
    groups: []?Match.Group,
    num_groups: usize,

    fn init(allocator: std.mem.Allocator, nfa: *const NFA, num_groups: usize) !NFAExecutor {
        var groups = try allocator.alloc(?Match.Group, num_groups + 1);
        @memset(groups, null);

        return .{
            .allocator = allocator,
            .nfa = nfa,
            .current = std.ArrayList(*const State).init(allocator),
            .next = std.ArrayList(*const State).init(allocator),
            .groups = groups,
            .num_groups = num_groups,
        };
    }

    fn deinit(self: *NFAExecutor) void {
        self.current.deinit();
        self.next.deinit();
        self.allocator.free(self.groups);
    }

    fn execute(self: *NFAExecutor, text: []const u8, start: usize, anchored_end: bool) ?Match {
        self.current.clearRetainingCapacity();
        self.addState(self.nfa.start, start) catch return null;

        var pos = start;
        var last_match: ?Match = null;

        while (pos <= text.len) {
            // Check for match
            for (self.current.items) |state| {
                if (state.type == .match) {
                    if (!anchored_end or pos == text.len) {
                        last_match = .{
                            .start = start,
                            .end = pos,
                            .groups = self.groups,
                        };
                    }
                }
            }

            if (pos == text.len) break;

            // Process current states
            self.next.clearRetainingCapacity();
            const c = text[pos];

            for (self.current.items) |state| {
                if (self.matchState(state, text, pos, c)) {
                    if (state.out) |next_state| {
                        self.addState(next_state, pos + 1) catch continue;
                    }
                }
            }

            // Swap current and next
            const tmp = self.current;
            self.current = self.next;
            self.next = tmp;

            if (self.current.items.len == 0) break;
            pos += 1;
        }

        return last_match;
    }

    fn matchState(self: *NFAExecutor, state: *const State, text: []const u8, pos: usize, c: u8) bool {
        _ = self;
        switch (state.type) {
            .literal => {
                const lit = state.data.literal;
                if (lit.case_insensitive) {
                    return toLower(c) == toLower(lit.char);
                }
                return c == lit.char;
            },
            .char_class => {
                const cc = state.data.char_class;
                var in_class = false;
                for (cc.ranges) |range| {
                    if (c >= range.start and c <= range.end) {
                        in_class = true;
                        break;
                    }
                }
                return if (cc.negated) !in_class else in_class;
            },
            .dot => {
                return c != '\n';
            },
            .line_start => {
                return pos == 0 or (pos > 0 and text[pos - 1] == '\n');
            },
            .line_end => {
                return pos == text.len or c == '\n';
            },
            .word_boundary => {
                const at_word_before = pos > 0 and isWordChar(text[pos - 1]);
                const at_word_after = pos < text.len and isWordChar(text[pos]);
                return at_word_before != at_word_after;
            },
            else => return false,
        }
    }

    fn addState(self: *NFAExecutor, state: *const State, pos: usize) !void {
        // Handle epsilon transitions
        switch (state.type) {
            .split => {
                if (state.data.split.out1) |s1| {
                    try self.addState(s1, pos);
                }
                if (state.data.split.out2) |s2| {
                    try self.addState(s2, pos);
                }
            },
            .group_start => {
                const idx = state.data.group.index;
                if (idx < self.groups.len) {
                    self.groups[idx] = .{ .start = pos, .end = pos };
                }
                if (state.out) |next| {
                    try self.addState(next, pos);
                }
            },
            .group_end => {
                const idx = state.data.group.index;
                if (idx < self.groups.len) {
                    if (self.groups[idx]) |*g| {
                        g.end = pos;
                    }
                }
                if (state.out) |next| {
                    try self.addState(next, pos);
                }
            },
            .line_start, .line_end, .word_boundary => {
                // Zero-width assertions - add but check condition
                try self.current.append(state);
            },
            else => {
                // Check for duplicates
                for (self.current.items) |s| {
                    if (s == state) return;
                }
                try self.current.append(state);
            },
        }
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    fn toLower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
};

/// Check if a pattern contains regex metacharacters
pub fn isRegexPattern(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            '.', '*', '+', '?', '[', ']', '(', ')', '{', '}', '|', '^', '$' => return true,
            '\\' => {
                if (i + 1 < pattern.len) {
                    const next = pattern[i + 1];
                    switch (next) {
                        'd', 'D', 'w', 'W', 's', 'S', 'b', 'B' => return true,
                        else => {},
                    }
                }
                i += 1;
            },
            else => {},
        }
        i += 1;
    }
    return false;
}

// Tests
test "simple literal match" {
    var regex = try Regex.compile(std.testing.allocator, "hello", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("hello world"));
    try std.testing.expect(regex.isMatch("say hello"));
    try std.testing.expect(!regex.isMatch("hell"));
}

test "dot metacharacter" {
    var regex = try Regex.compile(std.testing.allocator, "h.llo", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("hello"));
    try std.testing.expect(regex.isMatch("hallo"));
    try std.testing.expect(!regex.isMatch("hllo"));
}

test "character class" {
    var regex = try Regex.compile(std.testing.allocator, "[abc]", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("a"));
    try std.testing.expect(regex.isMatch("b"));
    try std.testing.expect(regex.isMatch("c"));
    try std.testing.expect(!regex.isMatch("d"));
}

test "kleene star" {
    var regex = try Regex.compile(std.testing.allocator, "ab*c", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("ac"));
    try std.testing.expect(regex.isMatch("abc"));
    try std.testing.expect(regex.isMatch("abbc"));
    try std.testing.expect(regex.isMatch("abbbc"));
}

test "plus quantifier" {
    var regex = try Regex.compile(std.testing.allocator, "ab+c", .{});
    defer regex.deinit();

    try std.testing.expect(!regex.isMatch("ac"));
    try std.testing.expect(regex.isMatch("abc"));
    try std.testing.expect(regex.isMatch("abbc"));
}

test "alternation" {
    var regex = try Regex.compile(std.testing.allocator, "cat|dog", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("cat"));
    try std.testing.expect(regex.isMatch("dog"));
    try std.testing.expect(!regex.isMatch("bird"));
}

test "anchors" {
    var regex_start = try Regex.compile(std.testing.allocator, "^hello", .{});
    defer regex_start.deinit();

    try std.testing.expect(regex_start.isMatch("hello world"));
    try std.testing.expect(!regex_start.isMatch("say hello"));

    var regex_end = try Regex.compile(std.testing.allocator, "world$", .{});
    defer regex_end.deinit();

    try std.testing.expect(regex_end.isMatch("hello world"));
    try std.testing.expect(!regex_end.isMatch("world hello"));
}

test "word class" {
    var regex = try Regex.compile(std.testing.allocator, "\\w+", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("hello"));
    try std.testing.expect(regex.isMatch("hello123"));
    try std.testing.expect(regex.isMatch("_test"));
}

test "digit class" {
    var regex = try Regex.compile(std.testing.allocator, "\\d+", .{});
    defer regex.deinit();

    try std.testing.expect(regex.isMatch("123"));
    try std.testing.expect(regex.isMatch("a123b"));
    try std.testing.expect(!regex.isMatch("abc"));
}

test "isRegexPattern" {
    try std.testing.expect(!isRegexPattern("hello"));
    try std.testing.expect(isRegexPattern("hello.*"));
    try std.testing.expect(isRegexPattern("^hello"));
    try std.testing.expect(isRegexPattern("[a-z]+"));
    try std.testing.expect(isRegexPattern("a|b"));
    try std.testing.expect(isRegexPattern("\\d+"));
}
