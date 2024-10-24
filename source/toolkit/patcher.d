module toolkit.patcher;

import std.typecons : Nullable;

import toolkit.process;

import core.sys.posix.sys.uio : iovec;
extern(C) ptrdiff_t process_vm_writev(int pid, iovec* local, size_t len, iovec* remote, size_t rlen, ulong flags);

class Patcher
{
    alias MapSelector = bool delegate(const GameProcess.MemoryMap);
    alias DetourHook  = extern(C) void function() @nogc nothrow;

    static struct FunctionEstimate
    {
        GameProcess.MemoryMap map;
        size_t offset;
        size_t estimatedSize;
    }

    private
    {
        GameProcess _process;
        MapSelector _mapSelector;
    }

    this(GameProcess process, MapSelector selector)
    {
        this._process = process;
        this._mapSelector = selector;
    }

    Nullable!FunctionEstimate signatureScan(
        int[] bytes,
        size_t delegate(scope const ubyte[] memoryStartingFromSignature) sizeEstimator,
    )
    {
        this._process.refreshMaps();
        foreach(map; this._process.memoryMaps)
        {
            if(!this._mapSelector(map))
                continue;

            Nullable!FunctionEstimate result;
            this._process.accessMemory(map, (scope memory){
                if(bytes.length < bytes.length)
                    return;
                
                size_t byteIndex;
                Failed: while(byteIndex < memory.length - bytes.length)
                {
                    const offset = byteIndex;
                    foreach(i, check; bytes)
                    {
                        if(bytes[i] >= 0 && bytes[i] <= 0xFF)
                        {
                            if(memory[offset + i] != bytes[i])
                            {
                                byteIndex++;
                                goto Failed;
                            }
                        }
                    }

                    result = FunctionEstimate(map, offset, sizeEstimator(memory[offset..$]));
                    return;
                }
            });

            if(!result.isNull)
                return result;
        }

        return typeof(return).init;
    }

    void poke8Bytes(FunctionEstimate func, ptrdiff_t offset, ubyte[8] bytes)
    {
        const result = ptrace(PTRACE_POKEDATA, this._process.pid, cast(void*)(func.map.start + func.offset + offset), cast(void*)(*(cast(size_t*)bytes.ptr))); // @suppress(dscanner.style.long_line)
        if(result == -1)
        {
            import core.stdc.errno : errno;
            import std.string : fromStringz;
            import core.sys.posix.string : strerror;
            throw new Exception("Failed to poke memory: " ~ strerror(errno).fromStringz.idup);
        }
    }
}