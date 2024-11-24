module toolkit.input;

class RawInput
{
    import core.sys.linux.fcntl  : open, F_SETFL, O_NONBLOCK, O_RDONLY;
    import core.sys.linux.unistd : read;
    import core.sys.linux.uinput : input_event;

    private
    {
        int _eventFd;
    }

    this(string eventFile = "/dev/input/event0")
    {
        import std.string : toStringz;

        this._eventFd = open(eventFile.toStringz, O_RDONLY | O_NONBLOCK); // Phobos doesn't suport non-blocking I/O :/
        if(this._eventFd < 0)
        {
            import core.stdc.errno : errno;
            import std.string : fromStringz;
            import core.sys.posix.string : strerror;
            throw new Exception("Failed to open input event file: " ~ strerror(errno).fromStringz.idup);
        }
    }

    void nextInputs(alias MaxEvents = 100)(void delegate(scope input_event[]) onInput)
    in(onInput !is null)
    {
        ubyte[MaxEvents * input_event.sizeof] buffer = void;
        const bytesRead = read(this._eventFd, buffer.ptr, buffer.length);
        if(bytesRead <= 0)
            return;

        auto usedBuffer = buffer[0..bytesRead];
        const partialReadBytes = bytesRead % input_event.sizeof;
        if(partialReadBytes > 0)
        {
            usedBuffer = buffer[0..$-partialReadBytes];
            assert(false, "debug");
        }

        onInput(cast(input_event[])(cast(void[])usedBuffer));
    }
}

alias KeyT = ushort;

enum PressState
{
    FAILSAFE,
    pressed,
    released,
    tapped
}

struct KeyEvent
{
    KeyT key;
    PressState state;
}

interface IProcessedInput
{
    void nextInputs(void delegate(scope KeyEvent[]) onKeyboardInput);
}

class NoInput : IProcessedInput
{
    static NoInput instance;

    static this()
    {
        this.instance = new NoInput();
    }

    void nextInputs(void delegate(scope KeyEvent[]) onKeyboardInput){}
}

class ProcessedInput(KeyT[] KeysOfInterest) : IProcessedInput
{
    private
    {
        RawInput _keyboard;
        RawInput _mouse;
    }

    this(RawInput keyboard, RawInput mouse)
    in(keyboard !is null)
    in(mouse !is null)
    {
        this._keyboard = keyboard;
        this._mouse = mouse;
    }

    void nextInputs(void delegate(scope KeyEvent[]) onKeyboardInput)
    {
        import core.sys.linux.input : EV_KEY;
        import std.algorithm        : filter, canFind;

        bool[KeysOfInterest.length] keyAlreadyHandled;
        bool[KeysOfInterest.length] keyPressMask;
        KeyEvent[KeysOfInterest.length] keyboardEvents = void;
        size_t keyboardEventsCount;

        size_t indexForKey(KeyT key)
        {
            for(size_t i = 0; i < KeysOfInterest.length; i++)
            {
                if(KeysOfInterest[i] == key)
                    return i;
            }
            assert(false, "Key not found?");
        }

        bool canHandle(KeyT key)
        {
            const index = indexForKey(key);
            if(keyAlreadyHandled[index])
                return false;
            keyAlreadyHandled[index] = true;
            return true;
        }

        void pushEvent(KeyEvent event)
        {
            keyboardEvents[keyboardEventsCount++] = event;
        }

        this._keyboard.nextInputs((scope inputs){
            auto ofInterest = inputs.filter!(i => i.type == EV_KEY && KeysOfInterest.canFind(i.code));
            import std : writeln; writeln(ofInterest);
            foreach(input; ofInterest)
            {
                const keyIndex = indexForKey(input.code);
                switch(input.value)
                {
                    case 0: // release
                        if(keyPressMask[keyIndex])
                        {
                            keyPressMask[keyIndex] = false;
                            if(canHandle(input.code))
                                pushEvent(KeyEvent(input.code, PressState.tapped));
                        }
                        else
                        {
                            if(canHandle(input.code))
                                pushEvent(KeyEvent(input.code, PressState.released));
                        }
                        break;

                    case 1: // keypress
                    case 2: // autorepeat
                        keyPressMask[keyIndex] = true;
                        break;

                    default: break;
                }
            }

            foreach(i, pressed; keyPressMask)
            {
                if(keyPressMask[i] && canHandle(KeysOfInterest[i]))
                    pushEvent(KeyEvent(KeysOfInterest[i], PressState.pressed));
            }
        });

        if(keyboardEventsCount > 0)
            onKeyboardInput(keyboardEvents[0..keyboardEventsCount]);
    }
}

alias tt = PersistedInput!([0]);
class PersistedInput(KeyT[] KeysOfInterest)
{
    private
    {
        PressState[KeysOfInterest.length] _keys;
    }

    void onInput(KeyEvent[] events)
    {
        import std.algorithm : filter, canFind;

        auto ofInterest = events.filter!(e => KeysOfInterest.canFind(e.key));
        foreach(event; ofInterest)
            this._keys[indexForKey(event.key)] = event.state;
    }

    void resetTappedKeys()
    {
        foreach(ref key; this._keys)
        {
            if(key == PressState.tapped)
                key = PressState.released;
        }
    }

    private size_t indexForKey(KeyT key)
    {
        for(size_t i = 0; i < KeysOfInterest.length; i++)
        {
            if(KeysOfInterest[i] == key)
                return i;
        }
        assert(false, "Key not found?");
    }

    bool isDown(KeyT key)
    {
        const state = this._keys[this.indexForKey(key)];
        return state == PressState.pressed || state == PressState.tapped;
    }
}