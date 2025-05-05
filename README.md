# libstd++ stubs generator

This program reads a `baseline_symbols.txt` from the official `libstdc++-v3`
library of the `gcc` project and generates an assembly file that can be used to
create libstdc++.so stubs given the target triple `<arch>-<os>-gnu[<glibc_version>]`
it corresponds to.

This stub can then be used to link against the libstdc++ without actually 
equiring to compile it nor depending of target libstdc++ prebuilds.

## Running

```sh
$ zig run main.zig -- -target aarch64-linux-gnu baseline_symbols.txt
$ ls -la build
drwxr-xr-x  11 root  staff     352 01 Jan 00:00 .
drwxr-xr-x  26 root  staff     832 01 Jan 00:00 ..
-rw-r--r--   1 root  staff     658 01 Jan 00:00 all.map
-rw-r--r--   1 root  staff  265786 01 Jan 00:00 libstdc++.S
```

> `baseline_symbols.txt` can be obtained in the `gcc` source tree.
> 
> https://raw.githubusercontent.com/gcc-mirror/gcc/refs/heads/master/libstdc%2B%2B-v3/config/abi/post/aarch64-linux-gnu/baseline_symbols.txt

## Inspiration

This project is largely inspired by the part of the Zig compiler that generates
glibc stubs and the https://github.com/ziglang/libc-abi-tools project.

Those projects gave birth to the glibc stub standalone generator: https://github.com/cerisier/glibc-stubs-generator
