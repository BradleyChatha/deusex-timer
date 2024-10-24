import toolkit.process, toolkit.finders, toolkit.patcher;

version(linux){}
else static assert(false, "Only Linux is supported.");

version(X86_64) {}
else static assert(false, "Only amd64 machines are supported.");

int main()
{
    GameProcess deusex;
    Patcher enginePatcher;
    size_t flagsAddress;

    findDeusEx(/*out*/ deusex, /*out*/ enginePatcher);
    scope(failure) deusex.detach(); // The dtor doesn't always run, so on failure make sure we always detach.

    patchFlagSettersIntoLoadMap(deusex, enginePatcher, /*out*/ flagsAddress);
    deusex.detach(); // PTRACE_ATTACH forces the program to pause, so this is just to unpause it. We don't need it to modify memory anymore.

    bool before = false;
    while(true)
    {
        // Temp loop just to double check it actually works.
        import core.sys.posix.sys.uio : iovec;
        import toolkit.process : process_vm_readv;

        bool current;

        iovec local;
        local.iov_base = cast(void*)&current;
        local.iov_len = 1;

        iovec remote;
        remote.iov_base = cast(void*)flagsAddress;
        remote.iov_len = 1;

        process_vm_readv(deusex.pid, &local, 1, &remote, 1, 0);

        if(before != current)
        {
            import std.stdio : writeln;
            writeln(current); // dear christ it's working.
            before = current;
        }

        // The amount of effort to get to this point :joy: - Actual timer coming soon.
    }

    return 0;
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
           the flag to 0, and replace the old instructions with a jump to this extended prologue.

    Read the function comments for specifics.

    I should note that I could've hardcoded a lot of addresses and made things much easier on myself, but
    I kinda wanted to do it "semi-properly" for funsies.
+/
void patchFlagSettersIntoLoadMap(GameProcess deusex, Patcher enginePatcher, out size_t flagsAddress)
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
    // It's very unlikely the last byte of the last mapping is in actual use, so we can use it to store our own flags.
    const mapToStoreFlags = deusex.memoryMaps
                            .filter!(m => m.pathname.canFind("Engine.dll") && m.writable)
                            .array[$-1];
    deusex.accessMemory(mapToStoreFlags, (scope memory){ enforce(memory[$-1] == 0, "Last byte is in use :("); });
    flagsAddress = mapToStoreFlags.end - 1;
    writefln("Storing flag byte at 0x%08X", flagsAddress);

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
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions, unsetFlagInstructions);
    enginePatcher.poke8Bytes(loadMapSig, endOfLoadMapInstructions+8, [
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