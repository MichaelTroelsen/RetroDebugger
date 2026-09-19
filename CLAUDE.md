# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git & GitHub hygiene

**Never push AI-coding artifacts to GitHub.** Implementation plans, design specs, and any
AI-assistant working files — e.g. `docs/superpowers/` (plans/specs), `.claude/`,
`.superpowers/`, `claude/` — must NOT be committed to or pushed to the remote repository.
They are gitignored; keep it that way. Do not `git add` them and do not push commits that
contain them. `CLAUDE.md` / `AGENTS.md` (this guidance file) is the only AI-related file
intentionally tracked.

**Never push to the remote without explicit user consent.** Commit locally, then ask before
pushing.

## Project Overview

Retro Debugger is a real-time debugger for 8-bit computers: Commodore 64, Atari XL/XE, and
NES. It embeds full emulator engines (VICE, Atari800, NestopiaUE) and provides cycle-accurate
debugging through an ImGui-based interface. Previously known as "C64 65XE NES Debugger".

This checkout is a **fork whose purpose is fixing the MCP server**. See "MCP Server" below.

## Build Commands

### macOS (Xcode)
```bash
xcodebuild -project ./platform/MacOS/c64d.xcodeproj -target "Retro Debugger"
```
Or open `platform/MacOS/c64d.xcodeproj` in Xcode. `build-macos.sh` clones MTEngineSDL first.

### Linux (CMake)
```bash
./build-linux.sh        # Full build: clones MTEngineSDL + uSockets, builds everything
# Or manually:
mkdir -p build && cd build && cmake ../ && make -j$(nproc) retrodebugger
```

### Windows (PowerShell)
```powershell
.\build-windows.ps1                     # Clang Release x64 (default)
.\build-windows.ps1 -Compiler MSVC      # MSVC v143 instead of ClangCL
.\build-windows.ps1 -SkipDeps           # Skip llama.cpp / FTXUI / mbedTLS rebuild
.\build-windows.ps1 -Platform ARM64
```
Output: `platform\Windows\bin\<Platform>\<Configuration>\c64d.exe`. The VS solution
(`platform/Windows/c64d.sln`) can also be opened directly, but the script is the supported
path — it builds MTEngineSDL and its dependencies too.

**The Windows script does NOT clone MTEngineSDL** (unlike the Linux/macOS scripts). Clone it
yourself as a sibling first, or the script throws on `Push-Location $mtDir`.

#### Side-by-side Visual Studio installs
The project needs the **ClangCL** toolset (default) or **v143** (`-Compiler MSVC`). A newer VS
may have neither — VS 2026 (18.x) ships v145 only, while VS 2022 (17.x) has both. So
"newest VS" and "VS that can build this" are different questions:

- `build-windows.ps1` selects the VS instance **by the toolset it actually provides** (it used
  to use `vswhere -latest`, which picked the wrong one). Both the MSBuild lookup and the VC
  tools PATH resolve from that same instance — do not split them.
- **MTEngineSDL's dependency scripts still have this bug.** `build-llama_cpp_cpu.ps1`,
  `build-llama_cpp_cuda.ps1`, `build-ftxui.ps1` and `build-mbedtls.ps1` take CMake's *default*
  generator (= newest VS) and pair it with `-T ClangCL`, failing with
  "No CMAKE_CXX_COMPILER could be found". Until that is fixed upstream, set the generator
  before building:

  ```powershell
  $env:CMAKE_GENERATOR = "Visual Studio 17 2022"   # or whichever VS has the toolset
  .\build-windows.ps1
  ```

  `CMAKE_GENERATOR` overrides which generator CMake stars as its default, which is the exact
  line those scripts parse. A stale `build-windows-*` directory from a failed configure must be
  deleted first, or CMake refuses to reconfigure with a different generator.

### Keeping Build Projects in Sync
**IMPORTANT:** When adding, removing, or renaming source files in the Xcode project
(`platform/MacOS/c64d.xcodeproj`), you MUST also update the Linux CMake (`CMakeLists.txt`) and
Windows Visual Studio (`platform/Windows/c64d/c64d.vcxproj` + `.vcxproj.filters`) projects to
match. All three build systems use explicit file lists — there is no auto-discovery. The same
applies to MTEngineSDL — its Xcode, CMake, and Visual Studio projects must all be kept in sync
when files change.

### Critical Dependency
**MTEngineSDL** must exist at `../MTEngineSDL` — a **sibling** of this repo, not one level
further up. It provides SDL2 + ImGui integration, the GUI framework (`CGuiView`, `guiMain`),
and all platform abstractions. Repo: https://github.com/slajerek/MTEngineSDL

```bash
git clone --recursive https://github.com/slajerek/MTEngineSDL.git   # ~1.4 GB with submodules
```

**IMPORTANT: Do NOT modify MTEngineSDL directly.** It is an external library. If new
functionality is needed in MTEngineSDL, flag this to the user and wait for permission. We will
switch to the MTEngineSDL project space to implement changes there. Never implement or change
anything in MTEngineSDL without explicit user approval.

**IMPORTANT: Do NOT create git worktree it is not supported in both c64d and MTEngineSDL repos.

## Logging

`LOGD()`/`LOGM()` compile to no-ops when `GLOBAL_DEBUG_OFF` is defined; comment it out in the
platform's `DBG_Log.h` to enable output. Log destination is **platform-specific**, and the
`--log-dir` flag is **not** universal:

| Platform | Implementation | Default destination | `--log-dir` honoured? |
|---|---|---|---|
| macOS | `MTEngineSDL/platform/MacOS/src.MacOS/DBG_Log.mm` | `~/Library/Caches/RetroDebugger-*.txt` | yes |
| Windows | `MTEngineSDL/platform/Windows/src.Windows/DBG_Log.cpp:189` | `./log/MTEngine-*.txt`, falling back to `./MTEngine-*.txt` in the **working directory** | **no — silently ignored** |

On Windows this means test runs drop `MTEngine-*.txt` files into whatever directory you ran
from, including the repo root. They are untracked; delete them rather than committing them.

## Architecture

### Emulator Abstraction Layer
`CDebugInterface` (in `src/DebugInterface/`) is the abstract base class all emulators implement. Concrete implementations:
- `CDebugInterfaceVice` (C64, inherits `CDebugInterfaceC64`) in `src/Emulators/vice/ViceInterface/`
- `CDebugInterfaceAtari` in `src/Emulators/atari800/AtariInterface/`
- `CDebugInterfaceNes` in `src/Emulators/nestopiaue/NestopiaInterface/`

Emulators are enabled/disabled via `#define` flags in `src/Emulators/EmulatorsConfig.h` (`RUN_COMMODORE64`, `RUN_ATARI`, `RUN_NES`).

### Data Adapter Pattern
`CDebugDataAdapter` provides uniform memory access across different address spaces (C64 RAM, cartridge, REU, 1541 drive RAM, NES PPU/OAM, Atari regions). All generic memory views (hex dump, data map, watches) work through this abstraction.

### View System
Views inherit from `CGuiView` (MTEngineSDL base class) and render via `RenderImGui()`. Key views are in `src/Views/` with platform-specific subfolders (`C64/`, `Atari800/`, `Nes/`).

### Central Coordinator
`CViewC64` (`src/Screens/CViewC64.cpp`) is the main application view: manages emulator instances, layout switching, and coordinates multi-threaded emulation. Despite the name, it manages all emulated platforms. It also owns `debuggerServer` init order — the MCP startup race lived here.

### App Lifecycle
Entry point is `src/RetroDebuggerAppInit.cpp`. MTEngineSDL calls `MT_PreInit()` -> `MT_PostInit()` (creates `CViewC64`). CLI flags for tests and MCP modes are parsed at the top of `MT_PostInit()`. Settings folder: "RetroDebugger".

### Plugin System
Plugins extend `CDebuggerEmulatorPlugin` and hook into frame rendering and input. Registered in `src/Plugins/C64D_InitPlugins.cpp`. Present plugins: `Commando/`, `CrtMaker/`, `DNDK/`, `Galaxy/`, `GoatTracker/`. Plugin tests live in `src/Plugins/<Plugin>/tests/` and register through `C64D_RegisterPluginTests()`.

### Symbol & Breakpoint System
`CDebugSymbols` manages labels, breakpoints, and watches organized by `CDebugSymbolsSegment`. Supports VICE, KickAss, and other symbol file formats. Serialized as HJSON.

### Task System
`CDebugInterfaceTask` handles deferred/thread-safe emulator state changes, including VSync-synchronized operations.

### Remote Debugging
`src/Remote/` holds three transports: `WebSockets/` (JSON command protocol, test client in
`tools/websockets-debugger-test/`), `Pipe/`, and `MCP/`. Shared entry points are
`CDebuggerServer` / `CDebuggerServerApi`.

### Menu Bar
`CMainMenuBar` (`src/Views/CMainMenuBar.cpp`) is the largest single file (~5700 lines) containing all menu definitions and settings UI.

## MCP Server

The fork's focus. Implementation is `src/Remote/MCP/`:

- `CMCPServer.cpp` — the MCP server itself (the bulk of the code)
- `CMCPBridgeClient.cpp` — bridge client

Launch modes (parsed in `MT_PostInit()`): `--mcp-server`, `--mcp-headless`, `--mcp-live`.
Regression tests: `CTestMCPProtocol`, `CTestMCPBridge`, plus `CTestRemoteProtocol`.

Server startup order is coordinated from `CViewC64` together with
`src/Remote/CDebuggerServer.cpp` — that interaction is where the startup race was, so treat
changes there as touching the fix.

**Usage skill:** when the retrodebugger MCP server is connected (any `mcp__*retrodebugger*`
tool is available — the exact prefix depends on how the plugin is installed), you MUST READ
`docs/mcp/retrodebugger-mcp-skill.md` before using any MCP tools. It covers tool usage
guidelines, safe debugging defaults, and workflows — including the correct tool for each task
(e.g. `retro_memory_search` for finding game state variables, NOT manual memory reads).

## Embedded VICE

`src/Emulators/vice/root/version.h` reports **`3.10-WIP`** — the 3.1 -> 3.10 upgrade has landed
on master. (`README.md` still says "Vice v3.1"; the README is the stale one.) Type migration
(`BYTE` -> `uint8_t` etc.) is complete.

**WARNING:** VICE 3.1 (OLD) and VICE 3.10 (NEW) are different releases years apart — do NOT
confuse them.

Known open issue: a rewind-while-running 6502 jam regression, reproduced by
`CTestViceRewindWhileRunning` (kept out of the green suite; run it explicitly).

## Code Conventions

- Class names use `C` prefix (e.g., `CViewC64`, `CDebugInterface`)
- Logging via `LOGD()`, `LOGM()` macros from MTEngineSDL
- Configuration uses HJSON format (`CConfigStorageHjson`)
- Version string in `src/C64D_Version.h` (`RETRODEBUGGER_VERSION_STRING`)
- Command-line parsing in `src/Tools/C64CommandLine.cpp`; test/MCP flags in `src/RetroDebuggerAppInit.cpp`
- Settings storage in `src/Tools/C64SettingsStorage.cpp`

## GT2 Renoise Shortcuts

When adding a new functional key shortcut for the GoatTracker 2 Renoise layout,
update all three places together: the shortcut dispatcher
(`CGT2RenoiseInput`/focused GT2 views), the automated GT2 shortcut tests, and the
GoatTracker plugin menu (`C64DebuggerPluginGoatTracker::RenderMainMenuImGui()`).
If the shortcut is a user-visible command, add or update its menu item/shortcut
hint in the GT2 menu. Do not add GoatTracker-specific shortcut logic to
`CMainMenuBar`; the main menu should keep routing through generic plugin hooks.

## Writing Conventions

- **Never use `§` as a section marker.** Use `#` with the section number, e.g.
  `#11a.4`, `#15.4.1`. This applies to all prose: specs, docs, commit
  messages, PR bodies, code comments, and chat responses. The reason is
  plain-ASCII portability — `§` renders inconsistently across terminals,
  grep patterns, and diff tools, and the repo's existing spec/doc style
  already uses `#N` cross-references throughout.

## Claude Workspace (`claude/`)

The `claude/` directory is Claude's dedicated workspace. All Claude-generated artifacts go here
— **never** in project directories like `tools/`, `src/`, etc. (unless it's actual project
source code).

- **`claude/tools/`** — Scripts and utilities created by Claude (e.g., migration helpers, code generators)
- **`claude/architecture/`** — Technical documentation about the codebase
- **`claude/`** (root) — Status files, plans, assessments

**`claude/` is gitignored, so it does not exist in a fresh clone.** Do not write instructions
that depend on a file under `claude/` being present — check before reading, and create the
directory when you need it. Durable guidance belongs in this file or under `docs/`.

The `tools/` directory at the project root is reserved for user's project tools only (e.g.,
`Exomizer-Decrunch`, `c64d-champ`, `make-release`, `websockets-debugger-test`). Tracked
documentation lives in `docs/` (`docs/mcp/`, `docs/specs/`, `docs/a800fixes`,
`docs/release-notes.txt`).

**Technical docs**: When implementing features, fixing bugs, or changing architecture, update
the relevant documentation in `claude/`. If a doc doesn't exist yet for the area you're
changing, create one. Keep docs accurate and in sync with the code — outdated docs are worse
than no docs.

## Git Commits

- Do NOT add "Co-Authored-By" lines to commit messages.
- **"Commit and push" means**: Before committing, review and update all relevant documentation
  in `claude/architecture/`. Then commit and push **both** RetroDebugger and MTEngineSDL (if
  MTEngineSDL has changes). Always check both repos.

## Testing

Dual-framework test system in `src/Tests/` (ported from LightHeroes):

1. **CTest / suite** — Async integration tests (emulator state, memory ops, breakpoints)
2. **imgui_test_engine** — UI automation tests (menu verification, view interaction)

Both run headlessly from CLI. ~65 tests are registered, plus per-plugin registrars; a few are
deliberately commented out in the registrar with the reason inline.

### Running Tests

```bash
# Shell script (builds + runs + parses results)
tests/run_test.sh                               # All suite tests
tests/run_test.sh EmulatorStartup               # Single test
tests/run_test.sh --skip-build EmulatorStartup  # Skip build
tests/run_suite_isolated.sh                     # Each test in its own process

# Direct binary flags
./retrodebugger --headless --log-dir /tmp --run-suite --exit-after-tests                 # suite
./retrodebugger --headless --log-dir /tmp --run-tests --exit-after-tests                 # ImGui tests
./retrodebugger --headless --log-dir /tmp --run-test EmulatorStartup --exit-after-tests  # single
./retrodebugger --list-tests                                                             # names
```

**Always run from the repo root.** Results are written to `tests/results/last_run.txt`, a path
**relative to the working directory** — run from elsewhere and the file is silently never
written.

**On Windows** the binary is `platform\Windows\bin\x64\Release\c64d.exe`, and it is a
**GUI-subsystem PE**: it prints nothing to the console even in `--headless`, and `--log-dir` is
ignored (see "Logging"). An exit code of 0 is therefore *not* evidence a test ran. Read
`tests/results/last_run.txt`:

```powershell
Remove-Item tests\results\last_run.txt -EA SilentlyContinue
Start-Process ".\platform\Windows\bin\x64\Release\c64d.exe" `
  -ArgumentList "--headless","--run-test","MCPProtocol","--exit-after-tests" -Wait
Get-Content tests\results\last_run.txt
# [MCPProtocol] PASS: All MCP protocol tests passed (10/10)
# RESULT: 1/1 passed
```

### Adding Tests

1. Create `src/Tests/CTestMyFeature.h/.cpp` inheriting from `CTest`; `GetName()` returns the
   name used by `--run-test`
2. Register in `CTestSuiteRegisterRetroDebuggerTests()` (`src/Tests/CTestSuiteRetroDebugger.cpp`)
   — add the `#include` there too
3. For UI tests, add to `RegisterRetroDebuggerTests()` in `src/Tests/CImGuiTests.cpp`

**Important:** Emulators (C64, Atari, NES) can be enabled/disabled via the File menu. Not all
emulators may be running at test time. Tests that need a specific emulator must check
`di->isRunning` and call `viewC64->StartEmulationThread(di)` + `SYS_Sleep(2000)` if not
running, then restore the original state with `viewC64->StopEmulationThread(di)` afterward. See
`CTestOpenAllViews` and `CTestStackAnnotation` for examples.

Manual testing with test assets in `assets/tests/` and PRG files is also supported.
