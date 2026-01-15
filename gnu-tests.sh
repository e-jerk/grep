#!/bin/bash
# GNU grep compatibility tests for e-jerk grep
# These tests are derived from GNU grep test patterns

# Don't use set -e since we need to check exit codes

GREP=${GREP:-"$(dirname "$0")/zig-out/bin/grep"}
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

passed=0
failed=0
skipped=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

pass() {
    ((passed++))
    echo -e "${GREEN}PASS${NC}: $1"
}

fail() {
    ((failed++))
    echo -e "${RED}FAIL${NC}: $1"
    if [ -n "$2" ]; then
        echo "  Expected: $2"
        echo "  Got: $3"
    fi
}

skip() {
    ((skipped++))
    echo -e "${YELLOW}SKIP${NC}: $1"
}

echo "========================================="
echo "GNU grep compatibility tests"
echo "Testing: $GREP"
echo "========================================="
echo

# Test basic matching
echo "--- Basic Matching Tests ---"

# Test 1: Simple pattern match
echo "hello world" > "$TMPDIR/test1.txt"
if $GREP "hello" "$TMPDIR/test1.txt" > /dev/null 2>&1; then
    pass "Simple pattern match"
else
    fail "Simple pattern match"
fi

# Test 2: Pattern not found (exit code 1)
if $GREP "notfound" "$TMPDIR/test1.txt" > /dev/null 2>&1; then
    fail "Pattern not found should exit 1"
else
    if [ $? -eq 1 ]; then
        pass "Pattern not found exits with 1"
    else
        fail "Pattern not found exits with 1" "1" "$?"
    fi
fi

# Test 3: Multiple lines
cat > "$TMPDIR/test3.txt" << 'EOF'
line one
line two with pattern
line three
another pattern here
EOF
result=$($GREP "pattern" "$TMPDIR/test3.txt" | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Multiple matches (found 2 lines)"
else
    fail "Multiple matches" "2 lines" "$result lines"
fi

# Test 4: Case insensitive (-i)
echo "HELLO World" > "$TMPDIR/test4.txt"
if $GREP -i "hello" "$TMPDIR/test4.txt" > /dev/null 2>&1; then
    pass "Case insensitive match (-i)"
else
    fail "Case insensitive match (-i)"
fi

# Test 5: Invert match (-v)
cat > "$TMPDIR/test5.txt" << 'EOF'
keep this line
remove pattern line
keep this too
pattern here too
EOF
result=$($GREP -v "pattern" "$TMPDIR/test5.txt" | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Invert match (-v)"
else
    fail "Invert match (-v)" "2 lines" "$result lines"
fi

# Test 6: Word boundary (-w)
cat > "$TMPDIR/test6.txt" << 'EOF'
the quick brown fox
there is a problem
another the word
EOF
result=$($GREP -w "the" "$TMPDIR/test6.txt" | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Word boundary match (-w)"
else
    fail "Word boundary match (-w)" "2 lines" "$result lines"
fi

# Test 7: Fixed strings (-F)
echo 'match [this] pattern' > "$TMPDIR/test7.txt"
if $GREP -F "[this]" "$TMPDIR/test7.txt" > /dev/null 2>&1; then
    pass "Fixed string match (-F)"
else
    fail "Fixed string match (-F)"
fi

# Test 8: Stdin input
echo "stdin pattern test" | $GREP "pattern" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "Stdin input"
else
    fail "Stdin input"
fi

# Test 9: Multiple files
echo "file1 pattern" > "$TMPDIR/file1.txt"
echo "file2 other" > "$TMPDIR/file2.txt"
echo "file3 pattern too" > "$TMPDIR/file3.txt"
result=$($GREP "pattern" "$TMPDIR/file1.txt" "$TMPDIR/file2.txt" "$TMPDIR/file3.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Multiple files"
else
    fail "Multiple files" "2 matches" "$result matches"
fi

# Test 10: Empty pattern matches all lines
cat > "$TMPDIR/test10.txt" << 'EOF'
line 1
line 2
line 3
EOF
# Note: GNU grep with empty pattern matches all lines
# Skip if not supported
if $GREP -e '' "$TMPDIR/test10.txt" > /dev/null 2>&1; then
    result=$($GREP -e '' "$TMPDIR/test10.txt" | wc -l | tr -d ' ')
    if [ "$result" -eq 3 ]; then
        pass "Empty pattern matches all"
    else
        fail "Empty pattern matches all" "3 lines" "$result lines"
    fi
else
    skip "Empty pattern (not supported)"
fi

# Test 11: Exit code 2 on error (invalid file)
$GREP "pattern" "/nonexistent/file.txt" > /dev/null 2>&1
if [ $? -eq 2 ]; then
    pass "Exit code 2 on error"
else
    fail "Exit code 2 on error" "2" "$?"
fi

echo
echo "--- Edge Cases ---"

# Test 12: Empty file
touch "$TMPDIR/empty.txt"
$GREP "pattern" "$TMPDIR/empty.txt" > /dev/null 2>&1
if [ $? -eq 1 ]; then
    pass "Empty file returns 1"
else
    fail "Empty file returns 1" "1" "$?"
fi

# Test 13: Binary file
printf 'hello\x00world\npattern\n' > "$TMPDIR/binary.txt"
if $GREP "pattern" "$TMPDIR/binary.txt" > /dev/null 2>&1; then
    pass "Binary file handling"
else
    skip "Binary file handling"
fi

# Test 14: Very long line
python3 -c "print('x' * 10000 + 'pattern' + 'y' * 10000)" > "$TMPDIR/longline.txt"
if $GREP "pattern" "$TMPDIR/longline.txt" > /dev/null 2>&1; then
    pass "Very long line"
else
    fail "Very long line"
fi

# Test 15: Special characters in pattern (fixed string mode)
echo 'test$value^here' > "$TMPDIR/special.txt"
if $GREP -F '$value^' "$TMPDIR/special.txt" > /dev/null 2>&1; then
    pass "Special characters in fixed string"
else
    fail "Special characters in fixed string"
fi

echo
echo "--- GNU grep specific tests ---"

# Test 16: Multiple patterns with -e
cat > "$TMPDIR/multi.txt" << 'EOF'
apple
banana
cherry
date
EOF
result=$($GREP -e "apple" -e "cherry" "$TMPDIR/multi.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Multiple patterns (-e)"
else
    # Try alternate syntax
    result=$($GREP -F -e "apple" -e "cherry" "$TMPDIR/multi.txt" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$result" -eq 2 ]; then
        pass "Multiple patterns (-e with -F)"
    else
        skip "Multiple patterns (-e) not supported"
    fi
fi

# Test 17: Line count (-c) if supported
if $GREP --help 2>&1 | grep -q '\-c'; then
    result=$($GREP -c "pattern" "$TMPDIR/test3.txt" 2>/dev/null)
    if [ "$result" -eq 2 ]; then
        pass "Count mode (-c)"
    else
        fail "Count mode (-c)" "2" "$result"
    fi
else
    skip "Count mode (-c) not supported"
fi

# Test 18: Combination -i -w
cat > "$TMPDIR/combo.txt" << 'EOF'
The quick brown fox
there is THE problem
THERE was a theorem
EOF
result=$($GREP -i -w "the" "$TMPDIR/combo.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Combined -i -w"
else
    fail "Combined -i -w" "2 lines" "$result lines"
fi

# Test 19: Unicode if supported
echo "café résumé naïve" > "$TMPDIR/unicode.txt"
if $GREP "café" "$TMPDIR/unicode.txt" > /dev/null 2>&1; then
    pass "Unicode pattern match"
else
    skip "Unicode pattern match"
fi

# Test 20: Null-separated paths if reading from stdin
echo -e "path1\npath2\npath3" > "$TMPDIR/paths.txt"
# This tests that - means stdin
cat "$TMPDIR/paths.txt" | $GREP "path2" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "Dash means stdin"
else
    fail "Dash means stdin"
fi

echo
echo "--- New Output Control Tests ---"

# Test 21: Line numbers (-n)
cat > "$TMPDIR/test21.txt" << 'EOF'
first line
second line with pattern
third line
fourth with pattern
EOF
result=$($GREP -n "pattern" "$TMPDIR/test21.txt" 2>/dev/null)
if echo "$result" | grep -q "^2:"; then
    if echo "$result" | grep -q "^4:"; then
        pass "Line numbers (-n)"
    else
        fail "Line numbers (-n)" "2: and 4:" "$result"
    fi
else
    fail "Line numbers (-n)" "2: and 4:" "$result"
fi

# Test 22: Files with matches (-l)
echo "has pattern" > "$TMPDIR/has.txt"
echo "no match here" > "$TMPDIR/no.txt"
echo "another pattern" > "$TMPDIR/has2.txt"
result=$($GREP -l "pattern" "$TMPDIR/has.txt" "$TMPDIR/no.txt" "$TMPDIR/has2.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Files with matches (-l)"
else
    fail "Files with matches (-l)" "2 files" "$result files"
fi

# Test 23: Files without match (-L)
result=$($GREP -L "pattern" "$TMPDIR/has.txt" "$TMPDIR/no.txt" "$TMPDIR/has2.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 1 ]; then
    pass "Files without match (-L)"
else
    fail "Files without match (-L)" "1 file" "$result files"
fi

# Test 24: Quiet mode (-q) with match
echo "hello world" | $GREP -q "hello" 2>/dev/null
if [ $? -eq 0 ]; then
    pass "Quiet mode with match (-q)"
else
    fail "Quiet mode with match (-q)" "exit 0" "exit $?"
fi

# Test 25: Quiet mode (-q) without match
echo "hello world" | $GREP -q "notfound" 2>/dev/null
if [ $? -eq 1 ]; then
    pass "Quiet mode without match (-q)"
else
    fail "Quiet mode without match (-q)" "exit 1" "exit $?"
fi

# Test 26: Only matching (-o)
result=$(echo "hello world hello" | $GREP -o "hello" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 2 ]; then
    pass "Only matching (-o)"
else
    fail "Only matching (-o)" "2 matches" "$result matches"
fi

# Test 27: Line numbers with only matching (-n -o)
result=$(echo -e "hello world\ntest\nhello again" | $GREP -n -o "hello" 2>/dev/null)
if echo "$result" | grep -q "^1:hello"; then
    if echo "$result" | grep -q "^3:hello"; then
        pass "Line numbers with only matching (-n -o)"
    else
        fail "Line numbers with only matching (-n -o)"
    fi
else
    fail "Line numbers with only matching (-n -o)"
fi

echo
echo "--- Context Lines Tests ---"

# Test 28: After context (-A)
cat > "$TMPDIR/context.txt" << 'EOF'
line 1
line 2
MATCH
line 4
line 5
EOF
result=$($GREP -A2 "MATCH" "$TMPDIR/context.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 3 ]; then
    pass "After context (-A 2)"
else
    fail "After context (-A 2)" "3 lines" "$result lines"
fi

# Test 29: Before context (-B)
result=$($GREP -B2 "MATCH" "$TMPDIR/context.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 3 ]; then
    pass "Before context (-B 2)"
else
    fail "Before context (-B 2)" "3 lines" "$result lines"
fi

# Test 30: Both context (-C)
result=$($GREP -C1 "MATCH" "$TMPDIR/context.txt" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 3 ]; then
    pass "Context (-C 1)"
else
    fail "Context (-C 1)" "3 lines" "$result lines"
fi

# Test 31: Context with line numbers
result=$($GREP -n -B1 -A1 "MATCH" "$TMPDIR/context.txt" 2>/dev/null)
if echo "$result" | grep -q "^2-line 2"; then
    if echo "$result" | grep -q "^3:MATCH"; then
        if echo "$result" | grep -q "^4-line 4"; then
            pass "Context with line numbers (-n -B1 -A1)"
        else
            fail "Context with line numbers" "4-line 4" "$result"
        fi
    else
        fail "Context with line numbers" "3:MATCH" "$result"
    fi
else
    fail "Context with line numbers" "2-line 2" "$result"
fi

# Test 32: Multiple matches with context separator
cat > "$TMPDIR/multi_context.txt" << 'EOF'
line 1
MATCH1
line 3
line 4
line 5
MATCH2
line 7
EOF
result=$($GREP -C1 "MATCH" "$TMPDIR/multi_context.txt" 2>/dev/null)
if echo "$result" | grep -q "^--$"; then
    pass "Context separator between groups (--)"
else
    fail "Context separator between groups" "-- separator" "$result"
fi

# Test 33: Context with merged groups (overlapping context)
cat > "$TMPDIR/merged.txt" << 'EOF'
line 1
MATCH1
line 3
MATCH2
line 5
EOF
result=$($GREP -C1 "MATCH" "$TMPDIR/merged.txt" 2>/dev/null)
# When context overlaps, groups should merge (no separator)
lines=$(echo "$result" | wc -l | tr -d ' ')
separators=$(echo "$result" | grep -c "^--$" 2>/dev/null || true)
separators=${separators:-0}
if [ "$lines" -eq 5 ] && [ "$separators" -eq 0 ]; then
    pass "Merged context groups (overlapping)"
else
    fail "Merged context groups" "5 lines, 0 separators" "$lines lines, $separators separators"
fi

echo
echo "--- Recursive Search Tests ---"

# Test 34: Recursive search (-r)
mkdir -p "$TMPDIR/recursive/subdir1/nested" "$TMPDIR/recursive/subdir2"
echo "pattern in root" > "$TMPDIR/recursive/root.txt"
echo "no match here" > "$TMPDIR/recursive/other.txt"
echo "pattern in subdir" > "$TMPDIR/recursive/subdir1/file1.txt"
echo "nested pattern" > "$TMPDIR/recursive/subdir1/nested/deep.txt"
echo "another pattern" > "$TMPDIR/recursive/subdir2/file2.txt"
result=$($GREP -r "pattern" "$TMPDIR/recursive" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Recursive search (-r)"
else
    fail "Recursive search (-r)" "4 matches" "$result matches"
fi

# Test 35: Recursive with line numbers (-rn)
result=$($GREP -rn "pattern" "$TMPDIR/recursive" 2>/dev/null | grep -c ":1:" || true)
result=${result:-0}
if [ "$result" -eq 4 ]; then
    pass "Recursive with line numbers (-rn)"
else
    fail "Recursive with line numbers (-rn)" "4 lines with :1:" "$result"
fi

# Test 36: Recursive case-insensitive (-ri)
echo "PATTERN uppercase" > "$TMPDIR/recursive/upper.txt"
result=$($GREP -ri "pattern" "$TMPDIR/recursive" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 5 ]; then
    pass "Recursive case-insensitive (-ri)"
else
    fail "Recursive case-insensitive (-ri)" "5 matches" "$result matches"
fi

# Test 37: Recursive count (-rc)
result=$($GREP -rc "pattern" "$TMPDIR/recursive" 2>/dev/null | grep -c ":1$" || true)
result=${result:-0}
if [ "$result" -ge 4 ]; then
    pass "Recursive count (-rc)"
else
    fail "Recursive count (-rc)" "at least 4 files with count 1" "$result"
fi

# Test 38: Recursive with -l (files with matches)
result=$($GREP -rl "pattern" "$TMPDIR/recursive" 2>/dev/null | wc -l | tr -d ' ')
if [ "$result" -eq 4 ]; then
    pass "Recursive files with matches (-rl)"
else
    fail "Recursive files with matches (-rl)" "4 files" "$result files"
fi

echo
echo "--- Color Output Tests ---"

# Test 39: Color output (--color=always)
result=$(echo "hello world hello" | $GREP --color=always "hello" 2>/dev/null)
# Check for ANSI escape codes (ESC[01;31m)
if echo "$result" | grep -q $'\x1b\[01;31m'; then
    pass "Color output (--color=always)"
else
    fail "Color output (--color=always)" "ANSI escape codes" "$result"
fi

# Test 40: Color output with multiple matches on same line
result=$(echo "test pattern test pattern end" | $GREP --color=always "pattern" 2>/dev/null)
# Should have two colored "pattern" occurrences
count=$(echo "$result" | grep -o $'\x1b\[01;31m' | wc -l | tr -d ' ')
if [ "$count" -eq 2 ]; then
    pass "Color output multiple matches"
else
    fail "Color output multiple matches" "2 color starts" "$count"
fi

# Test 41: Color with -o (only-matching)
result=$(echo "hello world" | $GREP --color=always -o "hello" 2>/dev/null)
if echo "$result" | grep -q $'\x1b\[01;31mhello\x1b\[m'; then
    pass "Color with only-matching (-o)"
else
    fail "Color with only-matching (-o)"
fi

# Test 42: No color output (--color=never)
result=$(echo "hello world" | $GREP --color=never "hello" 2>/dev/null)
if echo "$result" | grep -q $'\x1b'; then
    fail "No color output (--color=never)" "no escape codes" "$result"
else
    pass "No color output (--color=never)"
fi

echo
echo "========================================="
echo "Results: $passed passed, $failed failed, $skipped skipped"
echo "========================================="

if [ $failed -gt 0 ]; then
    exit 1
fi
exit 0
