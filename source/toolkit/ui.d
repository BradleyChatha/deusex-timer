module toolkit.ui;

import std.typecons : Flag;
import core.time : Duration;

abstract class Ansi
{
    static const red        = "\x1b[31m";
    static const green      = "\x1b[32m";
    static const yellow     = "\x1b[33m";
    static const blue       = "\x1b[34m";
    static const white      = "\x1b[37m";
    static const hiBlack    = "\x1b[90m";
    static const hiWhite    = "\x1b[97m";

    static const bgBlack    = "\x1b[40m";
    static const bgRed      = "\x1b[41m";
    static const bgGreen    = "\x1b[42m";
    static const bgYellow   = "\x1b[43m";
    static const bgHiBlack  = "\x1b[100m";

    static const bold       = "\x1b[1m";
    static const reset      = "\x1b[0m";
    static const clear      = "\x1b[2J\x1b[H";
}

// More for code organisation than a proper, robust UI system - hence why there's barely any common configurable options.
interface UiComponent
{
    void draw();
    void update(Duration delta);
}

class UiLoop
{
    private
    {
        static bool _looping; // Must be static for easy access from signal handler.
        
        UiComponent[] _components;
    }

    void addComponent(UiComponent component)
    {
        this._components ~= component;
    }

    private static extern(C) void onSigInt(int _) @nogc nothrow
    {
        import core.atomic : atomicStore;
        atomicStore(this._looping, false);
    }

    void loop(const Duration targetLoopTime)
    {
        import std.datetime          : Clock;
        import std.stdio             : writeln, writefln;
        import core.atomic           : atomicStore, atomicLoad;
        import core.thread           : Thread;
        import core.sys.posix.signal : signal, SIGINT;
        
        atomicStore(UiLoop._looping, true);
        signal(SIGINT, &onSigInt);

        auto lastFrameTime = Clock.currTime();
        while(atomicLoad(UiLoop._looping))
        {
            const startTime = Clock.currTime();
            const delta = startTime - lastFrameTime;

            writeln(Ansi.clear);
            foreach(component; this._components)
            {
                component.update(delta);
                component.draw();
            }

            const loopTime = Clock.currTime() - startTime;
            writefln("target: %s | taken: %s", targetLoopTime, loopTime);
            if(loopTime < targetLoopTime)
                Thread.sleep(targetLoopTime - loopTime);
            lastFrameTime = startTime;
        }
    }
}

class UpdateOnlyComponent : UiComponent
{
    private void delegate(Duration) _func;

    this(typeof(_func) func)
    {
        this._func = func;
    }

    override void update(Duration delta)
    {
        this._func(delta);
    }

    override void draw() {}
}

class Label : UiComponent
{
    string text;
    string colour;

    this(string text, string colour = Ansi.hiBlack)
    {
        this.text = text;
        this.colour = colour;
    }

    override void draw()
    {
        import std.stdio : writefln;
        if(this.text.length != 0)
            writefln("  %s%s%s", this.colour, this.text, Ansi.reset);
    }

    override void update(Duration _){}
}

class Timer : UiComponent
{
    private
    {
        enum State
        {
            waitingForFirstLoad,
            paused,
            running,
        }
        
        Duration _rtaElapsed;
        Duration _elapsed;
        State _state;
        bool _skipNext;
    }

    void pause() { this._state = State.paused;  }
    void resume() 
    {
        if(this._state == State.running)
            return;
        this._state = State.running; 
        this._skipNext = true; 
    }

    Duration elapsed() const => this._elapsed;

    override void update(Duration delta)
    {
        final switch(this._state) with(State)
        {
            case waitingForFirstLoad:
                break;

            case paused:
                this._rtaElapsed += delta;
                break;

            case running:
                this._rtaElapsed += delta;
                if(!this._skipNext)
                    this._elapsed += delta;
                this._skipNext = false;
                break;
        }
    }

    override void draw() 
    {
        import std.stdio : writefln;

        void drawDuration(string tag, Duration elapsed)
        {
            const colour  = this._state == State.running ? Ansi.green : Ansi.yellow;
            writefln("  [%s] %s%s%s", tag, colour, formatDuration(elapsed), Ansi.reset);
        }

        final switch(this._state) with(State)
        {
            case waitingForFirstLoad:
                writefln("  [T] Waiting for first load...");
                break;

            case paused:
            case running:
                drawDuration("LRT", this._elapsed);
                drawDuration("RTA", this._rtaElapsed);
                break;
        }
    }
}

class SplitList : UiComponent
{
    import std.json : JSONValue;

    static struct Split
    {
        string id;
        string name;
        Duration startTime;
        Duration endTime;

        string version_ = "1"; // In case I ever want to change the JSON format in the future, but still load old splits.

        string displayName() const => this.name.length ? this.name : this.id;
        Duration delta() const => this.endTime - this.startTime;
    }

    enum SplitStyle
    {
        FAILSAFE,
        upcoming,
        active,
        glod,
        fasterButNotGlod,
        slower,
        slowest
    }

    private
    {
        Split[] _currentRun;
        Split[] _personalBestRun;
        Split[] _fastestEverSplits;
        Split[] _slowestEverSplits;
        
        Duration _elapsed;
        size_t _currentRunIndex;

        invariant(_currentRunIndex <= _currentRun.length, "_currentRunIndex is out of bounds");
        invariant(
            _currentRun.length == _personalBestRun.length
            && _currentRun.length == _fastestEverSplits.length
            && _currentRun.length == _slowestEverSplits.length,
            "All split arrays must be the same length"
        );
    }

    const(Split)[] currentSplits() const => this._currentRun;
    const(Split)[] personalBestSplits() const => this._personalBestRun;
    const(Split)[] fastestEverSplits() const => this._fastestEverSplits;
    const(Split)[] slowestEverSplits() const => this._slowestEverSplits;

    this(){} // Mainly useful for testing.

    this(Split[] initialSplits, JSONValue root)
    {
        import core.time : dur;
        import std.exception : enforce;
        import std.json : JSONType;

        enforce(root.type == JSONType.object, "Expected JSON object when deserialising root");

        Split splitFromJson(JSONValue object)
        {
            enforce(object.type == JSONType.object, "Expected JSON object when deserialising split");
            Split split;

            enforce(object["version_"].get!string == Split.init.version_, "Incompatible version field");
            static foreach(_, field; split.tupleof)
            {{
                const FieldName = __traits(identifier, field);
                alias FieldT = typeof(field);

                static if(is(FieldT == Duration))
                    __traits(getMember, split, FieldName) = object[FieldName].get!long.dur!"hnsecs";
                else
                    __traits(getMember, split, FieldName) = object[FieldName].get!FieldT;
            }}

            return split;
        }

        Split[] splitListFromJson(JSONValue array)
        {
            enforce(array.type == JSONType.array, "Expected JSON array when deserialising split list");

            Split[] list;
            foreach(value; array.array)
                list ~= splitFromJson(value); // @suppress(dscanner.vcall_ctor)

            return list;
        }

        this._currentRun        = initialSplits;
        this._personalBestRun   = splitListFromJson(root["personalBest"]); // @suppress(dscanner.vcall_ctor)
        this._fastestEverSplits = splitListFromJson(root["fastestEver"]); // @suppress(dscanner.vcall_ctor)
        this._slowestEverSplits = splitListFromJson(root["slowestEver"]); // @suppress(dscanner.vcall_ctor)

        void reorderSplits(scope ref Split[] list)
        {
            import std.range : insertInPlace;

            for(size_t i = 0; i < initialSplits.length; i++)
            {
                if(i >= list.length) // Add missing splits
                {
                    list ~= initialSplits[i];
                    continue;
                }
                else if(list[i].id != initialSplits[i].id)
                {
                    bool found = false;
                    foreach(j, ref listSplit; list[i..$]) // See if the split exists, but is in the wrong position, and if so move it.
                    {
                        if(list[i].id == initialSplits[i].id)
                        {
                            auto tempSplit = listSplit;
                            listSplit = list[i];
                            list[i] = tempSplit;
                            found = true;
                            break;
                        }
                    }

                    if(!found) // Otherwise add the missing split
                        insertInPlace(list, i, initialSplits[i]);
                    continue;
                }
                else // Id matches and its in the right position, so just make sure any display name override is up to date.
                    list[i].name = initialSplits[i].name;
            }

            // Drop excess/unknown splits
            list = list[0..initialSplits.length];

            // Sanity checks
            assert(list.length == initialSplits.length);
            foreach(i; 0..list.length)
                assert(list[i].id == initialSplits[i].id);
        }
        reorderSplits(this._personalBestRun); // @suppress(dscanner.vcall_ctor)
        reorderSplits(this._fastestEverSplits); // @suppress(dscanner.vcall_ctor)
        reorderSplits(this._slowestEverSplits); // @suppress(dscanner.vcall_ctor)
    }

    void split()
    {
        if(this._currentRunIndex < this._currentRun.length)
        {
            this._currentRun[this._currentRunIndex].endTime = this._elapsed;
            this._currentRunIndex++;
            
            if(this._currentRunIndex < this._currentRun.length)
                this._currentRun[this._currentRunIndex].startTime = this._elapsed;
        }
    }

    void splitIfIdMatchesNext(string id)
    {
        if(this._currentRunIndex + 1 < this._currentRun.length && this._currentRun[this._currentRunIndex+1].id == id)
            this.split();
    }

    void updateElapsedTime(Duration elapsed)
    {
        this._elapsed = elapsed;
    }

    JSONValue toJson()
    {
        JSONValue root;

        JSONValue splitToJson(Split split)
        {
            auto object = JSONValue.emptyObject;
            static foreach(_, field; split.tupleof)
            {{
                const FieldName = __traits(identifier, field);
                alias FieldT = typeof(field);

                static if(is(FieldT == Duration))
                    object[FieldName] = __traits(getMember, split, FieldName).total!"hnsecs";
                else
                    object[FieldName] = __traits(getMember, split, FieldName);
            }}

            return object;
        }

        JSONValue splitListToJson(Split[] splits)
        {
            auto array = JSONValue.emptyArray;
            foreach(split; splits)
                array.array ~= splitToJson(split);

            return array;
        }

        root["currentRun"] = splitListToJson(this._currentRun); // To be safe against bugs, keep the current run so I can manually fix the file.
        root["personalBest"] = splitListToJson(this._personalBestRun);
        root["fastestEver"] = splitListToJson(this._fastestEverSplits);
        root["slowestEver"] = splitListToJson(this._slowestEverSplits);

        return root;
    }

    void updateSplits()
    in(this._currentRunIndex >= this._currentRun.length - 1, "Cannot prematurely update splits - the run must be over.") // @suppress(dscanner.suspicious.length_subtraction)
    {
        const isPersonalBest = 
            this._personalBestRun[$-1].endTime == Duration.zero
            || (this._currentRun[$-1].endTime < this._personalBestRun[$-1].endTime);
        if(isPersonalBest)
            this._personalBestRun = this._currentRun;

        foreach(i, const thisRun; this._currentRun)
        {
            const fastest = this._fastestEverSplits[i];
            const slowest = this._fastestEverSplits[i];

            if(fastest.delta == Duration.zero || fastest.delta > thisRun.delta)
                this._fastestEverSplits[i] = thisRun;
            if(slowest.delta == Duration.zero || slowest.delta < thisRun.delta)
                this._slowestEverSplits[i] = thisRun;
        }
    }

    override void update(Duration delta)
    {
    }

    override void draw() 
    {
        const runIsOver = (this._currentRunIndex >= this._currentRun.length); // @suppress(dscanner.suspicious.length_subtraction)

        const start = (runIsOver) ? 0 : 
                        (this._currentRunIndex < 2) 
                            ? 0 
                            : this._currentRunIndex - 2;
        const end = (runIsOver) ? this._currentRun.length :
                        (this._currentRunIndex + 3 >= this._currentRun.length) 
                            ? this._currentRun.length 
                            : this._currentRunIndex + 3;

        foreach(i; start..end)
        {
            const current = this._currentRun[i];
            const pb      = this._personalBestRun[i];
            const fastest = this._fastestEverSplits[i];
            const slowest = this._slowestEverSplits[i];

            SplitStyle style;
            if(i < this._currentRunIndex)
            {
                if(current.delta < fastest.delta)
                    style = SplitStyle.glod;
                else if(current.delta < pb.delta)
                    style = SplitStyle.fasterButNotGlod;
                else if(current.delta > slowest.delta)
                    style = SplitStyle.slowest;
                else
                    style = SplitStyle.slower;
            }
            else if(i == this._currentRunIndex)
                style = SplitStyle.active;
            else
                style = SplitStyle.upcoming;

            const toBeat = (style == SplitStyle.active || style == SplitStyle.upcoming) 
                ? pb
                : current;
            const elapsed = (style == SplitStyle.active) 
                ? (this._elapsed - current.startTime) - toBeat.delta
                : current.delta - pb.delta;
            this.drawSplit(current.displayName, toBeat.endTime, elapsed, style);
        }
    }

    bool hasSplits() => this._currentRun.length > 0;

    const(Split) currentSplit()
    in(this.hasSplits(), "No splits have been loaded yet")
        => this._currentRun[this._currentRunIndex];

    private void drawSplit(
        string name,
        Duration toBeat,
        Duration delta,
        SplitStyle style,
    )
    {
        string bgColour;

        final switch(style) with(SplitStyle)
        {
            case FAILSAFE: assert(false, "FAILSAFE style");

            case upcoming:
                bgColour = Ansi.bgBlack;
                break;

            case active:
                bgColour = Ansi.bgBlack;
                break;
            
            case glod:
                bgColour = Ansi.bgBlack;
                break;

            case fasterButNotGlod:
                bgColour = Ansi.bgBlack;
                break;

            case slower:
                bgColour = Ansi.bgBlack;
                break;

            case slowest:
                bgColour = Ansi.bgBlack;
                break;
        }

        void line(Args...)(string fmt, Args args)
        {
            import std.stdio : writefln;
            import std.string : format;
            writefln("%s  %s%s", 
                bgColour,
                format(fmt, args),
                Ansi.reset
            );
        }

        line("");

        final switch(style) with(SplitStyle)
        {
            case FAILSAFE: assert(false, "FAILSAFE style");

            case upcoming:
                line("%s%s%s", Ansi.bold, Ansi.hiBlack, name);
                line("%s%s", Ansi.hiBlack, formatDuration(toBeat));
                break;

            case active:
                const deltaColour = (delta < Duration.zero) ? Ansi.green : Ansi.red;
                line("%s%s", Ansi.white, name);
                line("%s%s -> %s%s", 
                    Ansi.blue, formatDuration(toBeat), 
                    deltaColour, formatDuration(delta, WithPlusSign.yes),
                );
                break;
            
            case glod:
                line("%s%s", Ansi.yellow, name);
                line("%s%s << %s%s", 
                    Ansi.yellow, formatDuration(toBeat), 
                    Ansi.green, formatDuration(delta, WithPlusSign.yes)
                );
                break;

            case fasterButNotGlod:
                line("%s%s%s", Ansi.bold, Ansi.hiBlack, name);
                line("%s%s < %s%s", 
                    Ansi.hiBlack, formatDuration(toBeat), 
                    Ansi.green, formatDuration(delta, WithPlusSign.yes)
                );
                break;

            case slower:
                line("%s%s%s", Ansi.bold, Ansi.hiBlack, name);
                line("%s%s > %s%s", 
                    Ansi.hiBlack, formatDuration(toBeat), 
                    Ansi.red, formatDuration(delta, WithPlusSign.yes)
                );
                break;

            case slowest:
                line("%s%s", Ansi.red, name);
                line("%s%s >> %s%s", 
                    Ansi.red, formatDuration(toBeat), 
                    Ansi.red, formatDuration(delta, WithPlusSign.yes)
                );
                break;
        }

        line("");
    }
}

class SplitListStyleTest : SplitList
{
    override void update(Duration delta){}

    override void draw()
    {
        import core.time  : dur;
        import std.random : uniform;

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.upcoming
        );

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.active
        );

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.glod
        );

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.fasterButNotGlod
        );

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.slower
        );

        super.drawSplit(
            "00_MolePeopleCity_Or_Something",
            uniform(0, 1_000_000).dur!"msecs",
            uniform(0, 1_000_000).dur!"msecs",
            SplitStyle.slowest
        );
    }
}

class CompactSplitViewer : UiComponent
{
    private const(SplitList.Split)[] _splits;

    this(const SplitList.Split[] splits)
    {
        this._splits = splits;
    }

    override void update(Duration delta){}

    override void draw()
    {
        import std.algorithm : map, maxElement;
        import std.range     : repeat, take;
        import std.stdio     : writefln;
        const longestSplitName = this._splits.map!(s => s.displayName.length).maxElement;
    
        foreach(const split; this._splits)
        {
            writefln("%s%s | %s (%s)", 
                split.displayName, 
                repeat(' ').take(longestSplitName - split.displayName.length),
                formatDuration(split.endTime),
                formatDuration(split.delta)
            );
        }
    }
}

private alias WithPlusSign = Flag!"withPlusSign";

private string formatDuration(const Duration duration, WithPlusSign withPlusSign = WithPlusSign.no)
{
    import std.math   : abs;
    import std.string : format;
    
    const isNegative = duration < Duration.zero;
    const hours      = abs(duration.total!"hours");
    const minutes    = abs(duration.total!"minutes" % 60);
    const seconds    = abs(duration.total!"seconds" % 60);
    const millis     = abs(duration.total!"msecs" % 1000);
    const sign       = (withPlusSign && !isNegative) ? "+" : (isNegative ? "-" : "");

    return format("%s%02d:%02d:%02d.%03d", sign, hours, minutes, seconds, millis);
}