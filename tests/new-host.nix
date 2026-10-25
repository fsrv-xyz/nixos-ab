{
  runCommand,
  new-host,
  nixfmt,
  openssh,
  sops,
  ssh-to-age,
  yq-go,
}:
runCommand "new-host"
  {
    nativeBuildInputs = [
      new-host
      nixfmt
      openssh
      sops
      ssh-to-age
      yq-go
    ];
  }
  ''
    export HOME=$PWD/home
    mkdir -p $HOME/.ssh empty fresh repo
    ssh-keygen -q -t ed25519 -N "" -f $HOME/.ssh/id_ed25519
    admin=$(cut -d' ' -f1,2 $HOME/.ssh/id_ed25519.pub)
    fails() { if "$@"; then exit 1; fi; }

    (cd fresh && new-host h0 && test "$(yq '.keys[0] | anchor + " " + .' .sops.yaml)" = "admin $admin")

    cd repo
    ssh-keygen -q -t ed25519 -N "" -f device.key
    cat > .sops.yaml <<EOF
    keys:
      # stays
      - &admin $admin
      - &device $(ssh-to-age < device.key.pub)
    creation_rules:
      - path_regex: secrets\.yaml$
        key_groups:
          - age:
              - *admin
              - *device
    EOF
    new-host h1
    new-host h2
    nixfmt --check hosts/*/default.nix
    grep -q '# stays' .sops.yaml
    test "$(yq '.creation_rules[].path_regex' .sops.yaml | tr '\n' ' ')" = 'hosts/h2/secrets\.yaml$ hosts/h2/host-key\.yaml$ hosts/h1/secrets\.yaml$ hosts/h1/host-key\.yaml$ secrets\.yaml$ '
    rule() { yq "explode(.) | .creation_rules[$1].key_groups[0].age | join(\",\")" .sops.yaml; }
    test "$(rule 0)" = "$admin,$(ssh-to-age < hosts/h2/ssh_host_ed25519_key.pub)"
    test "$(rule 1)" = "$admin"

    admin() { SOPS_AGE_SSH_PRIVATE_KEY_FILE=$HOME/.ssh/id_ed25519 sops decrypt "$@"; }
    # as sops-nix decrypts: with an age identity made from the host key, no admin key in reach
    host() { HOME=../empty SOPS_AGE_KEY=$(ssh-to-age -private-key -i $1.key) sops decrypt hosts/$2/$3.yaml; }
    for h in h1 h2; do
      admin --extract '["ssh_host_ed25519_key"]' hosts/$h/host-key.yaml > $h.key
      chmod 600 $h.key
      test "$(ssh-keygen -y -f $h.key)" = "$(cat hosts/$h/ssh_host_ed25519_key.pub)"
      test "$(admin hosts/$h/secrets.yaml)" = "example: replace me"
      test "$(host $h $h secrets)" = "example: replace me"
      fails host $h $h host-key
    done
    fails host h1 h2 secrets
    fails host device h1 secrets
    fails new-host h1

    mkdir hosts/b
    touch hosts/b/keep
    fails new-host b
    test -e hosts/b/keep
    fails yq -e '.keys[] | select(anchor == "b")' .sops.yaml
    touch $out
  ''
