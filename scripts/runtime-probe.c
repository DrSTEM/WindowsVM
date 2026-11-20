#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
extern char **environ;

// QEMU's library entry points, also used by the open-source UTM launcher.
// This probe keeps the engine outside the native application's process.
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: runtime-probe library [qemu options]\n"); return 64; }
    void *library = dlopen(argv[1], RTLD_LOCAL | RTLD_NOW);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 69; }
    void (*initialize)(int, char **, char **) = dlsym(library, "qemu_init");
    void (*loop)(void) = dlsym(library, "qemu_main_loop");
    void (*cleanup)(void) = dlsym(library, "qemu_cleanup");
    if (!initialize || !loop || !cleanup) { fprintf(stderr, "Missing QEMU library entry points\n"); return 70; }
    initialize(argc - 1, argv + 1, environ);
    loop();
    cleanup();
    return 0;
}
