# A complete one-machine operator box: the agent accounts plus the admin
# access, networking and Nix settings a standalone host needs. A fleet that
# already has its own base profile should import ../agents directly and skip
# this module.
{ config, lib, ... }:
let
  cfg = config.operator.standalone;
  enabledAgents = lib.filterAttrs (_: a: a.enable) config.operator.agents;
  agentUsers = lib.mapAttrsToList (_: a: a.user) enabledAgents;
  agentKeys = lib.filter (k: k != null) (lib.mapAttrsToList (_: a: a.publicKey) enabledAgents);
in
{
  imports = [ ../agents ];

  options.operator.standalone = {
    enable = lib.mkEnableOption "admin access, networking and Nix settings for a standalone operator box";

    adminUser = lib.mkOption {
      type = lib.types.str;
      description = "Account with passwordless sudo, used to deploy the box.";
    };

    adminKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "SSH public keys allowed to log in as the admin account.";
    };

    efiBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Boot with systemd-boot on UEFI.";
    };

    maxJobs = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Parallel Nix builds. One is a safe start on 8 GB of RAM.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.adminKeys != [ ];
        message = "Set operator.standalone.adminKeys, or the box will be unreachable after installation.";
      }
      {
        assertion = lib.all (k: !(lib.elem k cfg.adminKeys)) agentKeys;
        message = "An agent publicKey must be a dedicated key, not the admin's key.";
      }
    ];

    networking.useDHCP = lib.mkDefault true;

    boot.loader.systemd-boot.enable = lib.mkDefault cfg.efiBoot;
    boot.loader.efi.canTouchEfiVariables = lib.mkDefault cfg.efiBoot;

    # Key-only admin access is used for the initial headless bootstrap.
    # The agent account has no sudo rights.
    services.openssh = {
      enable = true;
      openFirewall = lib.mkDefault true; # Needed for LAN bootstrap; review after Tailscale works.
      settings = {
        PasswordAuthentication = lib.mkDefault false;
        KbdInteractiveAuthentication = lib.mkDefault false;
        PermitRootLogin = lib.mkDefault "no";
        # A forwarded admin agent would let agent processes use the admin's keys.
        AllowAgentForwarding = lib.mkDefault false;
        AllowUsers = [ cfg.adminUser ] ++ agentUsers;
      };
    };

    operator.owner = lib.mkDefault cfg.adminUser;

    users.users.${cfg.adminUser} = {
      isNormalUser = true;
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = cfg.adminKeys;
    };

    security.sudo.extraRules = [
      {
        users = [ cfg.adminUser ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    services.tailscale = {
      enable = lib.mkDefault true;
      extraSetFlags = [ "--hostname=${config.networking.hostName}" ];
    };

    services.fstrim.enable = lib.mkDefault true;

    nixpkgs.config.allowUnfree = lib.mkDefault true;
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = lib.mkDefault true;
      max-jobs = lib.mkDefault cfg.maxJobs;
    };
    nix.gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "weekly";
      options = lib.mkDefault "--delete-older-than 14d";
    };
  };
}
