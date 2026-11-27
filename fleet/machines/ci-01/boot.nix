_:

{
  boot = {
    initrd.availableKernelModules = [
      "virtio_pci"
      "virtio_blk"
      "virtio_net"
    ];
    # Disko derives the GRUB install device from the reviewed EF02
    # partition on the by-path target disk; declaring it again here would
    # duplicate mirroredBoots.
    loader.grub.enable = true;
  };
}
