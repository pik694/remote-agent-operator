# A minimal, self-contained operator box built only from the exported
# `nixosModules.standalone`. It is the template a downstream flake copies: from
# your own flake you import `operator.nixosModules.standalone` (see the
# "Use it from your own flake" section of the README) instead of
# `self.nixosModules.standalone`, swap the placeholder disk and hardware below
# for your real ones, and wire the GitHub token through your secret store.
#
# It evaluates and builds without any real hardware or secrets, so the flake's
# `checks` build it in CI — that is what proves the module still composes.
{ ... }:
{
  # --- placeholder hardware: replace with your real disk + hardware config ---
  nixpkgs.hostPlatform = "x86_64-linux";
  boot.loader.systemd-boot.enable = true;
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  networking.hostName = "operator-example";

  operator.standalone = {
    enable = true;
    adminUser = "jdoe";
    adminKeys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEADMINKEYvalueGoesHere jdoe@example" ];
  };

  operator.agents.claude-acme = {
    uid = 1000;
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEAGENTKEYvalueGoesHere agent@example";
    repo.url = "git@github.com:acme/widget.git";
    git = {
      userName = "Jane Doe";
      userEmail = "jane+acme@example.com";
    };
    # On a real box these come from sops-nix or agenix. Here they are plain
    # paths so the example needs no secret store to evaluate.
    githubTokenFile = "/run/secrets/gh-acme";
    githubTokenEnvFile = "/run/secrets/claude-acme.env";
    docker.enable = true;
    claudeService.enable = true;
  };

  system.stateVersion = "26.05";
}
