module quickbite;

void runTests(string source) {
    import std.conv: to;
    import std.regex: matchFirst, regex;

    const functionPattern = regex(
        `int\s+([A-Za-z_]\w*)\s*\(\s*\)\s*\{\s*return\s+(-?\d+)\s*;\s*\}`,
        "s"
    );
    const unittestPattern = regex(
        `unittest\s*\{\s*assert\s*\(\s*([A-Za-z_]\w*)\s*\(\s*\)\s*==\s*(-?\d+)\s*\)\s*;\s*\}`,
        "s"
    );

    auto functionMatch = matchFirst(source, functionPattern);
    if (functionMatch.empty) {
        throw new Exception(
            "Unsupported source: expected an int function returning a literal."
        );
    }

    auto unittestMatch = matchFirst(source, unittestPattern);
    if (unittestMatch.empty) {
        throw new Exception(
            "Unsupported source: expected a unittest asserting a zero-arg call."
        );
    }

    const functionName = functionMatch.captures[1];
    const returnValue = functionMatch.captures[2].to!int;
    const assertedFunctionName = unittestMatch.captures[1];
    const assertedValue = unittestMatch.captures[2].to!int;

    if (functionName != assertedFunctionName) {
        throw new Exception(
            "Unittest calls a different function than the declared one."
        );
    }

    if (returnValue != assertedValue) {
        throw new Exception("Unittest assertion failed.");
    }
}
