# PkUncorder
A way to download all of your PK avatars! Just make sure `system.json` is put into this folder.

## To-Do
- [x] Generate an index that can be used for cache-related purposes.
- [x] Cache groups.
- [ ] Look into using PK's API rather than a `system.json` file.
- [ ] Make a web interface for this instead?
- [ ] Generate a new `system.json` with updated URLs.
- [ ] Make parser more robust.
- [ ] Setup proper package structure.

## How To Install
Currently there are no binaries pre-built, but if you install the [Nim](https://nim-lang.org) compiler, you
will be able to build it by cloning the repository or downloading the source, and running `nim c main.nim` within the folder.