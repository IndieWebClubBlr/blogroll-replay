{ pkgs ? import <nixpkgs> {} }:

let
  ghc = pkgs.haskellPackages.ghcWithPackages (ps: with ps; [
    aeson
    bytestring
    text
    time
    uuid
    yaml
    http-client
    http-conduit
    optparse-applicative
    directory
    filepath
    random
    feed
    hashable
  ]);
  build-script = pkgs.writeScriptBin "build" ''
  #!/bin/sh
  LEVEL=''${1:-0}
    nix-build . --arg optimizationLevel $LEVEL
  '';
  run-script = pkgs.writeScriptBin "run" ''
    #!/bin/sh
    ./result/bin/feed-repeat --config config.yaml --output-dir output --cache-dir cache
  '';
in

pkgs.mkShell {
  buildInputs = [
    build-script
    run-script
    ghc
    pkgs.haskellPackages.hlint
    pkgs.haskellPackages.ormolu
  ];
}
