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
in

pkgs.stdenv.mkDerivation {
  name = "feed-repeat";
  src = ./.;
  buildInputs = [ ghc ];
  buildPhase = ''
    ghc --make Main.hs -o feed-repeat -O2 -Wall -Werror
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp feed-repeat $out/bin/
  '';
}
