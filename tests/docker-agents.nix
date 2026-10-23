# Namespaced agents each get a rootless Docker daemon of their own, listening on
# their own socket, while agents sharing the host's network still share
# nixpkgs' single host-global daemon and so may number at most one. Evaluated
# only, so it fails at evaluation time.
{
  self,
  home-manager,
  nixpkgs,
}:
let
  inherit (nixpkgs) lib;

  agent = uid: namespaced: {
    inherit uid;
    repo.url = "git@github.com:acme/widget.git";
    git = {
      userName = "Jane Doe";
      userEmail = "jane+acme@example.com";
    };
    githubTokenFile = "/run/secrets/gh-${toString uid}";
    githubTokenEnvFile = "/run/secrets/${toString uid}.env";
    docker.enable = true;
    network.namespace.enable = namespaced;
  };

  box =
    agents:
    lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        home-manager.nixosModules.home-manager
        self.nixosModules.agents
        {
          boot.isContainer = true;
          system.stateVersion = "26.05";
          operator.agents = agents;
        }
      ];
    };

  failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);

  namespaced =
    (box {
      claude-acme = agent 1001 true;
      claude-globex = agent 1002 true;
    }).config;

  hostNetwork =
    (box {
      claude-acme = agent 1001 false;
      claude-globex = agent 1002 false;
    }).config;

  listensOnOwnSocket =
    user:
    lib.hasInfix "--host=unix:///home/${user}/.docker/run/docker.sock "
      namespaced.systemd.services."${user}-docker".serviceConfig.ExecStart;
in
assert lib.assertMsg (failedAssertions namespaced == [ ])
  "two namespaced Docker agents must be allowed, got: ${builtins.toJSON (failedAssertions namespaced)}";
assert lib.assertMsg (
  listensOnOwnSocket "claude-acme" && listensOnOwnSocket "claude-globex"
) "each namespaced agent's daemon must listen on that agent's own socket";
assert lib.assertMsg (
  namespaced.systemd.services.claude-acme-docker.serviceConfig.User == "claude-acme"
  && namespaced.systemd.services.claude-globex-docker.serviceConfig.User == "claude-globex"
) "each namespaced agent's daemon must run as that agent";
assert lib.assertMsg (
  !namespaced.systemd.user.services.docker.enable
) "with only namespaced agents, the host-global user daemon must stay off";
assert lib.assertMsg
  (lib.any (lib.hasInfix "claude-acme, claude-globex") (failedAssertions hostNetwork))
  "expected an assertion naming both host-network Docker agents, got: ${builtins.toJSON (failedAssertions hostNetwork)}";
nixpkgs.legacyPackages.x86_64-linux.emptyFile
