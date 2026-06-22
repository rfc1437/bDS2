// Native launcher for the BDS2 .app — compiled to a pure arm64 Mach-O by
// mix bds.bundle.macos. A shell-script main executable has no Mach-O slices, so
// LaunchServices advertises x86_64 and offers Rosetta; a real arm64 binary makes
// the bundle unambiguously Apple Silicon.
//
// Mirrors launcher.sh: resolve <Contents>, prepend Frameworks to the dyld
// fallback path, then exec <Contents>/Resources/rel/bin/<release> start.
#include <limits.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef BDS_RELEASE_NAME
#define BDS_RELEASE_NAME "bds"
#endif

int main(void) {
  char exec_path[PATH_MAX];
  uint32_t size = sizeof(exec_path);
  if (_NSGetExecutablePath(exec_path, &size) != 0) return 1;

  char resolved[PATH_MAX];
  if (realpath(exec_path, resolved) == NULL) return 1;

  // resolved = <Contents>/MacOS/bds2 ; climb two dirs to <Contents>.
  char macos[PATH_MAX];
  strncpy(macos, dirname(resolved), sizeof(macos) - 1);
  macos[sizeof(macos) - 1] = '\0';
  char *contents = dirname(macos);

  char frameworks[PATH_MAX];
  snprintf(frameworks, sizeof(frameworks), "%s/Frameworks", contents);

  const char *existing = getenv("DYLD_FALLBACK_LIBRARY_PATH");
  char fallback[2 * PATH_MAX];
  if (existing && *existing)
    snprintf(fallback, sizeof(fallback), "%s:%s", frameworks, existing);
  else
    snprintf(fallback, sizeof(fallback), "%s", frameworks);
  setenv("DYLD_FALLBACK_LIBRARY_PATH", fallback, 1);

  char bin[PATH_MAX];
  snprintf(bin, sizeof(bin), "%s/Resources/rel/bin/%s", contents, BDS_RELEASE_NAME);

  execl(bin, BDS_RELEASE_NAME, "start", (char *)NULL);
  perror("execl");  // only reached if exec failed
  return 127;
}
