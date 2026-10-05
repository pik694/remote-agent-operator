# A set of agent accounts. Each entry in `operator.agents` is one unprivileged
# Linux user = one Claude license = one `claude remote-control`, with its own
# checkout, GitHub token, egress rules and (optionally) rootless Docker. The
# module knows nothing about how the machine is accessed or monitored; see
# ../standalone for a complete box.
{ config, lib, ... }:
let
  agentModule =
    { name, config, ... }:
    {
      options = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether this agent account is created.";
        };

        user = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Unprivileged account the agent runs as.";
        };

        uid = lib.mkOption {
          type = lib.types.int;
          description = ''
            Fixed uid, so the account's uid is stable across rebuilds and the
            egress and Docker rules keyed on it stay correct. Must be unique
            across agents on a host.
          '';
        };

        publicKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            SSH public key allowed to log in as this agent, or null for no
            direct login. Must be a dedicated key, never the admin's.
          '';
        };

        repo = {
          url = lib.mkOption {
            type = lib.types.str;
            description = "Git remote the agent works against, cloned on first boot.";
            example = "git@github.com:alaro-ai/alaro.git";
          };

          directory = lib.mkOption {
            type = lib.types.str;
            default = lib.removeSuffix ".git" (baseNameOf config.repo.url);
            defaultText = lib.literalExpression "the repository name in repo.url";
            description = ''
              Checkout directory under the agent's home. It also names the
              per-repository SSH keys, so changing it after installation
              strands the existing keys.
            '';
          };
        };

        git = {
          userName = lib.mkOption {
            type = lib.types.str;
            description = "Author name on the agent's commits.";
          };

          userEmail = lib.mkOption {
            type = lib.types.str;
            description = ''
              Author address on the agent's commits, and the identity its
              signing key is trusted for. Use a dedicated address.
            '';
          };
        };

        githubTokenFile = lib.mkOption {
          type = lib.types.path;
          description = ''
            File holding the bare GitHub token, readable by this agent. How it
            gets there is the deployment's business: sops-nix, agenix or a
            file placed by hand all work.
          '';
        };

        githubTokenEnvFile = lib.mkOption {
          type = lib.types.path;
          description = ''
            File holding `GH_TOKEN=<token>`, readable by this agent, loaded as
            the Claude service's EnvironmentFile. Point the unit that writes
            it at this agent's claude service so a rotated token restarts it.
          '';
        };

        docker = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Rootless Docker for this agent, so tests can start containers
              without the agent gaining root-equivalent access. At most one
              agent per host may enable this (see docker.nix).
            '';
          };
        };

        egressFirewall = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Block this agent from reaching private network ranges, so a
              compromised session cannot touch the rest of the LAN. The
              tailnet and the public internet stay reachable.
            '';
          };
        };

        claudeService = {
          enable = lib.mkEnableOption "claude remote-control as a persistent service for this agent";

          capacity = lib.mkOption {
            type = lib.types.int;
            default = 4;
            description = "Concurrent sessions the service accepts.";
          };

          memoryHigh = lib.mkOption {
            type = lib.types.str;
            default = "5G";
            description = ''
              Soft memory limit; the service is throttled above it. Lower this
              when a host runs more than one agent.
            '';
          };

          memoryMax = lib.mkOption {
            type = lib.types.str;
            default = "6G";
            description = ''
              Hard memory limit; leave room for sshd, Nix builds and any other
              agents. Lower this when a host runs more than one agent.
            '';
          };
        };

        extraHomeConfig = lib.mkOption {
          type = lib.types.deferredModule;
          default = { };
          description = "Extra Home Manager configuration merged into this agent.";
        };
      };
    };
in
{
  imports = [
    ./users.nix
    ./docker.nix
    ./egress-firewall.nix
    ./checkout.nix
    ./claude-service.nix
    ./home.nix
  ];

  options.operator = {
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule agentModule);
      default = { };
      description = "Agent accounts to create on this host, keyed by name.";
    };

    claudePackage = lib.mkOption {
      type = lib.types.package;
      description = "Claude Code package the agents and their services use.";
    };
  };

  config =
    let
      enabled = lib.filterAttrs (_: a: a.enable) config.operator.agents;
    in
    lib.mkIf (enabled != { }) {
      assertions = lib.mapAttrsToList (name: agent: {
        assertion = agent.publicKey != null -> agent.publicKey != "";
        message = "operator.agents.${name}.publicKey must be a real key or null.";
      }) enabled;

      # Agent tooling runs downloaded binaries that expect a normal FHS layout.
      programs.nix-ld.enable = true;
    };
}
