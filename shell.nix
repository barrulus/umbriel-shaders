# Development tools only. The installed plugin needs Noctalia and Umbriel.
{ pkgs ? import <nixpkgs> {} }:
pkgs.mkShell {
  packages = with pkgs; [ python3 cmake ninja ];
}
