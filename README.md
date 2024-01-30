# mega-linter-runner

This projects implements:

1. A pure POSIX shell *replacement* for the [`mega-linter-runner`][runner]. The
   [script](#cli) only supports short options, but is otherwise almost
   compatible with the original. By default, it will pass all relevant
   environment variables into the container. You can set some more using the
   `-e` option.
2. A GitHub [action](#action) based on the script. The original purpose of this
   action was to achieve quicker download times for the Docker image
   implementing the MegaLinter, but this has shown to be a red herring. GitHub
   might be caching locally within its infrastructure.

Even though no speed improvements have been shown when at GitHub, you might find
this project useful:

1. Provided a UNIX-compatible shell, it is quicker than running
   [`mega-linter-runner`][runner] via `npx`. This is because `npx` will download
   the runner (and its dependencies) before running it.
2. This script automatically passes existing and relevant environment variables.
3. Since the default is to run against the GHCR, this script will bypass the
   rate limiting restrictions at the Docker Hub.
4. When run as an action, it behaves as the original action, and generates the
   same `output` as the original action. As downloading from the GHCR is the
   default, using this action should have one less moving part.

  [runner]: https://megalinter.io/latest/mega-linter-runner/

## Examples

### CLI

The following would run the MegaLinter (`documentation` flavour) against the
current directory, selecting the `BASH_SHELLCHECK` linter only. It will
automatically check the latest released version of the MegaLinter at GitHub and
run the container with that version (this is the default behaviour):

```bash
./mega-linter-runner.sh -e ENABLE_LINTERS=BASH_SHELLCHECK -v -f documentation
```

The following would do the same. It shows that [`mega-linter-runner.sh`][script]
will automatically pass further all the variables that are recognised by the
MegaLinter, as long as they are present in the environment. In the example, the
variable `ENABLE_LINTERS` is set outside of the script, and the script will pass
it into the container automatically:

```bash
ENABLE_LINTERS=BASH_SHELLCHECK ./mega-linter-runner.sh -v -f documentation
```

  [script]: ./mega-linter-runner.sh

### Action

The following step snippet would validate your entire project and, when called
from within a PR, generate a comment with the summary linting results. Consult
the [YAML][action] for more details about the inputs supported by the action.

```yaml
      - name: MegaLinter
        uses: efrecon/mega-linter-runner@main
        env:
          VALIDATE_ALL_CODEBASE: true
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          flavor: documentation
```

  [action]: ./action.yml
