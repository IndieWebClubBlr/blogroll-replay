{
  sources ? import ./sources.nix,
  nixpkgs ? sources.nixpkgs,
  system,
  compiler,
  static ? false,
  devTools ? true,
}:
import nixpkgs {
  inherit system;
  config = { };
  overlays = import ./overlays.nix { inherit sources compiler static devTools; };
}
