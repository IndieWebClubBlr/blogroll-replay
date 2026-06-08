{ pkgs, lib }:
let
  logo = pkgs.writeShellScriptBin "logo" ''
    set -euo pipefail
    echo -e "\n$(tput setaf 2)"
    echo feed-repeat | ${pkgs.figlet}/bin/figlet
    echo -e "$(tput sgr0)\n"
  '';
  build = pkgs.writeShellScriptBin "build" ''
    set -euo pipefail
    nix-build nix/release.nix
  '';
  build-static = pkgs.writeShellScriptBin "build-static" ''
    set -euo pipefail
    [[ $# -eq 1 ]] || { echo "Usage: build-static <arch>" >&2; exit 1; }
    nix-build nix/release.nix --arg static true --argstr system "$1-linux"
    # add Nix GC root for static dependencies and build tools
    nix-store --add-root .gcroots/static-deps-$1 \
      --realise `nix-instantiate --argstr system "$1-linux" --quiet --quiet --quiet nix/static-deps.nix` \
      > /dev/null
  '';
  run = pkgs.writeShellScriptBin "run" ''
    set -euo pipefail
    result/bin/feed-repeat --config config.yaml --output-dir output --cache-dir cache | awk '{ print strftime("%Y-%m-%d %H:%M:%S"), $0; }'
  '';
  build-docker = pkgs.writeShellScriptBin "build-docker" ''
    set -euo pipefail
    [[ $# -eq 1 ]] || { echo "Usage: build-docker <arch>" >&2; exit 1; }
    nix-build nix/docker.nix --argstr system "$1-linux"
  '';
  module-doc =
    serviceName:
    pkgs.nixosOptionsDoc {
      options =
        (pkgs.lib.evalModules {
          modules = [ (import ./module-options.nix { inherit pkgs serviceName; }) ];
        }).options;
    };
  gen-nix-module-docs = pkgs.writeShellScriptBin "gen-nix-module-docs" ''
    set -euo pipefail;
    cp ${(module-doc "feed-repeat").optionsCommonMark} docs/nix-module-options.md
    chmod +w docs/nix-module-options.md
    L=$(grep -n -m 1 "feed-repeat" docs/nix-module-options.md | cut -d ':' -f 1)
    M=$((L-1))
    sed -i "1,''${M}d" docs/nix-module-options.md
    sed -i '1i # feed-repeat NixOS Module Options\n' docs/nix-module-options.md
  '';
in
[
  logo
  build
  build-static
  build-docker
  gen-nix-module-docs
  run
]
