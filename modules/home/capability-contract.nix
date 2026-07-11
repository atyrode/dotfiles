{
  config,
  lib,
  pkgs,
  ...
}:

let
  knownCapabilities = builtins.attrNames (import ../../home/profiles);
  selected = config.atyrode.capabilities.selected;
  has = capability: builtins.elem capability selected;
in
{
  options.atyrode.capabilities.selected = lib.mkOption {
    type = lib.types.listOf (lib.types.enum knownCapabilities);
    default = [ ];
    internal = true;
    description = "Portable dotfiles capabilities selected by the imported profiles.";
  };

  config.assertions = [
    {
      assertion = builtins.length selected == builtins.length (lib.unique selected);
      message = "Home Manager capabilities must not be selected more than once";
    }
    {
      assertion = selected == [ ] || has "base";
      message = "every portable dotfiles composition must include the base capability";
    }
    {
      assertion = !(has "server" && has "desktop");
      message = "server and desktop Home Manager capabilities are incompatible";
    }
    {
      assertion = !(has "server" && has "development");
      message = "server and development Home Manager capabilities are incompatible";
    }
    {
      assertion = !has "server" || pkgs.stdenv.hostPlatform.isLinux;
      message = "the server Home Manager capability is Linux-only";
    }
    {
      assertion = !has "base" || builtins.hasAttr "atyrode" pkgs;
      message = "the base Home Manager capability requires the dotfiles package overlay";
    }
    {
      assertion = !has "agent-tools" || builtins.hasAttr "omp-configured" pkgs;
      message = "the agent-tools Home Manager capability requires the dotfiles package overlay";
    }
  ];
}
