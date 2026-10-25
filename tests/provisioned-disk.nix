# test script lines that give the node a disk from its image, with provision/hello on the ESP
{ pkgs }:
node: ''
  image = tempfile.NamedTemporaryFile()
  subprocess.run(["cp", "--sparse=always", "${node.system.build.release}/${node.image.filePath}", image.name], check=True)
  table = json.loads(subprocess.run(["${pkgs.util-linux}/bin/sfdisk", "--json", image.name], check=True, capture_output=True).stdout)["partitiontable"]
  esp = f"{image.name}@@{table['partitions'][0]['start'] * table['sectorsize']}"
  provisioned = tempfile.NamedTemporaryFile("w")
  provisioned.write("provisioned\n")
  provisioned.flush()
  env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
  subprocess.run(["${pkgs.mtools}/bin/mmd", "-i", esp, "::provision"], check=True, env=env)
  subprocess.run(["${pkgs.mtools}/bin/mcopy", "-i", esp, provisioned.name, "::provision/hello"], check=True, env=env)

  disk = tempfile.NamedTemporaryFile()
  subprocess.run([
    "${pkgs.qemu_kvm}/bin/qemu-img", "create", "-f", "qcow2",
    "-b", image.name, "-F", "raw",
    disk.name, "8G",
  ], check=True)
  os.environ["NIX_DISK_IMAGE"] = disk.name
''
