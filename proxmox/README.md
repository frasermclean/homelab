# Proxmox scripts

Helper scripts run on the Proxmox VE nodes (as root, over SSH).

| Script | Purpose |
|---|---|
| [create-debian-template.sh](create-debian-template.sh) | Build a Debian cloud-init VM template from the official cloud image |

## Debian template

```bash
# Copy to the node and run (once per node - templates on local storage only clone on their own node)
scp proxmox/create-debian-template.sh root@<node>:/root/
ssh root@<node> 'bash /root/create-debian-template.sh --vmid 9000 --ssh-keys /root/my-keys.pub'

# Deploy a VM from it
qm clone 9000 120 --name my-vm --full
qm set 120 --ipconfig0 ip=dhcp,ip6=auto
qm start 120
```

Add `--docker` to bake in Docker Engine + Compose from Docker's apt repo; the
cloud-init user is added to the `docker` group on each clone's first boot.

Run with `--help` for all options (release, storage, VLAN tag, sizing, etc.).
To refresh a template with a newer image, re-run with `--force` (fails if linked clones still depend on it).
