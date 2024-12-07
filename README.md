# A speedrun timer for DeusEx GOTY edition on Linux & Proton/Wine.

In short: I wanted to speedrun this game, but it wasn't worth installing Windows just to have an accurate timer + autosplits. As load removal is actually pretty important for this game I decided to learn everything I needed to make my own timer with a load remover.

There's some slight potential here for making this a more generic toolkit, but I'll only worry about fully achieving that goal if I want to speedrun other games... or if I just want to mess around with making a cool tool.

## Features

* Works with the GOTY Steam version - probably won't work with any other version.
* Automatic detection for: Game Start, Level Load, Game End, and Game Restart.
* Autosplitter and load remover.
* Uses Linux functionality that most modern desktop distros should support - doesn't use DE/Compositor specific APIs.

## Installing/Building

Currently there's no prebuilt release, so you'll need to build things yourself:

1. Install the ldc2 D compiler - there's usually a package available for common distros.
2. Double check that dub is installed (`dub --version`) otherwise there might be an extra package you need to install.
3. Run `dub build` or `dub run` at the root of this repository (Note: running the program will likely show an error - this is normal).

There is only a dependence on libc existing - which is already a hard requirement for standard D programs. Your Linux kernal should also support the `ptrace` and `process_vm_readv` syscalls, which should generally be a given unless you're on an ancient kernal.

## Running the timer

Either use `dub run`, or `dub build` followed by `./deusex-timer`.

At the moment the timer will only work when Deus Ex is actively running. If you try to open the program before opening the game, then you'll get an error.

Once the game is running, you should be able to just run the program (potentially needs to run as root on some systems) and things should Just Work (tm).

**If you restart the game, you must also restart the timer program.**

## USAGE

### Main timing functions

* The timer will automatically start upon loading into the first level of the game.
* The timer will automatically end upon achieving the "Dark Age" ending (no other endings are supported right now).
* The timer will automatically restart if the intro level is loaded during an active run.
* The timer may induce a frame or two of inaccuracy per load, I'm not super sure yet. I definitely need to improve its accuracy, though it should be good enough for non-WR paces.
* Currently splits are hardcoded, and are setup for the specific any% route I use, but this can easily change in the future.
* Autosplitting is supported by detecting the name of the last loaded map - this is achieved via code injection.
* Load removal is supported only for loads right now, and not saves - this is acheived via code injection.

The timer will keep track of the following:

* Splits for personal best runs.
* Fastest ever splits across all runs.
* Slowest ever splits across all runs.
* It will auto save the "last run" splits, but it never loads them back in - this is for events such as bugs and crashes.

Saving behaviour:

* Splits are saved automatically upon closing the program with CTRL+C. 
* PB, Fastest ever, and Slowest ever splits are only updated upon a completed run.
* Splits are automatically loaded when launching the program. 
* Loads of room for improvement here, but it's good enough for now.

It will display splits for the current run in the following manner:

* Fastest ever splits will be gold/yellow, and use the symbol "<<".
* Splits faster than your PB, but not fastest ever, will be green and use the symbol "<".
* Splits slower than your PB, but not slowest ever, will be red and use the symbol ">".
* Slowest ever splits will be red, and use the symbol ">>".

### Some nitty gritty details

Code injection is achieved by using [ptrace](https://man7.org/linux/man-pages/man2/ptrace.2.html). This requires the `CAP_SYS_PTRACE` capability to work properly. I can't (easily) use `process_vm_writev` for this purpose as I'd still have to use ptrace in order to modify page permissions anyway - something that ptrace can already bypass, but `process_vm_writev` can't.

Reading from Deus Ex's memory is instead achieved with [process_vm_readv](https://man7.org/linux/man-pages/man2/process_vm_readv.2.html). If the program can use `ptrace` succesfully then it should already have the correct capabilities to use this syscall.

Information on memory layout, and the ability to detect the process ID for Deus Ex, is achieved by using the special kernal-backed `/proc/` "directory".

Raw keyboard and mouse input are read from the special input-driver-backed `/dev/input` "directory". Keyboard input is read from `event0` by default, and mouse input is read from `mouse0`.

There's some more in-depth details within `app.d`'s source code around how exactly the code injection works.