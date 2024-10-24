module toolkit.finders;

import toolkit.process, toolkit.scanning;

class ByteFinder // Specialised for finding singular bytes.
{
    private
    {
        GameProcess _process;
        Match[]     _matches;
    }

    this(GameProcess process)
    {
        this._process = process;
    }

    void find(ubyte needle)
    {
        this._process.pause();
        this._process.refreshMaps();
        scope(exit) this._process.resume();

        if(this._matches is null)
            this.initialScanForByte(needle);
        else
            this.furtherScanForByte(needle);
    }

    void reset()
    {
        this._matches = null;
    }

    Match[] currentMatches()
    {
        return this._matches;
    }

    private void initialScanForByte(ubyte needle)
    {
        foreach(map; this._process.memoryMaps)
        {
            import std : writeln;
            if(!map.readable)
            {
                writeln("[Ignored] Map is not readable: ", map);
                continue;
            }

            try this._process.accessMemory(map, (scope const ubyte[] memory)
            {
                scanBlockForByte(memory, needle, (Match match)
                {
                    match.map = map;
                    this._matches ~= match;
                });
            });
            catch(Exception ex)
            {
                import std : writeln;
                writeln("[Ignored] Failed to access memory: ", ex.msg, " ", map);
            }
        }
    }

    private void furtherScanForByte(ubyte needle)
    {
        Match[] newMatches;

        size_t matchIndex = 0;
        while(matchIndex < this._matches.length)
        {
            const start = matchIndex;
            auto end = matchIndex + 1;
            while(end < this._matches.length && this._matches[end].map == this._matches[start].map)
                end++;
            
            if(!this._process.mapStillExists(this._matches[matchIndex].map))
            {
                matchIndex = end;
                continue;
            }

            try this._process.accessMemory(this._matches[start].map, (scope const ubyte[] memory)
            {
                scanMatchesForByte(memory, this._matches[start..end], needle, (Match match)
                {
                    // Note: scanMatchesForBytes preserves the original match's map.
                    newMatches ~= match;
                });
            });
            catch(Exception ex)
            {
                import std : writeln;
                writeln("[Ignored] Failed to access memory: ", ex.msg, " ", this._matches[start].map);
            }

            matchIndex = end;
        }

        this._matches = newMatches;
    }
}