# Rootless Docker for the agents that enable it.
#
# An agent with network.namespace gets its own rootless daemon as a system
# service in its namespace, `<user>-docker`: a user service can't join a
# namespace, and a daemon left on the host publishes container ports where the
# agent can't reach them and sends container traffic out past its namespace.
# Every namespaced agent on a host can have one.
#
# An agent without a namespace uses nixpkgs' virtualisation.docker.rootless
# user service instead. That is host-global (a single user service and socket),
# so at most one such agent per host can enable Docker.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  dockerAgents = lib.filterAttrs (_: a: a.enable && a.docker.enable) config.operator.agents;
  namespacedAgents = lib.filterAttrs (_: a: a.network.namespace.enable) dockerAgents;
  hostAgents = lib.filterAttrs (_: a: !a.network.namespace.enable) dockerAgents;
  hostAgentNames = lib.attrNames hostAgents;
  hostAgent = lib.head (lib.attrValues hostAgents);
  hostAgentPaths = import ./paths.nix hostAgent;
  rootless = config.virtualisation.docker.rootless;

  namespacedDaemon =
    agent:
    let
      paths = import ./paths.nix agent;
      uid = toString agent.uid;
      # The host-global daemon's socket is in the shared settings; this one
      # names its own on the command line, which dockerd refuses alongside a
      # `hosts` key in the config file.
      settings = removeAttrs rootless.daemon.settings [ "hosts" ];
    in
    {
      description = "Rootless Docker for the ${agent.user} agent, in its network namespace";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "${agent.user}-netns.service"
        "user-runtime-dir@${uid}.service"
      ];
      after = [
        "${agent.user}-netns.service"
        "user-runtime-dir@${uid}.service"
        "nscd.service"
      ];
      # newuidmap and newgidmap are setuid wrappers.
      path = [ "/run/wrappers" ] ++ rootless.extraPackages;
      environment = {
        HOME = paths.home;
        XDG_RUNTIME_DIR = "/run/user/${uid}";
      };
      serviceConfig = {
        User = agent.user;
        Type = "notify";
        NotifyAccess = "all";
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 700 ${paths.dockerSocketDir}";
        ExecStart = "${rootless.package}/bin/dockerd-rootless --host=unix://${paths.dockerSocket} --config-file=${
          (pkgs.formats.json { }).generate "${agent.user}-daemon.json" settings
        }";
        ExecReload = "${pkgs.procps}/bin/kill -s HUP $MAINPID";
        TimeoutSec = 0;
        Restart = "always";
        RestartSec = 2;
        LimitNOFILE = "infinity";
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
        Delegate = true;
        KillMode = "mixed";
      }
      // import ./namespace-view.nix { inherit lib; } agent;
    };
in
{
  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = lib.length hostAgentNames <= 1;
          message = "At most one agent per host without network.namespace can enable docker.enable (nixpkgs rootless Docker is host-global); give the others a namespace. Enabled on: ${lib.concatStringsSep ", " hostAgentNames}.";
        }
      ];
    }

    (lib.mkIf (dockerAgents != { }) {
      # Each daemon runs as its agent, so containers get no more access than the
      # agent already has, and the egress rules apply to their traffic. Adding
      # an agent to the docker group would be root-equivalent instead.
      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = false; # It would point at the runtime directory.
      };

      systemd.user.services.docker.enable = hostAgents != { };

      systemd.services = lib.mapAttrs' (
        _: agent: lib.nameValuePair "${agent.user}-docker" (namespacedDaemon agent)
      ) namespacedAgents;
    })

    (lib.mkIf (hostAgents != { }) {
      # The socket lives under the agent's home rather than in the runtime
      # directory, because the Claude service's ProtectHome=tmpfs blanks
      # /run/user and the agent would not see it there.
      virtualisation.docker.rootless.daemon.settings.hosts = [
        "unix://${hostAgentPaths.dockerSocket}"
      ];

      systemd.user.services.docker = {
        # The service is defined for every user, but only this agent needs a
        # daemon and only it can write the socket directory.
        unitConfig.ConditionUser = lib.mkForce hostAgent.user;
        # The daemon does not create the socket directory, and waiting for
        # systemd-tmpfiles would be a race on the first start after a rebuild.
        serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 700 ${hostAgentPaths.dockerSocketDir}";
      };
    })
  ];
}
