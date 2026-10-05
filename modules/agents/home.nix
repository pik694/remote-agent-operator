{ config, lib, ... }:
let
  enabled = lib.filterAttrs (_: a: a.enable) config.operator.agents;

  agentHome =
    agent:
    { pkgs, ... }:
    let
      paths = import ./paths.nix agent;
    in
    {
      imports = [ agent.extraHomeConfig ];

      home.username = agent.user;
      home.homeDirectory = paths.home;
      home.stateVersion = config.system.stateVersion;

      home.packages = with pkgs; [
        helix
        less
      ];

      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        settings."github.com" = {
          User = "git";
          IdentityFile = paths.authKey;
          IdentitiesOnly = "yes";
          StrictHostKeyChecking = "yes";
        };
      };

      # gh authenticates with GH_TOKEN from the deployment's secret store;
      # git itself stays on the SSH keys.
      programs.gh = {
        enable = true;
        gitCredentialHelper.enable = false;
        settings.git_protocol = "ssh";
      };

      programs.git = {
        enable = true;
        ignores = [
          ".DS_Store"
          "**/.direnv/**"
          ".nix-hex/**"
          ".nix-mix/**"
          ".nix-cache/**"
          "**/.claude/**"
          "/.helix/**"
          ".ignore"
          "**/.envrc"
          "**/.env"
          "/.env_dir/**"
          "**/.metals/**"
          "/typos.toml"
        ];
        settings = {
          alias = {
            sha = "rev-parse --short HEAD";
            root = "rev-parse --show-toplevel";
            cmf = "commit --fixup";
            cm = "commit -m";
            fetch-update = "fetch --prune origin main:main";
            prune-local = "!git branch -vv | grep -v '^\\*' | grep -v '^+' | grep 'gone]' | awk '{print $1}' | xargs -I {} sh -c 'echo \"$(git rev-parse --short {}) {}\" && git branch -D {}';";
          };

          user.name = agent.git.userName;
          user.email = agent.git.userEmail;
          user.signingkey = paths.signingKey;

          core.pager = "${pkgs.less}/bin/less -FRX";
          core.editor = "${pkgs.helix}/bin/hx";

          commit.gpgSign = true;
          gpg.format = "ssh";
          gpg.ssh.allowedSignersFile = paths.allowedSigners;

          pull.rebase = true;
          branch.autosetuprebase = "always";
          init.defaultBranch = "main";
          push.autoSetupRemote = true;
          push.default = "simple";
          rebase.autosquash = true;
          rerere.enabled = true;

          url."git@github.com:".insteadOf = "https://github.com/";
          url."git@gitlab.com:".insteadOf = "https://gitlab.com/";
        };
      };
    };
in
{
  config = lib.mkIf (enabled != { }) {
    home-manager.useGlobalPkgs = lib.mkDefault true;
    home-manager.useUserPackages = lib.mkDefault true;
    home-manager.users = lib.mapAttrs' (_: agent: lib.nameValuePair agent.user (agentHome agent)) enabled;
  };
}
