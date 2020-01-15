# XCP-ng Local ZFS Storage

[ZFS (on Linux)](https://zfsonlinux.org/) has been available on [XCP-ng](https://xcp-ng.org/) since v7.5, but has been stable and included in the standard repository as of v8.0.

## Connecting Drives

ZFS needs direct access to the disks, so an IT-mode (initiator-target) host bus adapter (HBA) should be used to connet drives. Using adapters that abstract disks (ie. RAID cards) will *work*, but its not recommended since certain surety functions of ZFS won't work since those adapters "lie".

LSI (now Avago) controllers are generally the recommendation since they're so abundant, and thus, cheap.

Common cards:

| PCIe Version  | Drive Speed   | Connector             | Chipset   | Card Model    | Versions          |
|-              |-              |-                      |-          |-              |-                  |
| 2.0           | 6Gb/s         | SFF-8087              | SAS 2008  | 9211          | 8i                |
| 3.0           | 6Gb/s         | SFF-8087              | SAS 2308  | 9207          | 8i                |
| 3.0           | 12Gb/s        | SFF-8643<br>SFF-8644  | SAS 3008  | 9300          | 8e, 8i, 4i4e, 4i  |

!!! Info
    The above Versions describe the port layout of the card. `i` means Internal ports, `e` means external ports. The number denotes SAS lanes (4 per port).

    `8i` = 2 Internal SAS Connectors

    `4i4e` = 2 Internal and 2 External SAS Connectors.

## Install ZFS

For XCP-ng versions <8:

```sh
yum install --enable-repo="xcp-ng-extras" \
blktap \
vhd-tool \
kmod-spl-4.4.0+10 \
kmod-zfs-4.4.0+10 \
zfs
```

For XCP-ng version 8+:

```sh
yum install zfs
```

ZFS is a kernel module, so it needs to be enabled:

```sh
depmod -a
```

```sh
modprobe zfs
```

## Create Pool and Dataset

In this example, a 2-drive mirror will be created.

It's a good idea to create the pool using disk id's from `/dev/disk/by-id` since mount locations can change.

```sh
ls /dev/disk/by-id
```

```sh
. . .
ata-Samsung_SSD_860_EVO_1TB_S5BXXXXXXXXXX1N
ata-Samsung_SSD_860_EVO_1TB_S5BXXXXXXXXXX2N
. . .
```

Now create a mirrored pool named `tank` using the above drive locations:

```sh
zpool create tank mirror \
/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S5BXXXXXXXXXX1N \
/dev/disk/by-id/ata-Samsung_SSD_860_EVO_1TB_S5BXXXXXXXXXX2N
```

Now, create a dataset that will be the mount point for our local storage repository (SR):

```sh
zfs create tank/local
```

## Create SR

We'll use the `xe` command here, so we'll need to get the host's UUID. To easily reference this, we'll add the local inventory file so we can reference the UUID through an environment variable.

```sh
source /etc/xensource-inventory
```

Confirm the variables were loaded by echoing the UUID:

```sh
echo $INSTALLATION_UUID
```

You should get something like this:

```sh
abcdef12-3456-7890-abcd-ef1234567890
```

Now, create the SR:

```sh hl_lines="3 5"
xe sr-create \
host-uuid=$INSTALLATION_UUID \
name-label="Local ZFS" \
type=file \
device-config:location=/tank/local
```

Name the repository to whatever you want and make sure the location is accurate if you used a different name for the dataset.

For other servers, [Xen-Orchestra](https://xen-orchestra.com/) makes it easier to mount local ZFS storage. A guide can be found [here](../../services/xen-orchestra/) if you want to set that up.
