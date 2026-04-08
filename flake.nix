{
  outputs =
    {
      self,
      ...
    }@inputs:
    let
      lib-nixpkgs = inputs.introducingbloats.lib.nixpkgs inputs;
    in
    {
      # Google Chrome is x86_64-only on Linux (no aarch64 .deb available)
      packages = lib-nixpkgs.forSystems [ "x86_64-linux" ] (
        { pkgs, ... }:
        let
          versions = builtins.fromJSON (builtins.readFile ./version.json);
          constants = builtins.fromJSON (builtins.readFile ./constants.json);
          mkChrome = channel: pkgs.callPackage ./package.nix { inherit channel; };
          stable = mkChrome "stable";
          beta = mkChrome "beta";
          dev = mkChrome "dev";
          canary = mkChrome "canary";
        in
        {
          default = stable;
          google-chrome-stable = stable;
          google-chrome-beta = beta;
          google-chrome-dev = dev;
          google-chrome-canary = canary;
          chromium-snapshot = pkgs.callPackage ./chromium-package.nix {
            position = versions.snapshot.position;
            hash = versions.snapshot.hash;
            inherit constants;
          };
          updateScript = pkgs.callPackage ./update.nix { };
          bisect = pkgs.callPackage ./bisect.nix { };
        }
      );
    };
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11-small";
    introducingbloats.url = "github:introducingbloats/core.flakes/main";
  };
}
