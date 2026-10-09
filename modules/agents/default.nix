# A set of agent accounts. Each entry in `operator.agents` is one unprivileged
# Linux user = one Claude license = one `claude remote-control`, with its own
# checkout, GitHub token, egress rules and (optionally) rootless Docker. The
# module knows nothing about how the machine is accessed or monitored; see
# ../standalone for a complete box.
{ config, lib, ... }:
let
  inherit (config.networking) hostName;
  inherit (config.operator) owner;

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
            example = "git@github.com:acme/widget.git";
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

        network.namespace = {
          enable = lib.mkEnableOption ''
            a network namespace of the agent's own, reaching only the internet
            through the host, so host-level networks (LAN, the host's tailnet)
            stay out of its reach
          '';

          nameservers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "1.1.1.1"
              "9.9.9.9"
            ];
            description = ''
              Nameservers the agent's namespace resolves through, instead of
              the host's (which may be a tailnet or LAN resolver it cannot
              reach).
            '';
          };

          tailscale.enable = lib.mkEnableOption ''
            a tailscaled of the agent's own inside its namespace, so the agent
            can join a different tailnet than the host. Log it in once by hand:
            `sudo tailscale --socket=/run/<user>-tailscale/tailscaled.sock up`
          '';

          tailscale.authKeyFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              File holding a Tailscale auth key for the agent's tailnet, so its
              tailscaled logs in on its own. Used only while it is logged out.
            '';
          };

          tailscale.hostname = lib.mkOption {
            type = lib.types.str;
            default = lib.concatStringsSep "-" (
              [ hostName ] ++ lib.optional (owner != null) owner ++ [ "claude-agent" ]
            );
            defaultText = lib.literalExpression ''"<networking.hostName>-<operator.owner>-claude-agent"'';
            description = ''
              Name the agent's device gets in its tailnet, so its owner can find
              it among everyone else's.
            '';
          };

          tailscale.extraUpFlags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            example = [ "--advertise-tags=tag:agent" ];
            description = "Extra flags for the automatic `tailscale up`.";
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
    ./network-namespace.nix
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

    owner = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "jdoe";
      description = ''
        Who runs this box's agents, used to name them where others see them
        (for example their devices in a shared tailnet).
      '';
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
