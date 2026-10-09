# Two agents whose uids are equal modulo 256 would get the same namespace
# subnet; the build must refuse that rather than route one agent's traffic into
# the other's namespace. Evaluated only, so it fails at evaluation time.
{
  self,
  home-manager,
  nixpkgs,
}:
let
  inherit (nixpkgs) lib;

  agent = uid: {
    inherit uid;
    repo.url = "git@github.com:acme/widget.git";
    git = {
      userName = "Jane Doe";
      userEmail = "jane+acme@example.com";
    };
    githubTokenFile = "/run/secrets/gh-acme";
    githubTokenEnvFile = "/run/secrets/claude-acme.env";
    network.namespace.enable = true;
  };

  box = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      home-manager.nixosModules.home-manager
      self.nixosModules.agents
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        operator.agents = {
          claude-acme = agent 1001;
          claude-globex = agent 1257;
        };
      }
    ];
  };

  failedAssertions = map (a: a.message) (lib.filter (a: !a.assertion) box.config.assertions);
in
assert lib.assertMsg (lib.any (lib.hasInfix "10.233.233.0/30") failedAssertions)
  "expected an assertion naming the shared subnet 10.233.233.0/30, got: ${builtins.toJSON failedAssertions}";
nixpkgs.legacyPackages.x86_64-linux.emptyFile
