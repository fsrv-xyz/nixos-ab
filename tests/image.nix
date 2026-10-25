# the VM boots the disk image itself, not the test framework's kernel and host store
{ lib, ... }:
{
  system.image.id = "ab";
  virtualisation = {
    memorySize = 1024;
    directBoot.enable = false;
    mountHostNixStore = false;
    useEFIBoot = true;
    fileSystems = lib.mkVMOverride { };
  };
}
