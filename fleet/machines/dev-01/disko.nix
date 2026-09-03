_:

let
  targetDisk = "/dev/disk/by-path/pci-0000:00:10.0";
in
{
  disko.devices.disk.dev-01 = {
    type = "disk";
    device = targetDisk;

    # This guard duplicates every live preflight required by the reviewed
    # install plan. Any ambiguity aborts immediately before Disko writes.
    preCreateHook = ''
      set -eu
      # Disko executes generated disk scripts under `set -efu`; `-f` (noglob)
      # would leave the /sys/class/block/* patterns below unexpanded and abort
      # the guard even on a healthy single-disk target. Re-enable globbing.
      set +f

      test -L '${targetDisk}'
      test "$(readlink -f '${targetDisk}')" = /dev/vda
      test "$(cat /sys/class/block/vda/size)" = 2147483648

      command -v lsblk >/dev/null 2>&1
      disk_names="$(
        lsblk -dn -o NAME,TYPE |
          while read -r name type; do
            test "$type" != disk || printf '%s\n' "$name"
          done
      )"
      test "$disk_names" = vda

      whole_disks=0
      for candidate in /sys/class/block/vd* /sys/class/block/sd* /sys/class/block/nvme*n*; do
        test -e "$candidate" || continue
        test ! -e "$candidate/partition" || continue
        name="''${candidate##*/}"
        whole_disks="$((whole_disks + 1))"
        test "$name" = vda
      done
      test "$whole_disks" -eq 1

      command -v findmnt >/dev/null 2>&1
      test -z "$(findmnt -rn -S /dev/vda)"
      while read -r source _rest; do
        case "$source" in
          /dev/vda*) exit 1 ;;
        esac
      done < /proc/mounts

      test "$(wc -l < /proc/swaps)" -eq 1
      test ! -e /sys/firmware/efi
    '';

    content = {
      type = "gpt";
      partitions = {
        bios = {
          size = "1M";
          type = "EF02";
          priority = 1;
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
            mountOptions = [ "noatime" ];
          };
        };
      };
    };
  };

  assertions = [
    {
      assertion = targetDisk == "/dev/disk/by-path/pci-0000:00:10.0";
      message = "dev-01 Disko may target only the reviewed PCI by-path disk";
    }
  ];
}
