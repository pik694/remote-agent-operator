{
  description = "Reusable NixOS modules for agent operator boxes (Claude Code remote-control as per-user systemd services)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    claude-code = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      claude-code,
      ...
    }:
    {
      # The agent accounts on their own, for a fleet that already has a base
      # profile of its own. It needs home-manager and a secret store wired up
      # by the importing configuration.
      nixosModules.agents =
        { pkgs, lib, ... }:
        {
          imports = [ ./modules/agents ];
          operator.claudePackage = lib.mkDefault claude-code.packages.${pkgs.stdenv.hostPlatform.system}.default;
        };

      # A complete one-machine box: the agents plus admin access, networking
      # and Nix settings.
      nixosModules.standalone = {
        imports = [
          ./modules/standalone
          self.nixosModules.agents
        ];
      };

      nixosModules.default = self.nixosModules.standalone;

      # A complete box built only from the exported module, with placeholder
      # hardware and no secret store. It is the worked example a downstream
      # flake copies, and the CI check below builds it.
      nixosConfigurations.example = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          home-manager.nixosModules.home-manager
          self.nixosModules.standalone
          ./examples/single-box/configuration.nix
        ];
      };

      # `nix flake check` builds this in Linux CI (the operator boxes are
      # x86_64-linux), proving the exported module still composes into a
      # complete, buildable system.
      checks.x86_64-linux = {
        example = self.nixosConfigurations.example.config.system.build.toplevel;
        network-namespace = nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest (
          import ./tests/network-namespace.nix { inherit self home-manager; }
        );
        network-namespace-subnets = import ./tests/network-namespace-subnets.nix {
          inherit self home-manager nixpkgs;
        };
      };
    };
}
