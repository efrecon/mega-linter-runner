# mega-linter-runner

This projects implements:

1. A pure POSIX shell replacement for the `mega-linter-runner`. The script only
   supports short options, but is otherwise almost compatible with the original.
   By default, it will pass all relevant environment variables into the
   container.
2. A GitHub action based on the script. The original purpose of this action was
   to achieve quicker download times for the Docker image implementing the
   MegaLinter, but this has shown to be a red herring. GitHub might be caching
   locally within its infrastructure.

Even though no speed improvements have been shown when at GitHub, you might find
this project useful:

1. Provided a UNIX-compatible shell, it is quicker than running
   `mega-linter-runner` via `npx`. This is because `npx` will download the
   runner (and its dependencies) before running it.
2. Since the default is to run against the GHCR, this script will bypass the
   rate limiting restrictions at the Docker Hub.
3. When run as an action, it automatically passes the environment variables into
   the MegaLinter container, and generate the same `output` as the original
   action.
