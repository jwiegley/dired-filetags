{
  description = "dired-filetags.el — tag files in Dired with filetags";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    # The systems with coverage and allocation baselines, and the only
    # ones the flake offers.  x86_64-darwin is left out: it has no
    # baselines, and nixpkgs warns that its support is ending, which
    # `--option abort-on-warn true' (lefthook, CI) turns into an
    # evaluation error for every output of that system.
    flake-utils.lib.eachSystem [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        fs = lib.fileset;
        epkgs = pkgs.emacsPackagesFor pkgs.emacs-nox;

        # Karl Voit's filetags CLI.  dired-filetags asks it for every new
        # file name, and the ERT suite drives the real program, so the
        # checks and the dev shell both need it.
        filetags = pkgs.python3Packages.buildPythonPackage {
          pname = "filetags";
          # pyproject.toml's version.  Upstream tags no releases, and the
          # pinned commit (2026-09-01) comes after that version's.
          version = "2026.06.06.1-unstable-2026-09-01";
          pyproject = false;

          src = pkgs.fetchFromGitHub {
            owner = "novoid";
            repo = "filetags";
            rev = "811c97b8c2805dc9aad5636963d5ffe5bb4a7784";
            hash = "sha256-xLMXO7SsZ7q3kwEg+OhFqwkEpx+gUsidGqWbciT0u1w=";
          };

          # pyproject.toml also lists pyreadline3, a readline for Windows
          # that the program never imports elsewhere, so it is left out.
          dependencies = with pkgs.python3Packages; [
            colorama
            clint
          ];

          # The program is a single script; install it directly.  The
          # fixup phase patches its shebang and wraps it so that colorama
          # and clint are found.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp -p filetags/__init__.py $out/bin/filetags
            chmod +x $out/bin/filetags
            runHook postInstall
          '';

          # Prove the wrapped program starts inside the build sandbox.
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            $out/bin/filetags --version
            runHook postInstallCheck
          '';

          meta = {
            homepage = "https://github.com/novoid/filetags";
            description = "Management of simple tags within file names";
            # pyproject.toml: GPL-3.0-or-later.
            license = lib.licenses.gpl3Plus;
            maintainers = with lib.maintainers; [ jwiegley ];
            mainProgram = "filetags";
          };
        };

        emacsWithPkgs = epkgs.emacsWithPackages (epkgs: [
          epkgs.package-lint
          epkgs.format-all
          epkgs.relint
          # Lets the two dired-subtree tests run instead of skipping.
          epkgs.dired-subtree
          # Line coverage for scripts/coverage.sh.
          epkgs.undercover
        ]);

        # filetags' own dependencies, so that the fuzz tests can load the
        # pinned filetags source and compare the parser with its
        # FILE_WITH_TAGS_REGEX.
        fuzzPython = pkgs.python3.withPackages (ps: [
          ps.colorama
          ps.clint
        ]);

        # The environment every check, app and the dev shell share.  The
        # system is the key of the coverage and allocation baselines.
        toolEnv = {
          DIRED_FILETAGS_SYSTEM = system;
          DIRED_FILETAGS_PYTHON = "${fuzzPython}/bin/python3";
          DIRED_FILETAGS_PY = "${filetags.src}/filetags/__init__.py";
        };

        # What the suite and the reports call: Emacs, filetags, and git
        # for the VC tests.
        testTools = [
          emacsWithPkgs
          filetags
          pkgs.gitMinimal
        ];

        # rumdl links a jemalloc of its own, which fixes the largest page
        # size it can handle when it is built.  nixpkgs builds
        # aarch64-linux on kernels with 4 KiB pages, and that rumdl
        # aborts ("Unsupported system page size") on a kernel with 16 KiB
        # pages, such as Asahi Linux's.  Built for 64 KiB pages, as
        # nixpkgs' own jemalloc is on aarch64-linux, it runs on 4, 16 and
        # 64 KiB kernels alike.
        rumdl =
          if pkgs.stdenv.hostPlatform.isAarch64 && pkgs.stdenv.hostPlatform.isLinux then
            pkgs.rumdl.overrideAttrs (old: {
              env = (old.env or { }) // {
                JEMALLOC_SYS_WITH_LG_PAGE = "16";
              };
            })
          else
            pkgs.rumdl;

        # Every tool a target calls.  bash is 5.x: scripts/lint.sh and
        # scripts/format-all.sh need bash 4.4 or later, which macOS's
        # /bin/bash is not.
        devTools = testTools ++ [
          pkgs.bashInteractive
          pkgs.lefthook
          pkgs.lcov
          pkgs.nixfmt
          pkgs.statix
          pkgs.deadnix
          pkgs.shellcheck
          pkgs.shfmt
          pkgs.prettier
          pkgs.yamllint
          pkgs.actionlint
          pkgs.zizmor
          rumdl
        ];

        # The sources, each derivation taking only the files it reads, so
        # that an edit to the README, CI or lefthook rebuilds none of the
        # package, the suite or the reports, and a baseline edit rebuilds
        # only the two cheap gates.
        #
        # The whole tree, for the checks that look at every file: format,
        # lint and the apps.
        src = builtins.path {
          path = ./.;
          name = "dired-filetags-el-src";
          filter =
            path: _:
            let
              baseName = builtins.baseNameOf path;
            in
            baseName != ".git"
            && baseName != ".direnv"
            && baseName != "result"
            && baseName != "reports"
            && !(lib.hasPrefix "result-" baseName)
            # Emacs's lock files, symbolic links to nothing.
            && !(lib.hasPrefix ".#" baseName)
            && !(lib.hasSuffix ".elc" baseName);
        };
        # Every Emacs Lisp file, in the root and in scripts/, and the
        # scripts: the suite, the leak check, the fuzzer, the reports and
        # the Emacs Lisp linters, which check every *.el file.
        lispFiles = fs.unions [
          (fs.fileFilter (f: f.type == "regular" && f.hasExt "el") ./.)
          (fs.fileFilter (f: f.type == "regular" && f.hasExt "sh") ./scripts)
        ];
        lispSrc = fs.toSource {
          root = ./.;
          fileset = lispFiles;
        };
        # The same and the baselines, for the gates.
        gateSrc = fs.toSource {
          root = ./.;
          fileset = fs.union lispFiles ./baselines;
        };

        # SCRIPT runs in a copy of SRC, with TOOLS and stdenv's userland on
        # PATH, the shared environment, and a fresh HOME and TMPDIR.  With
        # workTree, the copy is made a git work tree first, so that
        # scripts/lint.sh and scripts/format-all.sh list its files as they
        # would in a checkout, and `lefthook validate' works.
        # A report writes $out itself; any other check leaves an empty
        # file.
        mkCheck =
          name:
          {
            src,
            tools,
            workTree ? false,
          }:
          script:
          pkgs.stdenv.mkDerivation {
            inherit name src;
            env = toolEnv;
            nativeBuildInputs = tools;
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              runHook preBuild
              export HOME=$(mktemp -d)
              export TMPDIR=$(mktemp -d)
              ${lib.optionalString workTree "git init -q"}
              ${script}
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              [ -e "$out" ] || touch "$out"
              runHook postInstall
            '';
          };
        onLisp = {
          src = lispSrc;
          tools = testTools;
        };

        # An app: TEXT runs in the root of the caller's checkout, $root,
        # with the checks' tools and environment.  The root is PRJ_ROOT,
        # which `nix fmt' sets to the flake's directory, else the nearest
        # directory at or above the current one that holds
        # dired-filetags.el and flake.nix, so an app runs from any
        # subdirectory, and fails outside a checkout.  GNU coreutils
        # and friends come first on PATH, as in the checks and the dev
        # shell, so the scripts never meet macOS's BSD userland.
        mkTool =
          name: description: text:
          pkgs.writeShellApplication {
            inherit name;
            text = ''
              is_root() { [[ -f $1/dired-filetags.el && -f $1/flake.nix ]]; }
              root=''${PRJ_ROOT:-}
              if [[ -z $root ]] || ! is_root "$root"; then
                root=$PWD
                until is_root "$root"; do
                  if [[ $root == / ]]; then
                    echo "${name}: run this inside the dired-filetags checkout" >&2
                    exit 2
                  fi
                  root=$(dirname "$root")
                done
              fi
              cd "$root"
              ${text}
            '';
            runtimeInputs = [
              pkgs.coreutils
              pkgs.findutils
              pkgs.diffutils
              pkgs.gnused
              pkgs.gawk
              pkgs.gnugrep
            ]
            ++ devTools;
            runtimeEnv = toolEnv;
            meta.description = description;
          };

        bench = "emacs -Q --batch -L . -l scripts/bench.el -f dired-filetags-bench-batch";

        # Loads the suite and scripts/ert-skip-budget.el, which fails a
        # run of it, as a run that went wrong (exit status 2, from
        # `ert-run-tests-batch-and-exit' and from the leak check alike),
        # when more than one test skipped.  Wherever the flake runs the
        # suite, filetags, git, mkfifo and dired-subtree are on PATH, so
        # the only test that may skip is the one of the two
        # case-sensitivity tests that does not fit the file system.  A
        # missing tool skips dozens, which ERT would otherwise count as a
        # pass.  lefthook and scripts/coverage.sh load the same file.
        ertLoad = "emacs --batch -Q -L . --eval '(setq load-prefer-newer t)' -l ert -l dired-filetags-test.el -l scripts/ert-skip-budget.el";

        # The package, as nixpkgs builds packages from MELPA: installed with
        # package.el into site-lisp/elpa, with dired-filetags-autoloads.el,
        # byte-compiled and native-compiled by the package set's own Emacs
        # (none of the dev tools is on load-path), every warning an error.
        # Before that, preBuild compiles it with `byte-compile-warnings'
        # `all' rather than the default t, the project's setting.
        package = epkgs.melpaBuild {
          pname = "dired-filetags";
          # dired-filetags.el's Version header.
          version = "0.1.0";
          src = fs.toSource {
            root = ./.;
            fileset = ./dired-filetags.el;
          };
          turnCompilationWarningToError = true;
          preBuild = ''
            emacs --batch -Q -L . \
              --eval '(setq byte-compile-error-on-warn t byte-compile-warnings (quote all))' \
              -f batch-byte-compile dired-filetags.el
            rm dired-filetags.elc
          '';
          meta = {
            description = "Tag files in Dired with filetags";
            homepage = "https://github.com/jwiegley/dired-filetags";
            license = lib.licenses.bsd3;
            maintainers = with lib.maintainers; [ jwiegley ];
          };
        };

        # The reports never fail on a regression: the gates below are
        # separate checks that read them, so a failed gate still leaves
        # a report to look at, and each report is built only once.
        coverageReport = mkCheck "dired-filetags-coverage" (
          onLisp // { tools = testTools ++ [ pkgs.lcov ]; }
        ) "bash scripts/coverage.sh --no-gate --out $out";

        # A reference profile, not a measurement of the machine that reads
        # it.  It is measured once, in the build sandbox of whichever
        # machine builds it (a remote builder, a CI runner, or this one,
        # under the load of other builds), and then cached by input hash:
        # a later build returns that measurement, possibly from another
        # machine's store, without measuring again.  Its allocation counts
        # hold on every machine of the system, and checks.perf gates them.
        # Its timings and profiles describe only the build it came from,
        # as PROVENANCE.txt and the head of perf.txt say.  `nix run .#perf'
        # measures the machine it runs on.  Nix is asked to build it here
        # rather than remotely or from a cache, but a builder may still
        # substitute it (always-allow-substitutes).
        provenance = ''
          REFERENCE PROFILE, not a measurement of the machine reading it.
          It was measured once, in a Nix build sandbox on the host named
          below (as the sandbox reports it; a Linux sandbox says localhost),
          possibly under the load of other builds, and has been cached by
          input hash since: `nix build .#perf-report' returns this same
          measurement, perhaps from another machine's store or a cache.  Its
          allocation counts hold on any ${system} machine with this Emacs;
          its timings and profiles describe only that build.  To measure
          this machine now, run `nix run .#perf' in the checkout.
        '';
        perfReport =
          (mkCheck "dired-filetags-perf-reference" onLisp ''
            ${bench} --report $out --samples 3
            {
              cat <<'EOF'
            ${provenance}
            EOF
              echo "Built on host $(uname -n) at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
            } >"$out/PROVENANCE.txt"
            { cat "$out/PROVENANCE.txt"; echo; cat "$out/perf.txt"; } >perf.txt
            mv perf.txt "$out/perf.txt"
          '').overrideAttrs
            {
              preferLocalBuild = true;
              allowSubstitutes = false;
              meta.description = "Reference performance profile from the Nix build sandbox (cached; nix run .#perf measures this machine)";
            };

        tools = {
          # format and lint go back to the caller's directory, which the
          # cd to the root left in OLDPWD, since they read a relative PATH
          # or FILE from there, and find the root themselves.
          format = mkTool "dired-filetags-format" "Format every file, or the PATHs" ''
            cd "$OLDPWD"
            exec bash "$root/scripts/format-all.sh" "$@"
          '';
          lint = mkTool "dired-filetags-lint" "Run every linter, or the CHECKs" ''
            cd "$OLDPWD"
            exec bash "$root/scripts/lint.sh" "$@"
          '';
          test = mkTool "dired-filetags-test" "Run the ERT suite (optional REGEXP)" ''
            SELECTOR="''${1:-}" exec ${ertLoad} \
              --eval '(ert-run-tests-batch-and-exit (let ((s (getenv "SELECTOR"))) (if (member s (quote (nil ""))) t s)))'
          '';
          coverage = mkTool "dired-filetags-coverage" "Coverage report and gate" ''
            exec bash scripts/coverage.sh "$@"
          '';
          perf = mkTool "dired-filetags-perf" "Measure this machine now: profiling report and gates" ''
            exec ${bench} --report reports/perf --gate all "$@"
          '';
          fuzz = mkTool "dired-filetags-fuzz" "Long fuzz runs" ''
            exec bash scripts/fuzz.sh "$@"
          '';
          update-baselines = mkTool "dired-filetags-update-baselines" "Record this machine's baselines" ''
            bash scripts/coverage.sh --update
            ${bench} --update
            git --no-pager diff --stat -- baselines/
          '';
        };

        devShell = pkgs.mkShell {
          packages = devTools;
          env = toolEnv;
          shellHook = "lefthook install";
        };

        # The Emacs Lisp linters look only at *.el files and scripts/.
        lintCheck =
          n:
          mkCheck "dired-filetags-${n}" {
            src = lispSrc;
            tools = [
              emacsWithPkgs
              pkgs.gitMinimal
            ];
            workTree = true;
          } "bash scripts/lint.sh ${n}";

        # The gates read baselines/ from their source, which always holds
        # it: coverage.sh and bench.el fail when a baseline file, or this
        # system's entry, is missing or was recorded with another Emacs.
        onGate = {
          src = gateSrc;
          tools = [ emacsWithPkgs ];
        };
        onTree = {
          inherit src;
          tools = devTools;
          workTree = true;
        };
      in
      {
        packages = {
          default = package;
          inherit filetags;
          coverage = coverageReport;
          perf-report = perfReport;
        };

        checks = {
          # The package builds with no warnings.
          build = package;

          # The suite drives the real filetags CLI, and git for the VC tests.
          ert = mkCheck "dired-filetags-ert" onLisp "${ertLoad} -f ert-run-tests-batch-and-exit";

          # The suite again, failing on any buffer, process, timer, hook,
          # overlay, temporary file or global state a test leaves behind.
          leak =
            mkCheck "dired-filetags-leak" onLisp
              "${ertLoad} -l scripts/leak-check.el -f dired-filetags-leak-check-batch-and-exit";

          # Property tests with the fixed seed and 1000 iterations.
          fuzz = mkCheck "dired-filetags-fuzz" onLisp "bash scripts/fuzz.sh --check";

          # Line coverage against baselines/coverage.txt.
          coverage =
            mkCheck "dired-filetags-coverage-gate" onGate
              "bash scripts/coverage.sh --gate ${coverageReport}";

          # Allocations against baselines/perf.eld; timings only report,
          # since a builder is never the machine a timing baseline is for.
          perf =
            mkCheck "dired-filetags-perf-gate" onGate
              "${bench} --results ${perfReport}/perf.eld --gate alloc";

          # Every file is formatted.
          format = mkCheck "dired-filetags-format" onTree "bash scripts/format-all.sh --check";

          # The linters for the files that are not Emacs Lisp, and
          # check-declare.
          lint =
            mkCheck "dired-filetags-lint" onTree
              "bash scripts/lint.sh check-declare nix shell yaml actions markdown";

          # Every app, the formatter and the dev shell build ($out links
          # to each), and the apps run as a user without the dev shell
          # would run them: from a subdirectory of the checkout, with
          # nothing on PATH but /usr/bin and /bin.  Each runs in a cheap
          # mode: format on files of each kind (named relative to
          # scripts/, where it runs; two Emacs Lisp files, since a
          # scratch-file bug in check-format.sh shows only from the
          # second), lint's nix, shell and yaml checks, the oracle
          # tests, and the usage of coverage and fuzz.  perf would gate
          # its timings against the build host's own baseline while
          # other builds load it, and update-baselines would rewrite
          # baselines/, so those two are only built.  On macOS,
          # check-format.sh also runs by itself with only the system's
          # BSD userland and Emacs on PATH, which the apps never meet,
          # as they put GNU coreutils first.
          apps =
            mkCheck "dired-filetags-apps"
              {
                inherit src;
                tools = [ pkgs.gitMinimal ];
                workTree = true;
              }
              ''
                mkdir -p $out
                ${lib.concatStrings (
                  lib.mapAttrsToList (name: drv: "ln -s ${drv} $out/${name}\n") (
                    tools
                    // {
                      formatter = tools.format;
                      inherit devShell;
                    }
                  )
                )}
                as_user() { env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH=/usr/bin:/bin "$@"; }
                git add -A
                cd scripts
                as_user ${lib.getExe tools.format} --check \
                  format-setup.el compile.el ../flake.nix fuzz.sh ../lefthook.yml
                ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
                  env -i HOME="$HOME" TMPDIR="$TMPDIR" \
                    PATH=/usr/bin:/bin:${lib.getBin emacsWithPkgs}/bin \
                    ./check-format.sh format-setup.el compile.el
                ''}
                as_user ${lib.getExe tools.lint} nix shell yaml
                as_user ${lib.getExe tools.test} '^dired-filetags-oracle-'
                as_user ${lib.getExe tools.coverage} --help >/dev/null
                as_user ${lib.getExe tools.fuzz} --help >/dev/null
                cd ..
                # No app may change or delete a file, nor leave one behind,
                # even an ignored one: compare the tree with the index.
                { git diff --name-only; git ls-files --others; } >"$TMPDIR/changed"
                if [ -s "$TMPDIR/changed" ]; then
                  echo "an app changed or left behind these files:"
                  cat "$TMPDIR/changed"
                  exit 1
                fi
              '';
        }
        # One check per Emacs Lisp linter, each with every warning an
        # error.
        // lib.genAttrs [
          "byte-compile"
          "native-compile"
          "package-lint"
          "checkdoc"
          "relint"
        ] lintCheck;

        apps = lib.mapAttrs (_: drv: {
          type = "app";
          program = lib.getExe drv;
          meta.description = drv.meta.description;
        }) tools;

        formatter = tools.format;

        devShells.default = devShell;
      }
    );
}
