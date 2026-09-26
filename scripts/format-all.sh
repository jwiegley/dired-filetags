#!/usr/bin/env bash
# Format every file with the tool for its language, or check that it is.
# Usage: format-all.sh [--check] [--staged] [PATH...]
#
#   *.el                   scripts/format.sh (format-all)   scripts/check-format.sh
#   *.nix                  nixfmt                           nixfmt --check
#   *.sh                   shfmt -w -i 2 -ci                shfmt -d -i 2 -ci
#   *.yml, *.yaml, *.md    prettier --write                 prettier --check
#
# A PATH is a file or a directory; a relative one is read from the
# current directory, which may be any directory of the checkout.  A
# directory stands for the files git lists below it, tracked or
# untracked but not ignored; no PATH at all means the whole checkout.
# LICENSE.md is never formatted, since every Markdown formatter would
# collapse the two spaces in its copyright line, and other kinds of
# file are skipped.
#
# --staged says that the PATHs are the files staged for a commit, as the
# pre-commit hook passes them.  If one of them is part of the formatting
# machinery (these scripts, .prettierignore, flake.nix or flake.lock,
# which pins the formatters), every file in git's index is taken
# instead, since such a change can alter the verdict on any file.
#
# --check writes nothing.  It shows each file that is not formatted, and
# exits 1 if there is one.  Otherwise the files are rewritten in place,
# and each one that changed is named.  The exit status is 2 for a usage
# error or a missing tool.
set -euo pipefail
if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  echo "format-all.sh: needs bash 4.4 or later; this is ${BASH_VERSION}" >&2
  exit 2
fi
shopt -s lastpipe

usage() {
  echo "Usage: $0 [--check] [--staged] [PATH...]"
}

# Files that decide how every other file is formatted.
MACHINERY=(scripts/format-all.sh scripts/format.sh scripts/check-format.sh
  scripts/format-setup.el .prettierignore flake.nix flake.lock)

check=false
staged=false
paths=()
for arg in "$@"; do
  case $arg in
    --check) check=true ;;
    --staged) staged=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      echo "format-all.sh: unknown option: ${arg}" >&2
      usage >&2
      exit 2
      ;;
    *) paths+=("$arg") ;;
  esac
done

caller=$PWD
here=$(dirname -- "${BASH_SOURCE[0]}")
root=$(cd -- "${here}/.." && pwd -P)
cd -- "$root"

# Print PATH, relative to the caller's directory, as a path relative to
# the project root.  Exit 2 if there is no such file, or if it lies
# outside the project.  It runs in a command substitution, where exit
# leaves only the subshell, and inherit_errexit keeps set -e there.
shopt -s inherit_errexit
relative() {
  local path=$1 abs dir
  if [[ $path != /* ]]; then
    path=${caller}/${path}
  fi
  if [[ -d $path ]]; then
    abs=$(cd -- "$path" && pwd -P)
  elif [[ -e $path ]]; then
    dir=$(dirname -- "$path")
    dir=$(cd -- "$dir" && pwd -P)
    abs=${dir}/${path##*/}
  else
    echo "format-all.sh: no such file or directory: $1" >&2
    exit 2
  fi
  case $abs in
    "$root") echo . ;;
    "$root"/*) echo "${abs#"$root"/}" ;;
    *)
      echo "format-all.sh: $1 is outside the project, ${root}" >&2
      exit 2
      ;;
  esac
}

for i in "${!paths[@]}"; do
  paths[i]=$(relative "${paths[i]}")
done
if $staged; then
  for path in "${paths[@]}"; do
    if [[ " ${MACHINERY[*]} " == *" ${path} "* ]]; then
      echo "format-all.sh: ${path} is part of the formatting machinery," \
        "so every file in the index is checked"
      paths=()
      git ls-files -z --cached | LC_ALL=C sort -z |
        while IFS= read -r -d '' file; do
          paths+=("$file")
        done
      break
    fi
  done
elif ((${#paths[@]} == 0)); then
  paths=(.)
fi

# Collect the files to format, each once, in the order found.
declare -A seen=()
files=()
add_file() {
  local file=${1#./}
  if [[ -z ${seen[$file]:-} ]]; then
    seen[$file]=1
    files+=("$file")
  fi
}
for path in "${paths[@]}"; do
  if [[ -d $path ]]; then
    inside=$(git -C "$path" rev-parse --is-inside-work-tree 2>/dev/null || echo false)
    if [[ $inside != true ]]; then
      echo "format-all.sh: ${path} is not in a git work tree, and git lists" >&2
      echo "the files below a directory; run \`git init' first" >&2
      exit 2
    fi
    git ls-files -z --cached --others --exclude-standard -- "$path" |
      LC_ALL=C sort -z |
      while IFS= read -r -d '' file; do
        # A file deleted from the work tree is still in the index.
        if [[ -f $file ]]; then
          add_file "$file"
        fi
      done
  elif [[ -f $path ]]; then
    add_file "$path"
  fi
done

el=() nix=() sh=() prettier=()
for file in "${files[@]}"; do
  if [[ ${file##*/} == LICENSE.md ]]; then
    continue
  fi
  case $file in
    *.el) el+=("$file") ;;
    *.nix) nix+=("$file") ;;
    *.sh) sh+=("$file") ;;
    *.yml | *.yaml | *.md) prettier+=("$file") ;;
    *) ;;
  esac
done

# TOOL formats the files of one language; it must be on PATH if there
# are any.
need() {
  local tool=$1
  shift
  if (($# > 0)) && ! command -v "$tool" >/dev/null; then
    echo "format-all.sh: ${tool} is not on PATH" >&2
    exit 2
  fi
}
need emacs "${el[@]}"
need nixfmt "${nix[@]}"
need shfmt "${sh[@]}"
need prettier "${prettier[@]}"

# The shfmt style: two-space indents, with case patterns indented.
SHFMT=(shfmt -i 2 -ci)

status=0
if $check; then
  if ((${#el[@]} > 0)); then
    bash scripts/check-format.sh "${el[@]}" || status=1
  fi
  if ((${#nix[@]} > 0)); then
    nixfmt --check -- "${nix[@]}" || status=1
  fi
  if ((${#sh[@]} > 0)); then
    "${SHFMT[@]}" -d -- "${sh[@]}" || status=1
  fi
  if ((${#prettier[@]} > 0)); then
    prettier --check --log-level warn -- "${prettier[@]}" || status=1
  fi
  if ((status != 0)); then
    echo "format-all.sh: files above are not formatted; run scripts/format-all.sh"
  else
    echo "format-all.sh: ${#el[@]} Emacs Lisp, ${#nix[@]} Nix, ${#sh[@]} shell and" \
      "${#prettier[@]} YAML or Markdown files are formatted"
  fi
  exit "$status"
fi

# Format in place, then name the files whose contents changed.
all=("${el[@]}" "${nix[@]}" "${sh[@]}" "${prettier[@]}")
declare -A before=()
for file in "${all[@]}"; do
  before[$file]=$(cksum <"$file")
done
if ((${#el[@]} > 0)); then
  bash scripts/format.sh "${el[@]}" >/dev/null || status=1
fi
if ((${#nix[@]} > 0)); then
  nixfmt -- "${nix[@]}" || status=1
fi
if ((${#sh[@]} > 0)); then
  "${SHFMT[@]}" -w -- "${sh[@]}" || status=1
fi
if ((${#prettier[@]} > 0)); then
  prettier --write --log-level warn -- "${prettier[@]}" || status=1
fi
changed=0
for file in "${all[@]}"; do
  after=$(cksum <"$file")
  if [[ $after != "${before[$file]}" ]]; then
    echo "Formatted: ${file}"
    changed=$((changed + 1))
  fi
done
if ((status != 0)); then
  echo "format-all.sh: a formatter failed" >&2
  exit 1
fi
echo "format-all.sh: ${changed} of ${#all[@]} files changed"
