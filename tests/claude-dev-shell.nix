# An agent with claudeService.devShell runs claude remote-control inside that
# devShell of its checkout's flake, so the sessions it starts inherit the
# repository's toolchain; without it, claude starts directly as before.
# Evaluated only, so it fails at evaluation time.
{
  self,
  home-manager,
  nixpkgs,
}:
let
  inherit (nixpkgs) lib;

  startScript =
    devShell:
    let
      config =
        (lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            home-manager.nixosModules.home-manager
            self.nixosModules.agents
            {
              boot.isContainer = true;
              system.stateVersion = "26.05";
              operator.agents.claude-acme = {
                uid = 1001;
                repo.url = "git@github.com:acme/widget.git";
                git = {
                  userName = "Jane Doe";
                  userEmail = "jane+acme@example.com";
                };
                githubTokenFile = "/run/secrets/gh-acme";
                githubTokenEnvFile = "/run/secrets/claude-acme.env";
                claudeService = {
                  enable = true;
                  inherit devShell;
                };
              };
            }
          ];
        }).config;
    in
    config.systemd.services.claude-acme.serviceConfig.ExecStart.text;

  inDevShell = startScript "agent";
  direct = startScript null;
in
assert lib.assertMsg
  (lib.hasInfix "/bin/nix develop '/home/claude-acme/widget#agent' --command " inDevShell)
  "the service must start claude remote-control inside the checkout's agent devShell, got: ${inDevShell}";
assert lib.assertMsg (
  lib.hasInfix "--command /nix/store/" inDevShell
  && lib.hasInfix "/bin/claude remote-control --spawn worktree" inDevShell
) "nix develop must run claude remote-control itself, got: ${inDevShell}";
assert lib.assertMsg (
  !lib.hasInfix "nix develop" direct
) "without a devShell, claude must start directly, got: ${direct}";
nixpkgs.legacyPackages.x86_64-linux.emptyFile
