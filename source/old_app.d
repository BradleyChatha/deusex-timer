// The following memory addresses all get set (... most of the time) to 0x01 during a loading screen.
//
// Since they don't _always_ get set and I haven't fully narrowed down whether each of them is actually a "loading"
// flag or not, I'm going to call them "possible flags" for now.
//
// If at least half the flags are set to 0x01, then we can assume that the game is in a loading screen.
const POSSIBLE_FLAGS_ADDRESSES = [
	// 0x86f395,
	// 0x86d7e4,
	// 0x86f3e0,
	// 0x86f3f4,
	// 0x86f43c,
	// 0x86f46a,
	// 0x86f89d,

	// 0xd7413c5,
	// 0xd741215,
	// 0xd74120d,
	// 0xd741205,
	// 0xd7411c5,
	// 0xd741095,
	// 0xd741085,
	// 0xd741055,
	// 0xd741015,
	// 0xd740f95,

	// 0xd0c48a9,
	// 0xd0c4da9,
	// 0xd0c8df1,
	// 0xd0c9db1,
	// 0xd0c9ef1,
	// 0xd0ca191,
	// 0xd10fe75,
	// 0xd10feb5,
	// 0xd10fef5,
	// 0xd10ff35,
	// 0xd10ff75,

	// This seems to be the one!... But it's quirky:
	// 	- On load it is set to 0x01, then reset to 0x00 as expected.
	//  - On *save* it is set to 0x02, and stays like that until a load screen is hit.
	//
	// So until I have a second flag to detect when the game is paused/saving, I can only stop the timer for loads, not saves.
	// 0x102a2659,
	// It wasn't the one.

	0x9c2807,
	0x1f3925b,
];

/*
d7413c5, 260 +        113c5,  misc, 0, [I16 I8 ]
d741215, 260 +        11215,  misc, 0, [I16 I8 ]
d74120d, 260 +        1120d,  misc, 0, [I8 ]
d741205, 260 +        11205,  misc, 0, [I8 ]
d7411c5, 260 +        111c5,  misc, 0, [I8 ]
d741095, 260 +        11095,  misc, 0, [I16 I8 ]
d741085, 260 +        11085,  misc, 1, [I16 I8 ]
d741055, 260 +        11055,  misc, 1, [I16 I8 ]
d741015, 260 +        11015,  misc, 1, [I16 I8 ]
d740f95, 260 +        10f95,  misc, 1, [I16 I8 ]

[ 0]      d0c48a9, 255 +        148a9,  misc, 3, [I16 I8 ]
[ 1]      d0c4da9, 255 +        14da9,  misc, 2, [I16 I8 ]
[ 2]      d0c8df1, 255 +        18df1,  misc, 0, [I16 I8 ]
[ 3]      d0c9db1, 255 +        19db1,  misc, 1, [I32 I16 I8 ]
[ 4]      d0c9ef1, 255 +        19ef1,  misc, 1, [I16 I8 ]
[ 5]      d0ca191, 255 +        1a191,  misc, 2, [I32 I16 I8 ]
[ 6]      d10fe75, 255 +        5fe75,  misc, 2, [I8 ]
[ 7]      d10feb5, 255 +        5feb5,  misc, 2, [I8 ]
[ 8]      d10fef5, 255 +        5fef5,  misc, 2, [I8 ]
[ 9]      d10ff35, 255 +        5ff35,  misc, 2, [I8 ]
[10]      d10ff75, 255 +        5ff75,  misc, 2, [I8 ]
[11]     102a2659, 285 +        ee659,  misc, 2, [I32 I16 I8 ]
*/

alias Flags = ubyte[POSSIBLE_FLAGS_ADDRESSES.length];

import core.sys.posix.sys.uio : iovec;
extern(C) ptrdiff_t process_vm_readv(int pid, iovec* local, size_t len, iovec* remote, size_t rlen, ulong flags);

import std.stdio : File;

const ANSI_RED    = "\x1b[31m";
const ANSI_GREEN  = "\x1b[32m";
const ANSI_YELLOW = "\x1b[33m";
const ANSI_BLUE   = "\x1b[34m";
const ANSI_RESET  = "\x1b[0m";
const ANSI_CLEAR  = "\x1b[2J\x1b[H";

struct GameMemory
{
	int pid;
	File procMem;
}

struct View
{
	import std.datetime : Duration;

	Duration elapsedTime;
	Flags 	 flags;
	bool 	 isGameLoading;
	bool     waitingForFirstLoad;
	int 	 pid;
}

void oldMain()
{
	import std.algorithm : filter;
	import std.datetime  : Clock, Duration, dur;
	import core.thread   : Thread;

	auto game = loadGameMemory();
	const refreshRate = dur!"msecs"(1000 / 60); // 60 FPS...ish

	import std : writeln;
	const maps = readMapsForProcess(game.pid);
	foreach(map; maps.filter!(m => m.readable))
	{
		try
		{
			const ranges = scanForString(map, "UNATCO");
			foreach(range; ranges)
			{
				import std : to;
				writeln("Found 'LOADING' at ", range.start.to!string(16), " - ", range.end, " in ", map.pathname);
			}

			// if(ranges.length == 0)
				// writeln("No 'LOADING' found in ", map);
		}
		catch(Exception e)
		{
			// writeln(e.msg, ": ", map);
		}
	}
	return;

	auto lastStart = Clock.currTime;
	bool wasLoading = false;
	bool waitingForFirstLoad = true;
	Duration timer;
	while(true)
	{
		const start = Clock.currTime;

		if(!waitingForFirstLoad)
		{
			if(!wasLoading)
				timer += (start - lastStart);
			View view;
			view.flags = peekFlags(game.pid);
			view.isGameLoading = isGameLoading(view.flags);
			view.elapsedTime = timer;
			wasLoading = view.isGameLoading;

			render(view);
		}
		else
		{
			View view;
			view.flags = peekFlags(game.pid);
			view.waitingForFirstLoad = true;
			view.pid = game.pid;

			render(view);

			waitingForFirstLoad = !view.flags.isGameLoading();
		}

		const end = Clock.currTime;
		const elapsed = (end - start);
		if(elapsed < refreshRate)
			Thread.sleep(refreshRate - elapsed);
		lastStart = start;
	}
}

void render(View view)
{
	import std.stdio : writefln, writef;

	writef("%s\n", ANSI_CLEAR);

	if(view.waitingForFirstLoad)
	{
		writefln("  Waiting for first load...");
		writefln("  [P] %s", view.pid);
	}
	else
	{
		const hours   = view.elapsedTime.total!"hours";
		const minutes = view.elapsedTime.total!"minutes" % 60;
		const seconds = view.elapsedTime.total!"seconds" % 60;
		const millis  = view.elapsedTime.total!"msecs" % 1000;
		const timerColour = view.isGameLoading ? ANSI_YELLOW : ANSI_BLUE;
		writefln("  [T] %s%02d:%02d:%02d.%04d%s", timerColour, hours, minutes, seconds, millis, ANSI_RESET);
	}

	writef("  [F] ");
	foreach(i, flag; view.flags)
	{
		if(flag <= 1)
		{
			const colour = flag == 0x01 ? ANSI_GREEN : ANSI_RED;
			writef("%s%d", colour, flag);
		}
		else
			writef("%s*", ANSI_YELLOW);
	}
	writefln("%s", ANSI_RESET);

	foreach(i, flag; view.flags)
	{
		writefln(" [F%d] %08X = %d", i, POSSIBLE_FLAGS_ADDRESSES[i], flag);
	}
	
	writefln("\n\n\n\n"); // So the cursor doesn't get in the way
}

GameMemory loadGameMemory()
{
	GameMemory game;
	game.pid = findDeusExPid();

	return game;
}

int findDeusExPid()
{
	import std.algorithm : endsWith, splitter, filter, canFind;
	import std.conv      : to;
	import std.exception : enforce;
	import std.range     : dropOne;
	import std.string    : lineSplitter;
	import std.process   : execute;

	const result = execute(["ps", "aux"]);
	enforce(result.status == 0, "Failed to execute ps aux");

	foreach(line; result.output.lineSplitter)
	{
		if(
				(line.endsWith("DeusEx.exe") || line.endsWith("deusex.exe")) 
			&& !line.canFind("waitforexitandrun")
			&& !line.canFind("ps aux")
			&& !line.canFind("steam.exe")
		)
		{
			return line
					.splitter(' ')
					.dropOne // Drop the first element (the username)
					.filter!(l => l.length > 0) // Filter out empty strings that were created by multiple spaces
					.front
					.to!int;
		}
	}

	throw new Exception("DeusEx.exe not found in list of active processes");
}

Flags peekFlags(int pid)
{
	Flags flags;

	// This could be a _lot_ more efficient, but since the flag count is so low now I'm not gonna bother.
	foreach(i, ref flag; flags)
	{
		iovec local;
		local.iov_base = &flag;
		local.iov_len = 1;

		iovec remote;
		remote.iov_base = cast(void*)POSSIBLE_FLAGS_ADDRESSES[i];
		remote.iov_len = 1;

		const result = process_vm_readv(pid, &local, 1, &remote, 1, 0);
		// if(result == -1)
		// 	throw new Exception("Failed to read memory");
	}

	return flags;
}

bool isGameLoading(Flags flags)
{
	import std.algorithm : count;
	return flags[].count!(f => f == 0x01) >= ((flags.length / 2) + flags.length / 4) + 1;
}


/*******✨MEMORY SCANNING BULLSHIT✨*******/

struct Map
{
	int pid;
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

struct Range
{
	ulong start;
	ulong end;
}

Map[] readMapsForProcess(int pid)
{
	import std.conv   : to;
	import std.file   : readText;
	import std.string : lineSplitter;
	import std.regex  : regex, matchFirst;

	Map[] mappings;
	const reg = regex(r"([0-9a-f]+)-([0-9a-f]+)\s+([-r][-w][-x][-p])\s+([0-9a-f]+)\s+([0-9a-f]+):([0-9a-f]+)\s([0-9]+)\s+(.*)"); // @suppress(dscanner.style.long_line)

	foreach(line; readText("/proc/" ~ pid.to!string ~ "/maps").lineSplitter)
	{
		const captures = line.matchFirst(reg);
		if(!captures)
			continue;

		mappings ~= Map(
			pid,
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

	return mappings;
}

Range[] scanForString(Map map, string needle)
{
	import std.algorithm : find;
	import core.stdc.stdlib : malloc, free;

	const size = map.end - map.start;
	ubyte* buffer = cast(ubyte*)malloc(size);
	if(buffer is null)
		throw new Exception("Failed to allocate memory for buffer");
	
	scope(exit) free(buffer);

	// Read the memory
	iovec local;
	local.iov_base = buffer;
	local.iov_len = size;

	iovec remote;
	remote.iov_base = cast(void*)map.start;
	remote.iov_len = size;

	const result = process_vm_readv(map.pid, &local, 1, &remote, 1, 0);
	if(result == -1)
	{
		import core.stdc.errno : errno;
		import std.string : fromStringz;
		import core.sys.posix.string : strerror;
		throw new Exception("Failed to read memory: " ~ strerror(errno).fromStringz.idup);
	}

	// Scan the memory
	Range[] ranges;

	for(size_t i = 0; i < size; i++)
	{
		if(i + needle.length >= size)
			break;
		if(buffer[i] != needle[0])
			continue;

		if(buffer[i..i + needle.length] == needle)
			ranges ~= Range(map.start + i, map.start + i + needle.length);
	}

	return ranges;
}