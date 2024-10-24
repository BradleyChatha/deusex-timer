module toolkit.scanning;

struct Match
{
    import toolkit.process : GameProcess;

    GameProcess.MemoryMap map; // This can be set by the caller if they want to keep track of the map.
    
    ulong start = ulong.max;
    ulong end   = ulong.max;

    ulong length() const
    {
        return this.end - this.start;
    }
}

// Use case: Finding initial set of matches in a block of memory.
void scanBlockForByte(
    scope const ubyte[] haystack, 
    const ubyte needle,
    scope void delegate(Match) callback,
)
{
    // We have a lot of data to sift through, so making this fast with vectorised loops is important.
    import core.simd           : byte16, loadUnaligned;
    import ldc.gccbuiltins_x86 : __builtin_ia32_pmovmskb128;

    enum BytesPerVectorisedLoop = 16;

    const haystackMod     = haystack.length % BytesPerVectorisedLoop;
    const haystackVectors = haystack.length / BytesPerVectorisedLoop;
    const haystackPtr     = haystack.ptr;
    const needleVector    = byte16(needle);

    Match currentMatch;
    
    void pushMatch()
    {
        if(currentMatch == Match.init)
            return;

        callback(currentMatch);
        currentMatch = Match.init;
    }

    void onMatch(size_t address)
    {
        if(currentMatch == Match.init)
        {
            currentMatch.start = address;
            currentMatch.end   = address + 1;
            return;
        }

        if(currentMatch.end == address)
        {
            currentMatch.end++;
            return;
        }

        pushMatch();
        onMatch(address);
    }

    foreach(i; 0..haystackVectors)
    {
        const start        = i * BytesPerVectorisedLoop;
        const vector       = loadUnaligned!byte16(cast(byte16*)(haystackPtr + start));
        const equalsVector = vector == needleVector; // Vector comparison, elements are 0xFF if equal, 0x00 if not.
        const mask         = __builtin_ia32_pmovmskb128(equalsVector); // https://www.felixcloutier.com/x86/pmovmskb

        if(mask == 0) // No bytes matched
            continue;

        if(mask == 0xFFFF) // All bytes matched - fast path
        {
            if(currentMatch == Match.init)
            {
                currentMatch.start = start;
                currentMatch.end   = start + BytesPerVectorisedLoop;
            }
            else
                currentMatch.end += BytesPerVectorisedLoop;
            continue;
        } // Could technically special case a bunch more values here, but I CBA.

        foreach(byteI, byte_; haystackPtr[start..start + BytesPerVectorisedLoop])
        {
            if(byte_ == needle)
                onMatch(start + byteI);
            else
                pushMatch();
        }
    }

    const nonSimdStart = haystack.length - haystackMod;
    foreach(i, byte_; haystackPtr[nonSimdStart..haystack.length])
    {
        if(byte_ == needle)
            onMatch(nonSimdStart + i);
        else
            pushMatch();
    }
    pushMatch();
}

unittest
{
    auto haystack = new ubyte[531];
    auto locations = [
        0, 6, 256, 511, 530
    ];
    enum target = 42;

    foreach(loc; locations)
        haystack[loc] = target;

    int matchCount = 0;
    scanBlockForByte(haystack, target, (match){
        assert(haystack[match.start] == target);
        assert(match.start == locations[matchCount]);
        assert(match.end == match.start + 1);
        matchCount++;
    });
    assert(matchCount == locations.length);
}

unittest
{
    static struct Range
    {
        size_t start;
        size_t end;
    }

    auto haystack = new ubyte[531];
    auto locations = [
        Range(0, 6), 
        Range(256, 511), 
        Range(529, 530)
    ];
    enum target = 42;

    foreach(loc; locations)
        haystack[loc.start..loc.end] = target;

    int matchCount = 0;
    scanBlockForByte(haystack, target, (match){
        // assert(haystack[match.start] == target);
        assert(match.start == locations[matchCount].start);
        assert(match.end == locations[matchCount].end);
        matchCount++;
    });
    assert(matchCount == locations.length);
}

void scanMatchesForByte(
    scope const ubyte[] haystack,
    const Match[] matches,
    const ubyte needle,
    scope void delegate(Match) callback,
)
{
    foreach(match; matches)
    {
        scanBlockForByte(haystack[match.start..match.end], needle, (Match m){
            m.map = match.map;
            m.start += match.start;
            m.end   += match.start;
            callback(m);
        });
    }
}

unittest
{
    auto haystack = new ubyte[32];
    haystack[0] = 42;
    haystack[2] = 42;
    haystack[3] = 42;
    haystack[9] = 42;
    haystack[31] = 42;

    Match[] matches;
    scanBlockForByte(haystack, 42, (match){
        matches ~= match;
    });
    assert(matches.length == 4);

    Match[] confirmedMatches;
    scanMatchesForByte(haystack, matches, 42, (match){
        confirmedMatches ~= match;
    });
    assert(confirmedMatches.length == 4);

    haystack[9] = 0;
    confirmedMatches.length = 0;
    scanMatchesForByte(haystack, matches, 42, (match){
        confirmedMatches ~= match;
    });
    assert(confirmedMatches.length == 3);

    haystack[0] = 0;
    confirmedMatches.length = 0;
    scanMatchesForByte(haystack, matches, 42, (match){
        confirmedMatches ~= match;
    });
    assert(confirmedMatches.length == 2);

    haystack[31] = 0;
    confirmedMatches.length = 0;
    scanMatchesForByte(haystack, matches, 42, (match){
        confirmedMatches ~= match;
    });
    assert(confirmedMatches.length == 1);

    haystack[2] = 0;
    confirmedMatches.length = 0;
    scanMatchesForByte(haystack, matches, 42, (match){
        confirmedMatches ~= match;
    });
    assert(confirmedMatches.length == 1);
}