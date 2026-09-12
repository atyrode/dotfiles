{
  lib,
  pkgs,
  execution,
}:
let
  source = pkgs.writeText "manifold-runtime-library-probe.c" ''
    #include <dlfcn.h>
    #include <stdio.h>

    int main(void) {
      void *library = dlopen("libm.so.6", RTLD_NOW);
      if (library == NULL) {
        fputs(dlerror(), stderr);
        return 1;
      }
      dlclose(library);
      puts("native runtime libraries ready");
      return 0;
    }
  '';
  probe =
    pkgs.runCommandCC "manifold-runtime-library-probe"
      {
        nativeBuildInputs = [ pkgs.patchelf ];
      }
      ''
        $CC ${source} -ldl -o "$out"
        patchelf --remove-rpath --set-interpreter /lib64/ld-linux-x86-64.so.2 "$out"
      '';
  closure = pkgs.closureInfo {
    rootPaths = execution.runtimeToolClosures.system or [ ];
  };
  bindings = lib.concatMap (binding: [
    "--ro-bind"
    binding.source
    binding.target
  ]) execution.runtimeTools.system;
  runProbe = pkgs.writeShellScript "manifold-runtime-library-probe" ''
    set -euo pipefail
    args=(
      --unshare-all --die-with-parent --new-session --clearenv
      --proc /proc --dev /dev --tmpfs /tmp
      --ro-bind ${probe} /job/probe
      ${lib.escapeShellArgs bindings}
    )
    while IFS= read -r path; do
      args+=(--ro-bind "$path" "$path")
    done < ${closure}/store-paths
    exec ${pkgs.bubblewrap}/bin/bwrap "''${args[@]}" /job/probe
  '';
in
pkgs.testers.runNixOSTest {
  name = "manifold-runtime-libraries";
  nodes.machine = {
    virtualisation.memorySize = 1024;
    # The test channel must exist before stage-two udev enumeration under TCG.
    boot.initrd.kernelModules = [ "virtio_console" ];
  };
  testScript = ''
    import select

    machine.start()
    # Emulated boot may exceed connect's fixed deadline; wait for shell readiness itself.
    assert machine.shell is not None
    assert select.select([machine.shell], [], [], 900)[0], "VM shell did not become ready"
    machine.connect()
    machine.wait_for_unit("multi-user.target")
    machine.succeed("mkdir -p /run/systemd/resolve; touch /run/systemd/resolve/stub-resolv.conf")
    output = machine.succeed("${runProbe}")
    assert output.strip() == "native runtime libraries ready", output
  '';
}
