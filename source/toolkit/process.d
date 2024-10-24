module toolkit.process;

import core.sys.posix.sys.uio : iovec;
extern(C) ptrdiff_t process_vm_readv(int pid, iovec* local, size_t len, iovec* remote, size_t rlen, ulong flags);

enum PTRACE_ATTACH = 16;
enum PTRACE_DETACH = 17;
enum PTRACE_POKEDATA = 5;
extern(C) long ptrace(int op, int pid, void *addr, void *data);

class GameProcess
{
    static struct MemoryMap
    {
        ulong start;
        ulong end;
        bool readable;
        bool writable;
        bool executable;
        bool private_;
        ulong offset;
        uint major;
        uint minor;
        uint inode;
        string pathname;
    }

    private
    {
        int _pid;
        bool _attached;
        MemoryMap[] _maps;

        this(int pid)
        {
            this._pid = pid;
            this.attach();
        }
    }

    ~this()
    {
        if(this._pid != 0 && this._attached)
            this.detach();
    }

    static GameProcess fromPid(int pid)
    {
        return new GameProcess(pid);
    }

    static GameProcess fromProcess(RunningProcess process)
    {
        return new GameProcess(process.pid);
    }

    void attach()
    in(!this._attached, "Already attached")
    {
        const result = ptrace(PTRACE_ATTACH, pid, null, null);
        if(result == -1)
        {
            import core.stdc.errno : errno;
            import std.string : fromStringz;
            import core.sys.posix.string : strerror;
            throw new Exception("Failed to attach to process: " ~ strerror(errno).fromStringz.idup);
        }

        this._attached = true;
    }

    void detach()
    in(this._attached, "Not attached")
    {
        const result = ptrace(PTRACE_DETACH, pid, null, null);
        if(result == -1)
        {
            import core.stdc.errno : errno;
            import std.string : fromStringz;
            import core.sys.posix.string : strerror;
            throw new Exception("Failed to detach from process: " ~ strerror(errno).fromStringz.idup);
        }

        this._attached = false;
    }

    void pause()
    {
        import core.sys.posix.signal : kill, SIGSTOP;
        kill(this._pid, SIGSTOP);
    }

    void resume()
    {
        import core.sys.posix.signal : kill, SIGCONT;
        kill(this._pid, SIGCONT);
    }

    void refreshMaps()
    {
        import std.conv   : to;
        import std.file   : readText;
        import std.string : lineSplitter;
        import std.regex  : regex, matchFirst;

        MemoryMap[] mappings;
        const reg = regex(r"([0-9a-f]+)-([0-9a-f]+)\s+([-r][-w][-x][-p])\s+([0-9a-f]+)\s+([0-9a-f]+):([0-9a-f]+)\s([0-9]+)\s+(.*)"); // @suppress(dscanner.style.long_line)

        foreach(line; readText("/proc/" ~ this._pid.to!string ~ "/maps").lineSplitter)
        {
            const captures = line.matchFirst(reg);
            if(!captures)
                continue;

            mappings ~= MemoryMap(
                captures[1].to!ulong(16),
                captures[2].to!ulong(16),
                captures[3][0] == 'r',
                captures[3][1] == 'w',
                captures[3][2] == 'x',
                captures[3][3] == 'p',
                captures[4].to!ulong(16),
                captures[5].to!uint(16),
                captures[6].to!uint(16),
                captures[7].to!uint,
                captures[8]
            );
        }

        this._maps = mappings;
    }

    void accessMemory(MemoryMap map, void delegate(scope const ubyte[]) callback)
    {
        import core.memory : GC;

        auto buffer = (cast(ubyte*)GC.malloc(map.end - map.start, 0, typeid(ubyte)))[0..map.end - map.start];
        scope(exit) GC.free(buffer.ptr);

        iovec local;
        local.iov_base = buffer.ptr;
        local.iov_len = buffer.length;

        iovec remote;
        remote.iov_base = cast(void*)map.start;
        remote.iov_len = buffer.length;

        const result = process_vm_readv(this._pid, &local, 1, &remote, 1, 0);
        if(result == -1)
        {
            import core.stdc.errno : errno;
            import std.string : fromStringz;
            import core.sys.posix.string : strerror;
            throw new Exception("Failed to read memory: " ~ strerror(errno).fromStringz.idup);
        }

        callback(buffer);
    }

    bool mapStillExists(MemoryMap map)
    {
        import std.algorithm : any;
        return this._maps.any!(m => m.start == map.start && m.end == map.end);
    }

    MemoryMap[] memoryMaps()
    {
        return this._maps;
    }

    int pid()
    {
        return this._pid;
    }
}

struct RunningProcess
{
    int pid;

    // Values directly corresponding to the same named files in /proc/<pid>/
    string cmdline;
    string comm;

    static RunningProcess[] listAll()
    {
        import std.algorithm : all, filter, map;
        import std.array     : array;
        import std.conv      : to;
        import std.file      : dirEntries, SpanMode, readText;
        import std.path      : baseName;
        import std.string    : chomp;
        import std.uni       : isNumber;

        return dirEntries("/proc", SpanMode.shallow)
            .filter!(de => de.baseName.all!isNumber)
            .map!((de) {
                RunningProcess process;
                process.pid     = de.baseName.to!int;
                process.cmdline = readText(de.name ~ "/cmdline").chomp;
                process.comm    = readText(de.name ~ "/comm").chomp;

                return process;
            })
            .array;
    }

    string command()
    {
        return this.cmdline.length ? this.cmdline : this.comm;
    }
}