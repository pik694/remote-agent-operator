# Paths derived from the agent-runtime options, shared by its submodules.
cfg:
let
  home = "/home/${cfg.user}";
  repoPath = "${home}/${cfg.repo.directory}";
  # Claude Code mangles a project path into a directory name by replacing
  # every slash with a dash.
  projectDir = builtins.replaceStrings [ "/" ] [ "-" ] repoPath;
in
{
  inherit home repoPath;
  dockerSocketDir = "${home}/.docker/run";
  dockerSocket = "${home}/.docker/run/docker.sock";
  tmpDir = "${home}/.tmp";
  authKey = "${home}/.ssh/${cfg.repo.directory}-gh-auth";
  signingKey = "${home}/.ssh/${cfg.repo.directory}-gh-signing";
  allowedSigners = "${home}/.config/git/allowed_signers";
  bridgePointer = "${home}/.claude/projects/${projectDir}/bridge-pointer.json";
}
