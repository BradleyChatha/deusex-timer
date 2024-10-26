module toolkit.ui;

import core.time : Duration;

abstract class Ansi
{
    static const red        = "\x1b[31m";
    static const green      = "\x1b[32m";
    static const yellow     = "\x1b[33m";
    static const blue       = "\x1b[34m";
    static const hiBlack    = "\x1b[0;90m";
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
        UiComponent[] _components;
    }

    void addComponent(UiComponent component)
    {
        this._components ~= component;
    }

    void loop(const Duration targetLoopTime)
    {
        import std.datetime : Clock;
        import std.stdio    : writeln;
        import core.thread  : Thread;

        auto lastFrameTime = Clock.currTime();
        while(true) // Intentionally infinite
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
            const hours   = elapsed.total!"hours";
            const minutes = elapsed.total!"minutes" % 60;
            const seconds = elapsed.total!"seconds" % 60;
            const millis  = elapsed.total!"msecs" % 1000;

            writefln("  [%s] %s%02d:%02d:%02d.%03d%s", tag, colour, hours, minutes, seconds, millis, Ansi.reset);
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
                writefln("  %s%s%s", Ansi.hiBlack, "Note: End-of-game detection \n        not implemented yet.", Ansi.reset);
                break;
        }
    }
}