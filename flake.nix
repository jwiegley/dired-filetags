{
  description = "dired-filetags.el — tag files in Dired with filetags";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Karl Voit's filetags CLI.  dired-filetags asks it for every new
        # file name, and the ERT suite drives the real program, so the
        # checks and the dev shell both need it.
        filetags = pkgs.python3Packages.buildPythonPackage {
          pname = "filetags";
          version = "811c97b8";
          pyproject = false;

          src = pkgs.fetchFromGitHub {
            owner = "novoid";
            repo = "filetags";
            rev = "811c97b8c2805dc9aad5636963d5ffe5bb4a7784";
            hash = "sha256-xLMXO7SsZ7q3kwEg+OhFqwkEpx+gUsidGqWbciT0u1w=";
          };

          propagatedBuildInputs = with pkgs.python3Packages; [
            colorama
            clint
          ];

          # The program is a single script; install it directly.  The
          # fixup phase patches its shebang and wraps it so that colorama
          # and clint are found.
          installPhase = ''
            mkdir -p $out/bin
            cp -p filetags/__init__.py $out/bin/filetags
            chmod +x $out/bin/filetags
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
            license = pkgs.lib.licenses.gpl3;
            maintainers = with pkgs.lib.maintainers; [ jwiegley ];
            mainProgram = "filetags";
          };
        };

        emacsWithPkgs = (pkgs.emacsPackagesFor pkgs.emacs-nox).emacsWithPackages (epkgs: [
          epkgs.package-lint
          epkgs.format-all
          epkgs.relint
          # Lets the two dired-subtree tests run instead of skipping.
          epkgs.dired-subtree
        ]);

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
            && !(pkgs.lib.hasPrefix "result-" baseName)
            && !(pkgs.lib.hasSuffix ".elc" baseName);
        };

        # A check that runs SCRIPT in a copy of the source, with Emacs and
        # EXTRAINPUTS on PATH and a fresh, writable HOME and TMPDIR.
        mkCheck =
          name: extraInputs: script:
          pkgs.stdenv.mkDerivation {
            inherit name src;
            nativeBuildInputs = [ emacsWithPkgs ] ++ extraInputs;
            dontConfigure = true;
            buildPhase = ''
              export HOME=$(mktemp -d)
              export TMPDIR=$(mktemp -d)
              ${script}
            '';
            installPhase = "touch $out";
          };
      in
      {
        packages = {
          default = pkgs.stdenv.mkDerivation {
            pname = "dired-filetags-el";
            version = "0.1.0";
            inherit src;
            nativeBuildInputs = [ emacsWithPkgs ];
            buildPhase = ''
              emacs --batch -L . -f batch-byte-compile dired-filetags.el
            '';
            installPhase = ''
              mkdir -p $out/share/emacs/site-lisp
              cp dired-filetags.el dired-filetags.elc $out/share/emacs/site-lisp/
            '';
            meta = {
              description = "Tag files in Dired with filetags";
              license = pkgs.lib.licenses.bsd3;
            };
          };

          inherit filetags;
        };

        checks = {
          # The suite drives the real filetags CLI, and git for the VC tests
          ert =
            mkCheck "dired-filetags-ert"
              [
                filetags
                pkgs.gitMinimal
              ]
              ''
                emacs --batch -Q -L . --eval '(setq load-prefer-newer t)' \
                  -l ert -l dired-filetags-test.el -f ert-run-tests-batch-and-exit
              '';

          # Byte-compile with all warnings treated as errors
          byte-compile = mkCheck "dired-filetags-byte-compile" [ ] ''
            emacs --batch -L . \
              --eval '(setq load-prefer-newer t byte-compile-error-on-warn t)' \
              -f batch-byte-compile dired-filetags.el dired-filetags-test.el
          '';

          # Package header and dependency lint
          package-lint = mkCheck "dired-filetags-package-lint" [ ] ''
            emacs --batch -L . \
              -l package-lint \
              -f package-lint-batch-and-exit dired-filetags.el
          '';

          # Docstring convention check
          checkdoc = mkCheck "dired-filetags-checkdoc" [ ] ''
            emacs --batch -L . \
              -l ${./scripts/run-checkdoc.el} dired-filetags.el dired-filetags-test.el
          '';

          # Regexp lint
          relint = mkCheck "dired-filetags-relint" [ ] ''
            emacs --batch -L . \
              -l relint \
              -f relint-batch dired-filetags.el dired-filetags-test.el
          '';

          # Formatting matches format-all.  Run from the source tree, so
          # the script finds scripts/format-setup.el, and through bash,
          # as its /usr/bin/env shebang does not resolve in the Linux
          # sandbox.
          format = mkCheck "dired-filetags-format" [ ] ''
            bash scripts/check-format.sh dired-filetags.el dired-filetags-test.el
          '';
        };

        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            emacsWithPkgs
            filetags
            pkgs.lefthook
          ];
          shellHook = ''
            lefthook install
          '';
        };
      }
    );
}
