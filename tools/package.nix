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
  zstd,
}:
stdenvNoCC.mkDerivation {
  pname = "nixos-ab-tools";
  version = "0";
  src = ./.;
  nativeBuildInputs = [ makeWrapper ];
  # new-host finds host.nix.in next to itself
  installPhase = ''
    install -D -m 644 -t $out/share/nixos-ab host.nix.in
    for program in new-host install-host; do
      install -D -t $out/share/nixos-ab $program
      makeWrapper $out/share/nixos-ab/$program $out/bin/$program --set PATH ${
        lib.makeBinPath [
          coreutils
          gnused
          openssh
          sops
          ssh-to-age
          yq-go
          zstd
        ]
      }
    done
  '';
  meta.mainProgram = "new-host";
}
