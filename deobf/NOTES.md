# Luarmor V4 loader analysis (GET_SL_b03bc27ceb91ee919888093e293c2458.lua)

## What the file is

`GET_SL_<hash>.lua` — a **Luarmor V4 "superflow" loader**. 843 KB, almost everything on one line.

Layout:

1. `superflow_bytecode = { ... }` — small table (3 pieces) whose middle piece is
   `_bsdata0[11] .. "..."`. `_bsdata0` is **not defined anywhere in the file**
   (it is external/companion data), so that part cannot be reconstructed.
2. `setmetatable({ ... 202 VM functions ... }, {})` — the "superflow" VM itself.
   Numeric keys of that table are the VM opcodes and library bindings, e.g.
   `[4]=bit32.rshift`, `[27]=bit32.band`, `[93]=buffer.readu8`, `[104]=bit32.bxor`,
   `[112]=buffer.create`, `[115]=Vector3.new`, `[120]=typeof`, `[32]=getmetatable`.
3. The VM payload lives in `T.x_` — 688 675 printable chars (85-symbol alphabet).
   It is decoded with
   `string.gsub(x_:sub(5), T.c_, T.s_)` where `T.c_ == "[ -'}~]"` and `T.s_` holds
   ten 6-char replacement strings (a custom alphabet), then XOR-decrypted at runtime
   (`bit32.bxor`) into the code / constant buffers.

## Harness

`deobf.luau` (Lune) runs the loader under a mocked Roblox/executor environment:

* pure-Luau `buffer` implementation (Lune's own buffer lib is incomplete),
* stubs for Roblox datatypes + executor globals (`task`, `getgenv`, `identifyexecutor`,
  `loadstring`, `debug`, …),
* patches the source to expose the VM table, then wraps every VM function to
  * log calls (`--trace`),
  * capture decrypted string constants (they pass through `buffer.tostring`),
  * shadow all buffer writes so the decrypted VM buffers can be dumped.

Usage:

```sh
lune run deobf.luau <loader.lua> <outdir> [--native|--trace]
```

## Results obtained

* VM payload decoded: 688 775-char stream → decrypted VM buffers
  (146 442 B "code", 51 806 B "constants", 551 020 B raw).
* 116 decrypted string constants of the script (`out/strings.txt`).
* API trace of the script (`out/api_calls.txt`): the loader prints an ASCII-art
  logo, then validates the executor environment
  (`task.*`, `debug.info` fields, `bit32`/`buffer`/`coroutine`/`string`/`table` API
  surface, `Vector3/UDim/Color3/Rect/UDim2/Vector2.new`) and probes Roblox classes
  (`Instance.new("Folder"/"ScreenGui"/"Frame"/"Path2D")`).

## Why there is no plain Luau source

The payload is **not** standard Luau bytecode: it is a proprietary "superflow"
register VM with its own opcode encoding and encrypted string table, so
`luau-decompiler`, `unluau`, `luau-decompile` and `flow-decompiler` all reject the
recovered buffers. Recovering readable source requires re-implementing the
superflow opcode map + string decryption, and the final protected script is
fetched at runtime (Luarmor CDN / `static_content` cache), plus the missing
`_bsdata0` blob.
