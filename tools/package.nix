{
  lib,
  stdenvNoCC,
  makeWrapper,
  coreutils,
  gnused,
  openssh,
  sops,
  ssh-to-age,
  yq-go,
}:
stdenvNoCC.mkDerivation {
  pname = "new-host";
  version = "0";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  # the script finds host.nix.in next to itself
  installPhase = ''
    install -D -t $out/share/new-host new-host
    install -D -m 644 -t $out/share/new-host host.nix.in
    makeWrapper $out/share/new-host/new-host $out/bin/new-host --set PATH ${
      lib.makeBinPath [
        coreutils
        gnused
        openssh
        sops
        ssh-to-age
        yq-go
      ]
    }
  '';
  meta.mainProgram = "new-host";
}
