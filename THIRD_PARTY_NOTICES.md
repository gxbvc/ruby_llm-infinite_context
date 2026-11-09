# Third-party notices

This gem includes no third-party code, but its design is derived from these projects:

## OptChat / UniiChat (Victor Taelin)

The core design — an append-only message log summarized into a binary tree of one-line
summaries, a byte-budget view over that tree, and tools to zoom from a summary line down to
the original messages — comes from Victor Taelin's "OptChat" gist (titled "UniiChat").

- https://gist.github.com/VictorTaelin/91837951a5ce5b38f341ec1ba1df6449

The prompts in this gem are original text written for this gem; they implement the same ideas
(message kinds, the value order of what to keep, the byte limit, tagging items with their
kind) but are not copied from the gist.

## pi-optchat (Jonas) — MIT

An independent implementation of the same gist as a Pi extension, used as the up-to-date
reference for behavior. Its third-party notices file is the model for this file.

- https://github.com/jonaslsaa/pi-optchat
- https://www.npmjs.com/package/pi-optchat

Its license text:

```
MIT License

Copyright (c) 2026 Jonas Silva

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

(License text from pi-optchat's LICENSE file, read from the published npm tarball on
2026-11-09.)
