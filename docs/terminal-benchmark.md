# Terminal performance measurements

Run the same script **inside each terminal**, matching visible grid, font,
font size, display/refresh rate, power mode and scrollback settings:

```sh
./benchmark.sh --label ghostty
./benchmark.sh --label portal
./benchmark.sh --label ghostel
```

Each invocation runs three trials and prints medians. Results, samples, terminal
environment, script checksum and grid dimensions go in `build/benchmarks/*.json`.
Record other comparison settings with `--notes 'font, refresh rate, power mode, workload'`.
The default suite needs only Python 3; nothing is downloaded.
Keep the window visible and do not type; Ctrl-C stops the run. Resizing stops and
invalidates it. Benchmark terminals sequentially, with other benchmarks stopped;
alternate their order across repeated comparisons.

## What the numbers mean

| Metric | Interpretation |
| --- | --- |
| ASCII / truecolor / Unicode MiB/s | Bytes written then acknowledged by a cursor-position reply; higher is better. Includes PTY, parser and terminal work through the reply. |
| Idle reply p50 / p95 / p99 | Protocol round-trip milliseconds; lower is better. Includes benchmark, OS scheduling and terminal reply path. |
| Loaded batch reply p50 / p95 / p99 | Time to submit about 64 KiB of colored output and receive a subsequent reply, including burst write time. Repeatable backlog test, **not keyboard latency**. |
| Frame supply FPS | Full-grid updates submitted and parser-acknowledged per second; default target 60. **Not displayed FPS.** |
| Frame service p95 | Time to submit a prepared frame and receive its reply, excluding pacing sleeps. Shows tail stalls, not GPU frame time. |
| Missed supply slots | Producer missed its requested schedule; not renderer-skipped frames. |
| Optional CPU / sampled peak RSS | Host process CPU over the suite as a percentage of one core, and maximum RSS sampled every 0.5 seconds. Includes all of Emacs for Portal. |

Payloads and animation frames are prepared before timing; warm-ups are excluded. Writes handle
partial completion and time out. Cursor-position replies fence trials, avoiding
merely timing PTY-buffer filling, but **do not fence GPU presentation**. JSON holds
latency percentiles and per-trial data; the console reports median trial p50/p95s.

The default uses the alternate screen and restores the previous screen afterward.
Its scrolling test excludes scrollback accumulation. To include configured scrollback storage, run separately
in both terminals:

```sh
./benchmark.sh --label portal-scrollback --mode throughput --scrollback
```

This writes to the main screen, leaving output in scrollback; do not compare with
alternate-screen runs. CJK repeats warmed glyphs; it does not measure cold glyph
caches or complex emoji shaping. Benchmark without multiplexers such as tmux first:
they may answer protocol queries themselves.

## FPS benchmarks found online

- [Fortio `fps`](https://github.com/fortio/fps) is an animated FPS stress test with
  frame-time statistics. Its [measurement loop](https://github.com/fortio/fps/blob/main/fps.go)
  draws and waits for cursor-position replies: application/terminal round trips,
  not confirmed presentation. Optional independent check:
  `brew install fortio/tap/fps`, then `fps -fire -n 600 -json 60`.
- [DOOM-fire-zig](https://github.com/const-void/DOOM-fire-zig) is a visually demanding
  FPS demo. Its authors call comparisons unscientific and report choppiness despite
  higher reported FPS. Use it to spot stutter, not prove every frame was displayed.
- [kitty's benchmark](https://sw.kovidgoyal.net/kitty/performance/),
  `kitten __benchmark__`, measures parsing workloads, normally without rendering.
  `--render` enables rendering, but the docs warn that asynchronous rendering
  prevents proper rendering-performance measurement.
- [vtebench](https://github.com/alacritty/vtebench) offers broader PTY workloads,
  explicitly disclaiming frame-rate or latency measurement.

## Measure displayed frames on macOS

Use Apple's [Game Performance / Metal Instruments workflow](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/)
for frame duration, presentation and missed vsync intervals. Attach to **Emacs**
for embedded Ghostty: its renderer lives there. Get the PID with `M-: (emacs-pid)`.
For standalone Ghostty, use its app PID from Activity Monitor, not the shell's PID.

```sh
./benchmark.sh --label portal-trace --mode frames --seconds 15 --runs 1 \
  --target-fps 120 --pid 12345 --trace
```

Replace `12345`. This starts `xctrace` with the Game Performance template, waits for recording,
runs the workload, and saves a `.trace` beside the JSON. Full Xcode and existing
profiling access are required; failures go in the adjacent `.trace.log`.
Open the trace in Instruments; inspect the **Display** track and CPU/GPU scheduling
during the workload's timestamps. Display-wide vsync/surface-swap totals include
other apps: identify terminal presentation activity rather than reporting those
totals as terminal FPS. For IOSurface-backed
embedding layers, also inspect Core Animation presentation: GPU submissions alone
do not prove visible updates. Profiling adds overhead; compare equally
instrumented runs separately from the normal suite.

Use `--target-fps 60` for 60 Hz displays, 120 for 120 Hz. Uncapped supply
(`--target-fps 0`) measures update-processing capacity and can exceed refresh rate.
JSON `displayed_fps` remains null without separate presentation measurement;
no displayed FPS is fabricated.

## Measure the “snappy” feeling

The most relevant measure is **key-to-visible-pixel latency**, idle and under
output/Emacs load.
[Typometer](https://github.com/pavelfatin/typometer) injects OS keys and detects
resulting pixels. It supports macOS but is an older Java tool: verify it on your OS
and calibrate capture overhead. A high-speed camera filming key action and screen
is another independent end-to-end method. Report median and tail latency, not
just average. Protocol replies omit real input/display paths and cannot substitute.

Compare quiet Emacs with realistic redisplay/GC/Lisp activity in a second pane,
keeping the embedded terminal visible. Record workload and duration for repetition.
Sample resources separately too:

```sh
./benchmark.sh --label portal-resources --pid 12345
```

Match exact Ghostty engine/configuration where possible: the embedded wrapper and
installed release may use different engine revisions. A single throughput score
or composite “winner” hides these differences.

Research checked 2026-09-18. Execution verified in standalone Ghostty and native
Portal, including an Instruments capture. These smoke runs used different grids:
they are not comparative performance results. Local harness verification:
`./test.sh integration --suite benchmark-tool`.
