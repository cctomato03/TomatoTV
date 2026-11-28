# FFmpeg headers (vendored)

These headers come from **FFmpeg n7.1** and are used only to compile the
`libffprobe.so` native module in `entry/src/main/cpp` (stream enumeration for
audio / subtitle tracks).

- Upstream: https://github.com/FFmpeg/FFmpeg/tree/n7.1
- License: LGPL-2.1-or-later (see `LICENSE.LGPLv2.1`)
- The native module links against the FFmpeg shared libraries that ship with
  `@ohos/ijkplayer` (libavformat / libavcodec / libavutil).
- `libavutil/avconfig.h` is a minimal hand-written replacement for the
  configure-generated header (little-endian, fast unaligned access).

Only needed because the OHOS NDK does not ship FFmpeg development headers.
