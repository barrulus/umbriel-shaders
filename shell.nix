{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = with pkgs; [ cmake ninja pkg-config nlohmann_json tomlplusplus openssl curl python3 ];
}
