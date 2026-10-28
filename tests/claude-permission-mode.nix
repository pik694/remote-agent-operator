# An agent with claudeService.permissionMode starts claude remote-control with
# that --permission-mode, so the sessions it creates begin in it; without one,
# no flag is passed and the agent's settings files decide. Evaluated only, so
# it fails at evaluation time.
{
  self,
  home-manager,
  nixpkgs,
}:
let
  inherit (nixpkgs) lib;

  startScript =
    permissionMode:
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
                  inherit permissionMode;
                };
              };
            }
          ];
        }).config;
    in
    config.systemd.services.claude-acme.serviceConfig.ExecStart.text;

  auto = startScript "auto";
  unset = startScript null;
in
assert lib.assertMsg (lib.hasInfix "/bin/claude remote-control --spawn worktree --capacity 4 --permission-mode auto\n" auto)
  "the service must pass the agent's permission mode to claude remote-control, got: ${auto}";
assert lib.assertMsg (
  !lib.hasInfix "--permission-mode" unset
) "without a permission mode, claude remote-control must get no --permission-mode, got: ${unset}";
nixpkgs.legacyPackages.x86_64-linux.emptyFile
