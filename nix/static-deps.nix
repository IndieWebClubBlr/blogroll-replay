{
  compiler ? null,
  system ? builtins.currentSystem,
}:
let
  pkgs = import ./. {
    inherit compiler;
    static = true;
    inherit system;
  };
in
pkgs.feed-repeat.staticDeps
