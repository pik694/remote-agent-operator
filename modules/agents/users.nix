{ config, pkgs, lib, ... }:
let
  enabled = lib.filterAttrs (_: a: a.enable) config.operator.agents;
  paths = agent: import ./paths.nix agent;
in
{
  config = lib.mkIf (enabled != { }) {
    users.users = lib.mapAttrs' (
      _: agent:
      lib.nameValuePair agent.user {
        isNormalUser = true;
        uid = agent.uid;
        linger = true; # Keeps a rootless Docker daemon running without a login.
        openssh.authorizedKeys.keys = lib.optional (agent.publicKey != null) agent.publicKey;
      }
    ) enabled;

    # TMPDIR for each agent's Claude service (see its Environment); cleaned weekly.
    systemd.tmpfiles.rules = lib.mapAttrsToList (
      _: agent: "d ${(paths agent).tmpDir} 0700 ${agent.user} users 7d"
    ) enabled;

    # Each agent's SSH sessions (Codex, Claude Desktop over SSH) get that
    # agent's own GH_TOKEN, and its Docker socket when it has one. The checks
    # key on uid, so one agent never sees another's token.
    environment.extraInit = lib.concatMapStringsSep "\n" (
      agent:
      let
        p = paths agent;
      in
      ''
        if [ "$(id -u)" = ${toString agent.uid} ]; then
          if [ -r ${agent.githubTokenFile} ]; then
            GH_TOKEN="$(cat ${agent.githubTokenFile})"
            export GH_TOKEN
          fi
      ''
      + lib.optionalString agent.docker.enable ''
          export DOCKER_HOST=unix://${p.dockerSocket}
          # Testcontainers' Ryuk mounts the daemon socket into a container.
          export TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=${p.dockerSocket}
      ''
      + ''
        fi
      ''
    ) (lib.attrValues enabled);

    environment.systemPackages = [
      config.operator.claudePackage
      pkgs.codex
      pkgs.curl
      pkgs.gh
      pkgs.git
      pkgs.python3
      pkgs.ripgrep
      pkgs.tig
      pkgs.tmux
    ];
  };
}
