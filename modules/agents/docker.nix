# Rootless Docker for the one agent that enables it. nixpkgs'
# virtualisation.docker.rootless is host-global (a single user service and
# socket), so at most one agent per host can use it this way. Per-agent Docker
# would need a custom per-user daemon; this is the honest limit for now.
{ config, pkgs, lib, ... }:
let
  dockerAgents = lib.filterAttrs (_: a: a.enable && a.docker.enable) config.operator.agents;
  names = lib.attrNames dockerAgents;
  agent = lib.head (lib.attrValues dockerAgents);
  paths = import ./paths.nix agent;
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.length names <= 1;
          message = "At most one agent per host can enable docker.enable (nixpkgs rootless Docker is host-global). Enabled on: ${lib.concatStringsSep ", " names}.";
        }
      ];
    }

    (lib.mkIf (dockerAgents != { }) {
      # The daemon runs as the agent, so containers get no more access than the
      # agent already has, and the egress rules apply to their traffic. Adding
      # the agent to the docker group would be root-equivalent instead.
      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = false; # It would point at the runtime directory.
        # The socket lives under the agent's home rather than in the runtime
        # directory, because the Claude service's ProtectHome=tmpfs blanks
        # /run/user and the agents would not see it there.
        daemon.settings.hosts = [ "unix://${paths.dockerSocket}" ];
      };

      systemd.user.services.docker = {
        # The service is defined for every user, but only this agent needs a
        # daemon and only it can write the socket directory.
        unitConfig.ConditionUser = lib.mkForce agent.user;
        # The daemon does not create the socket directory, and waiting for
        # systemd-tmpfiles would be a race on the first start after a rebuild.
        serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 700 ${paths.dockerSocketDir}";
      };
    })
  ];
}
