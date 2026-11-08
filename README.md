# vmforge

Download OS images and run them as VMs on your Mac.

- **ARM64 guests (Linux, macOS)** run at near-native speed via Apple's Virtualization.framework (no dependencies; the helper compiles itself on first use).
- **x86_64 guests** are emulated with QEMU (`brew install qemu`), much slower.

```bash
./vmforge catalog                 # what you can download
./vmforge up alpine               # download + create + boot (try this first, ~70 MB)
./vmforge up ubuntu-desktop ubuntu --cpus 4 --mem 8192 --disk 60
./vmforge up macos mac            # latest macOS (~15 GB download, then installs)
./vmforge create win --iso ~/Downloads/some.iso   # your own ARM64 ISO
./vmforge ls | run NAME | eject NAME | rm NAME
./vmforge up debian --arch x86_64 # Intel guest via QEMU
```

After installing a Linux guest, run `./vmforge eject NAME` so it boots from its disk.
Everything lives in `~/VMForge` (override with `VMFORGE_HOME`). Downloads resume and are SHA-256 verified.
Closing the VM window hard-stops the guest, so shut down from inside the OS first.

## GUI

```bash
./build-gui.sh && open VMForge.app
```
A native SwiftUI window: create VMs from the catalog (or your own ISO) with progress, then start, stop, eject and delete them. It drives the same `vmforge` CLI.
