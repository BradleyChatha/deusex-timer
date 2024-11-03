import toolkit.process, toolkit.finders, toolkit.patcher, toolkit.ui;

version(linux){}
else static assert(false, "Only Linux is supported.");

version(X86_64) {}
else static assert(false, "Only amd64 machines are supported.");

struct FStringNoCap
{
    uint ptr;
    uint length;
}

int main()
{
    import core.time : dur;

    GameProcess deusex;
    Patcher enginePatcher;
    size_t flagsAddress;
    size_t lastLoadedMapAddress;

    findDeusEx(/*out*/ deusex, /*out*/ enginePatcher);

    try patchFlagSettersIntoLoadMap(deusex, enginePatcher, /*out*/ flagsAddress, /*out*/ lastLoadedMapAddress);
    finally deusex.detach(); // PTRACE_ATTACH forces the program to pause, so this is just to unpause it. We don't need it to modify memory anymore.

    auto timer = new Timer();
    auto mapLabel = new Label("", Ansi.blue);
    auto controller = new UpdateOnlyComponent(deusExController(
        timer, 
        mapLabel,
        deusex, 
        flagsAddress, 
        lastLoadedMapAddress,
    ));

    auto ui = new UiLoop();
    ui.addComponent(controller);
    ui.addComponent(timer);
    ui.addComponent(mapLabel);
    ui.addComponent(new Label("Note: End-of-game detection \n        not implemented yet."));
    ui.loop(dur!"msecs"(8)); // Try to be 2x faster than the game to minimise amount of extra time added to the timer.

    return 0;
}

auto deusExController(
    Timer timer, 
    Label mapLabel,
    GameProcess deusex, 
    size_t flagsAddress,
    size_t lastLoadedMapAddress,
)
{
    import core.time : Duration;

    enum State
    {
        waitingForFirstLoad,
        normal,
    }
    State state;
    bool wasLoadingLastTick;
    string lastLoadedMap;

    return delegate (Duration _){
        // process_vm_readv sometimes fails with ESRCH and I have no idea why, so ignore any errors for now.
        bool isLoading = false;
        try isLoading = deusex.peek!bool(flagsAddress);
        catch(Exception) return;
        
        scope(exit) wasLoadingLastTick = isLoading;
        
        final switch(state) with(State)
        {
            case waitingForFirstLoad:
                if(isLoading)
                    state = normal;
                break;

            case normal:
                if(!isLoading)
                {
                    timer.resume();

                    if(wasLoadingLastTick)
                    {
                        FStringNoCap lastLoadedMapPtr;
                        while(true)
                        {
                            try lastLoadedMapPtr = deusex.peek!FStringNoCap(lastLoadedMapAddress);
                            catch(Exception) continue;
                            break;
                        }

                        if(lastLoadedMapPtr.ptr > 0)
                        {
                            lastLoadedMap = toDString(deusex, lastLoadedMapPtr);
                            mapLabel.text = lastLoadedMap;
                        }
                    }
                }
                else
                    timer.pause();
                break;
        }
    };
}

string toDString(GameProcess deusex, FStringNoCap source)
{
    import std.algorithm : filter, all;
    import std.exception : assumeUnique;

    const sourceMap = deusex.memoryMaps
                        .filter!(m => source.ptr >= m.start && source.ptr <= m.end)
                        .front;

    auto result = new char[source.length];
    bool tryAgain = true;
    int attempts;

    while(tryAgain)
    {
        if(attempts++ >= int.max)
            return "Failed (process_vm_readv bug?)";

        tryAgain = false;
        deusex.accessMemory(sourceMap, (scope memory){
            // Characters are in some two-byte format, so we just need to take the first byte of each pair.
            const relativePtr = source.ptr - sourceMap.start;
            foreach(i; 0..source.length)
            {
                // Sometimes we get junk memory back... and I'm not sure why since all the numbers are correct.
                // So just keep trying again if it happens lol.
                const ch = memory[relativePtr + (2 * i)];
                switch(ch)
                {
                    case 'a': .. case 'z': break;
                    case 'A': .. case 'Z': break;
                    case '0': .. case '9': break;
                    
                    case ' ':
                    case '.':
                    case '_':
                    case '\\':
                        break;

                    case '\0':
                        if(i == source.length-1) // @suppress(dscanner.suspicious.length_subtraction)
                            break;
                        goto default;

                    default:
                        import std.stdio : writeln;
                        writeln(
                            "bad char: ", cast(char)ch, " ", cast(int)ch, 
                            " @ ", relativePtr, " + ", 2 * i, " = ", relativePtr + (2 * i), 
                            " | ", source, " ", sourceMap.start
                        );
                        tryAgain = true;
                        break;
                }

                result[i] = ch;
            }
        });
    }

    if(result.length && result[$-1] == 0)
        result = result[0..$-1];
    return result.assumeUnique;
}

void findDeusEx(out GameProcess deusex, out Patcher enginePatcher)
{
    import std.algorithm : filter;
    import std.range     : takeExactly;

    auto process = RunningProcess
                    .listAll()
                    .filter!(p => p.comm == "deusex.exe" || p.comm == "DeusEx.exe")
                    .takeExactly(1)
                    .front;

    deusex = GameProcess.fromProcess(process);
    enginePatcher = new Patcher(deusex, (map){
        import std.algorithm : endsWith;
        return map.pathname.endsWith("Engine.dll");
    });
}

/+
    What an absolute pain this was - I tried so hard to find an in-memory flag, since according to the
    UScript there should be a byte somewhere in memory where: 1 == LOADING, 2 == SAVING, but I just couldn't find it.
    
    So instead we have to live patch the LoadMap function to set a byte at an already known address instead.
    
    Fortunately symbol names are in tact, so the following steps were performed to find where LoadMap existed:
        * Dump export tables: llvm-readobj --coff-exports Engine.dll > /tmp/symbols.log
        
        * Disassemble Engine.dll: objdump -d Engine.dll > /tmp/dump.txt
        
        * Grep for LoadMap in the symbols dump, and lookup the RVA within the instruction dump.
        
        * It should land directly on an entry of a jump table. The address being jumped to being the LoadMap function.

    At a high level the patch process is:
        1. Add an instruction at the start of LoadMap to set our flag to 1, and update the jump table to
           start from this instruction instead.

        2. Move some of the ending instructions into unused memory, and prefix it with an instruction to set
           the flag to 0, and replace the old instructions with a jump to this extended epilog.

            2.1. Also includes instructions to fetch the loaded map name, and store it to a well known location.

    Read the function comments for specifics.

    I should note that I could've hardcoded a lot of addresses and made things much easier on myself, but
    I kinda wanted to do it "semi-properly" for funsies.
+/
void patchFlagSettersIntoLoadMap(
    GameProcess deusex, 
    Patcher enginePatcher, 
    out size_t flagsAddress,
    out size_t lastLoadedMapAddress,
)
{
    import std.algorithm : filter, canFind;
    import std.array     : array;
    import std.exception : enforce;
    import std.stdio     : writefln;
    
    /++ Find the LoadMap function, as well as its entry in the jump table. ++/
    auto loadMapSig = enginePatcher.signatureScan([
        0x55,                           // push ebp
        0x8B, 0xEC,                     // mov ebp, esp
        0x6A, 0xFF,                     // push 0xFFFFFFFF
        0x68, 0xBB, 0xFF, 0x41, 0x10    // push 0x1041ffbb
    ], (scope memoryAfterSig){ 
        const target = [0xC2, 0x10, 0x00]; // ret 0x10
        foreach(i, _; memoryAfterSig)
        {
            if(i >= memoryAfterSig.length - target.length) // @suppress(dscanner.suspicious.length_subtraction)
                throw new Exception("Could not find return instruction?");

            if(memoryAfterSig[i..i+target.length] == target)
                return i;
        }

        assert(false);
    }).get;
    writefln(
        "Found LoadMap at 0x%08X - ret is at 0x%08X (incorrect if already patched)",
        loadMapSig.map.start + loadMapSig.offset,
        loadMapSig.map.start + loadMapSig.offset + loadMapSig.estimatedSize,
    );

    auto loadMapJumpSigResult = enginePatcher.signatureScan([
        0xE9, 0x46, 0x8e, 0x08, 0x00 // jmp [rel LoadMap] -- Hopefully it doesn't magically change because I cba to calculate the relative address.
    ], (scope memoryAfterSig){ return 0; });

    // Engine.dll creates at least 2 writeable mappings.
    // It's very unlikely the last bytes of the last mapping are in actual use, so we can use it to store our own values.
    const mapToStoreFlags = deusex.memoryMaps
                            .filter!(m => m.pathname.canFind("Engine.dll") && m.writable)
                            .array[$-1];
    deusex.accessMemory(mapToStoreFlags, (scope memory){ 
        const flagBytes = 1;
        const loadedMapPtrBytes = 8;
        const totalBytes = flagBytes + loadedMapPtrBytes;
        // foreach(i; 0..totalBytes)
        //     enforce(memory[$-(1+i)] == 0, "Last byte is in use :("); 
    });
    flagsAddress = mapToStoreFlags.end - 1;
    lastLoadedMapAddress = mapToStoreFlags.end - 9;
    writefln("Storing flag byte at 0x%08X", flagsAddress);
    writefln("Storing last loaded map pointer at 0x%08X", lastLoadedMapAddress);

    if(loadMapJumpSigResult.isNull) // If we can't find it, assume we've already patched the process... could probably make it better, but meh.
    {
        import std.stdio : writeln;
        writeln("Could not find expected jump table entry, assuming process has already been patched.");
        return;
    }
    const loadMapJumpSig = loadMapJumpSigResult.get;
    writefln("Found LoadMap jump table entry at 0x%08X", loadMapJumpSig.map.start + loadMapJumpSig.offset);

    /++ 
        Functions in Engine.dll start and end with a guard of nops & int3s.

        This *very* thankfully provides an easy place for us to inject code to set a "loading" flag
        just before the actual LoadMap function. Unsetting is a little harder though.

        We can then modify the jump table to execute from our new starting instruction instead.
    ++/
    enginePatcher.poke8Bytes(loadMapSig, -8, [
        // mov byte [FlagsAddress], 1
        0xC6, 0x05, 
        cast(ubyte)(flagsAddress & 0xFF), 
        cast(ubyte)((flagsAddress & 0xFF00) >> (8 * 1)), 
        cast(ubyte)((flagsAddress & 0xFF0000) >> (8 * 2)), 
        cast(ubyte)((flagsAddress & 0xFF000000) >> (8 * 3)), 
        0x01,

        0x90, // nop
    ]);

    ubyte[8] jumpInstructions;
    deusex.accessMemory(loadMapJumpSig.map, (scope memory){
        jumpInstructions = memory[loadMapJumpSig.offset..loadMapJumpSig.offset+8];
    });
    jumpInstructions[1] -= 8;
    enginePatcher.poke8Bytes(loadMapJumpSig, 0, jumpInstructions);
    printHex("Jump table patched with: ", jumpInstructions[]);

    /++
        Unsetting the flag is a little more complex as there's instructions after
        the main (or at least appears to be the main) ret instruction, so we need
        to move the ret instruction (3 bytes) as well as the previous pop and mov instructions (3 bytes)
        somewhere else, and replace it with a relative jmp instruction (5 bytes) where we can add a bit
        of our own code alongside it.

        Fortunately there's a massive amount of nops & int3s near the end, so we can just stuff everything there.

        I just hope those other rets are error cases. I couldn't actually see what jumps into those branches though.

        Additionally, LoadMap returns a ULevel which appears to store the map's name at offset 0x60.
        This string type appears to be very standard: pointer + size + capacity.
        
        The characters are stored in two bytes (UTF-16?). At the very least the first byte is ASCII compatible,
        and the second is always 0 for these ASCII characters, so it's easy to handle still.

        So we can also inject some code to store the pointer to the loaded map name for us, which we can later
        read to do things like auto splits!
    ++/
    const retOffset = loadMapSig.offset + loadMapSig.estimatedSize;
    const retPopAndMovOffset = retOffset - 3;
    size_t endOfLoadMapInstructions = retPopAndMovOffset;
    ubyte[8] retPopAndMovInstructions; // The first 6 are the instructions we're overwriting, the rest we need for poke8Bytes so they stay in tact.

    deusex.accessMemory(loadMapSig.map, (scope memory){
        retPopAndMovInstructions = memory[retPopAndMovOffset..retPopAndMovOffset+8];

        const target = [0x90, 0x90, 0x90, 0x90]; // nop nop nop nop
        while(endOfLoadMapInstructions < memory.length - target.length)
        {
            if(memory[endOfLoadMapInstructions..endOfLoadMapInstructions+target.length] == target)
                return;
            endOfLoadMapInstructions++;
        }

        throw new Exception("Could not find end of LoadMap?");
    });
    printHex("retPopAndMovInstructions: ", retPopAndMovInstructions[]);

    const ubyte[8] unsetFlagInstructions = [
        // mov byte [FlagsAddress], 0
        0xC6, 0x05, 
        cast(ubyte)(flagsAddress & 0xFF), 
        cast(ubyte)((flagsAddress & 0xFF00) >> (8 * 1)), 
        cast(ubyte)((flagsAddress & 0xFF0000) >> (8 * 2)), 
        cast(ubyte)((flagsAddress & 0xFF000000) >> (8 * 3)), 
        0x00,

        0x90, // nop
    ];
    printHex("unsetFlagInstructions: ", unsetFlagInstructions[]);

    const ubyte[8][3] stashMapNameInstructions = [
        [
            // eax (used as the return register) contains a ULevel. ULevel + 0x60 is a string type, 
            // where the first four bytes is a pointer to the raw string data. This string is the level name.
            0x8B, 0x48, 0x60, // rest of: mov dword ecx, [eax + 0x60]

            // mov [LastLoadedMapPtr], ecx
            0x89, 0x0D,
            cast(ubyte)(lastLoadedMapAddress & 0xFF), 
            cast(ubyte)((lastLoadedMapAddress & 0xFF00) >> (8 * 1)), 
            cast(ubyte)((lastLoadedMapAddress & 0xFF0000) >> (8 * 2)), 
        ],
        [
            // Last byte of the previous instruction
            cast(ubyte)((lastLoadedMapAddress & 0xFF000000) >> (8 * 3)), 
            
            // We also need to stash the length so we know exactly how much memory to read, otherwise
            // we'd have to write a (potentially) slooow loop.
            0x8B, 0x48, 0x64, // mov dword ecx, [eax + 0x64]

            // mov [LastLoadedMapLength], ecx
            0x89, 0x0D, 
            cast(ubyte)((lastLoadedMapAddress + 4) & 0xFF), 
            cast(ubyte)(((lastLoadedMapAddress + 4) & 0xFF00) >> (8 * 1)), 
        ],
        [
            // Last two bytes of the previous instruction
            cast(ubyte)(((lastLoadedMapAddress + 4) & 0xFF0000) >> (8 * 2)), 
            cast(ubyte)(((lastLoadedMapAddress + 4) & 0xFF000000) >> (8 * 3)), 

            // nops
            0x90,0x90,0x90,0x90,0x90,0x90,
        ]
    ];
    printHex("stashMapNameInstructions[0]: ", stashMapNameInstructions[0][]);
    printHex("stashMapNameInstructions[1]: ", stashMapNameInstructions[1][]);
    printHex("stashMapNameInstructions[2]: ", stashMapNameInstructions[2][]);

    const relativeJumpOffset = (endOfLoadMapInstructions - retOffset) - 2; // Reminder: relative jmps occur after the IP is updated, so we have to remove the extra bytes that are read as part of the jmp instruction.
    ubyte[8] jumpMiniDetourInstructions = [
        // jmp [rel NewEndOfLoadMap]
        0xE9, 
        cast(ubyte)(relativeJumpOffset & 0xFF), 
        cast(ubyte)((relativeJumpOffset & 0xFF00) >> (8 * 1)), 
        cast(ubyte)((relativeJumpOffset & 0xFF0000) >> (8 * 2)), 
        cast(ubyte)((relativeJumpOffset & 0xFF000000) >> (8 * 3)),
        0x90, // nop
        
        // Preserve existing instructions.
        retPopAndMovInstructions[6],
        retPopAndMovInstructions[7],
    ];
    printHex("jumpMiniDetourInstructions: ", jumpMiniDetourInstructions[]);

    endOfLoadMapInstructions -= loadMapSig.offset; // Make it relative to the start of the function, rather than start of the map.
    writefln("injected ending: 0x%08X", loadMapSig.map.start + loadMapSig.offset + endOfLoadMapInstructions);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions, unsetFlagInstructions);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions+8, stashMapNameInstructions[0]);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions+16, stashMapNameInstructions[1]);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions+24, stashMapNameInstructions[2]);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions+32, [
        retPopAndMovInstructions[0],
        retPopAndMovInstructions[1],
        retPopAndMovInstructions[2],
        retPopAndMovInstructions[3],
        retPopAndMovInstructions[4],
        retPopAndMovInstructions[5],
        0x90, 0x90 // nop nop
    ]);
    enginePatcher.poke8Bytes(loadMapSig, retPopAndMovOffset - loadMapSig.offset, jumpMiniDetourInstructions);
}

void printHex(string context, const scope ubyte[] bytes)
{
    import std.stdio : writef;
    writef("%s", context);
    foreach(b; bytes)
        writef("%02X ", b);
    writef("\n");
}