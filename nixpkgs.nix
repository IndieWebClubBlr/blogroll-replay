let
  rev = "2bfc080955153be0be56724be6fa5477b4eefabb";
  sha256 = "1n2md3jngcw5mlgscbdsvlx83phzsby4a1sigsh4710nbkkf1cfb";
in
builtins.fetchTarball {
  url = "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz";
  inherit sha256;
}
