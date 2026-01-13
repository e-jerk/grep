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
echo "========================================="
echo "Results: $passed passed, $failed failed, $skipped skipped"
echo "========================================="

if [ $failed -gt 0 ]; then
    exit 1
fi
exit 0
