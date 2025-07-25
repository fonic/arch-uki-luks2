# Arch Linux / Manjaro with UKI and LUKS2 encryption

Hooks for `pacman`/`pamac` to automatically configure and generate [Unified
Kernel Images (UKIs)](https://wiki.archlinux.org/title/Unified_kernel_image)
and for `mkinitcpio` to unlock _dm-crypt/LUKS2_ encrypted volumes during boot,
allowing for a GRUB-less LUKS2 full disk encryption setup.


## Donations

I'm striving to become a full-time developer of [Free and open-source software
(FOSS)](https://en.wikipedia.org/wiki/Free_and_open-source_software). Donations
help me achieve that goal and are highly appreciated!

<a href="https://www.buymeacoffee.com/fonic"><img src="https://raw.githubusercontent.com/fonic/donate-buttons/main/buymeacoffee-button.png" alt="Buy Me A Coffee" height="35"></a>&nbsp;&nbsp;
<a href="https://paypal.me/fonicmaxxim"><img src="https://raw.githubusercontent.com/fonic/donate-buttons/main/paypal-button.png" alt="Donate via PayPal" height="35"></a>&nbsp;&nbsp;
<a href="https://ko-fi.com/fonic"><img src="https://raw.githubusercontent.com/fonic/donate-buttons/main/kofi-button.png" alt="Donate via Ko-fi" height="35"></a>


## Disclaimer

**Use this at you own risk!** Only recommended for advanced users! Make sure
to backup your system before applying any changes! Thoroughly review all code
to make sure it does what you expect!


## How it works

The `pacman`/`pamac` hooks monitor changes of Linux kernel packages (install,
remove, upgrade). If a change is detected, the respective kernel is configured
for UKI use (by altering its `.preset` file in `/etc/mkinitcpio.d`) and two
UKIs (_default_ for normal use, _fallback_ for recovery purposes) are generated
via `mkinitcpio` and installed to the EFI System Partition (ESP).

The `mkinitcpio` hook is similar to the stock `encrypt` hook, but features
zero-config unlocking of encrypted volumes (by locating and unlocking all
`TYPE="crypto_LUKS"` volumes) in addition to renaming corresponding device
mapper nodes based on file system labels (e.g. `/dev/mapper/luks-<UUID>` gets
renamed to `/dev/mapper/luks-root`). This is especially useful for systems
which have _multiple_ encrypted volumes that all share the same password (e.g.
root + swap + home).


## Pros and Cons

**Pros UKI vs. GRUB:**<br/>
- [X] Unlocking LUKS2 volumes is supported without patching GRUB (or any other
      components)
- [X] No GRUB, i.e. one less component to worry about (which might have bugs or
      expose vulnerabilities)
- [X] Integrates perfectly with _Secure Boot_ (UKIs get signed automatically by
      `sbctl` hooks without requiring any additional configuration)
- [X] Well-suited if there is only a single OS installed that needs to be booted

**Cons UKI vs. GRUB:**<br/>
- [ ] Kernel command line cannot be changed on demand (e.g. to fix boot issues
      after system upgrades) **(\*)**
- [ ] Requires a larger ESP as UKIs can get quite large (depending on included
      files/modules)
- [ ] Some UEFIs have trouble maintaining their boot order when entries are
      added/removed (e.g. due to kernel upgrades)
- [ ] No fancy boot selection menu (unless the machine's UEFI itself provides
      one)

**(\*)** The _fallback_ UKI provides a pre-configurable recovery option for
this scenario, though.


## Installation

1. Prepare a dm-crypt/LUKS2 encrypted disk containing Arch Linux / Manjaro:<br/>
   **Not covered here as detailed guides on that topic are widely available
   (e.g. see [Arch Linux Wiki](https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system)).**
   
   **The easiest approach might be to use _two_ separate devices:**<br/>
   Perform a normal (unencrypted) installation to the first device, then
   prepare the second encrypted device manually (erase, partition, encrypt,
   unlock, create file systems, mount file systems), then migrate all OS
   data from the first device to the newly set-up encrypted device (e.g.
   using `rsync`).

   The fully set-up encrypted disk might look like this:

   ```
   # fdisk -l /dev/nvme0n1

   Device          Start  End  Sectors  Size  Type
   /dev/nvme0n1p1    ...  ...      ...    1G  EFI System            -> EFI System Partition (ESP)
   /dev/nvme0n1p2    ...  ...      ...  100G  Linux filesystem      -> Root Partition
   /dev/nvme0n1p3    ...  ...      ...  1,5T  Linux filesystem      -> Home Partition
   /dev/nvme0n1p4    ...  ...      ...   64G  Linux filesystem      -> Swap Partition
   ```

   ```
   # blkid | grep nvme0n1

   /dev/nvme0n1p1:  LABEL="efi"  UUID="..."  TYPE="vfat"            -> Unencrypted EFI System Partition (ESP)
   /dev/nvme0n1p2:               UUID="..."  TYPE="crypto_LUKS"     -> Encrypted Root Partition
   /dev/nvme0n1p3:               UUID="..."  TYPE="crypto_LUKS"     -> Encrypted Home Partition
   /dev/nvme0n1p4:               UUID="..."  TYPE="crypto_LUKS"     -> Encrypted Swap Partition
   ```

   ```
   # blkid | grep mapper

   /dev/mapper/luks-root:  LABEL="root"  UUID="..."  TYPE="ext4"    -> Unlocked Root Partition
   /dev/mapper/luks-home:  LABEL="home"  UUID="..."  TYPE="ext4"    -> Unlocked Home Partition
   /dev/mapper/luks-swap:  LABEL="swap"  UUID="..."  TYPE="swap"    -> Unlocked Swap Partition
   ```

   **NOTE:** UKIs can get quite large (depending on included files/modules),
             thus the ESP should be **1G** or more in size (especially when
             multiple kernels are installed at the same time)<br/>
   **NOTE:** make sure to assign file system labels if you want the mkinitcpio
             hook (`encrypt-auto`) to rename device mapper nodes (optional)

2. Download and extract a [release](https://github.com/fonic/arch-uki-luks2/releases)
   of this project:<br/>
   [Link to latest release](https://github.com/fonic/arch-uki-luks2/releases/latest)

3. Copy contents of folder `etc` to encrypted root file system (to install
   the hooks):
   ```
   # cp -r arch-uki-luks2/etc /mnt/luks-root
   ```
   **NOTE:** this assumes the unlocked encrypted root file system
             `/dev/mapper/luks-root` is mounted to `/mnt/luks-root`

4. Edit `/etc/mkinitcpio.conf` and add hook `encrypt-auto` to `HOOKS=(...)`:
   ```
   HOOKS=(... mdadm_udev encrypt-auto resume filesystems fsck)
   ```
   **NOTE:** place `auto-encrypt` _after_ `mdadm_udev` if the system has
             encrypted RAID arrays that shall be unlocked<br/>
   **NOTE:** place `auto-encrypt` _before_ `resume` to be able to resume
             (from hibernation) from an encrypted swap partition

5. Edit `/etc/pacman.d/hooks.bin/uki-manager.conf` and adjust these settings
   to match your system:
   ```
   UBM_DISK="/dev/disk/by-id/<disk-id>"    # Disk where EFI System Partition (ESP) is located (via id)
   UBM_PART=1                              # Partition number of EFI System Partition (ESP) on disk
   ```
   **NOTE:** it is highly recommended to use `/dev/disk/by-id/...` instead
             of device nodes like `/dev/nvme0n1` or `/dev/sda` for `UBM_DISK`,
             as the latter are **not** guaranteed to maintain their particular
             order from one boot to another (e.g. devices referenced via
             `/dev/nvme0n1` and `/dev/nvme1n1` might switch places)

6. Edit `/etc/kernel/cmdline-default` and `/etc/kernel/cmdline-fallback` and
   adjust their contents to match your system<br/>
   **NOTE:** these files contain the _kernel command line_ for the _default_
             and _fallback_ UKIs<br/>
   **NOTE:** use `cat /proc/cmdline` to display your current kernel command
             line

7. Reinstall kernel package(s) to generate UKIs and install them to the ESP:
   ```
   # pacman -S linuxXY
   ```
   -or-
   ```
   $ pamac reinstall linuxXY
   ```
   **NOTE:** replace `XY` with your desired kernel version (e.g. `linux612`)

8. Check if UKIs were properly generated and installed:
   ```
   # ls -lh /boot/efi/EFI/linux
   ```
   Output should look like this:
   ```
   -rwx------ 1 root root 30M Jul 20 18:00 linux-linux612-default.efi
   -rwx------ 1 root root 30M Jul 20 18:00 linux-linux612-fallback.efi
   ```

9. Check if UKIs were properly added to UEFI boot table:
   ```
   # efibootmgr
   ```
   Output should look like this:
   ```
   BootOrder: 0001,0002
   Boot0001*  Linux (6.12-x86_64) (default)   HD(1,GPT,...,0x800,0x200000)/\EFI\linux\linux-linux612-default.efi
   Boot0002*  Linux (6.12-x86_64) (fallback)  HD(1,GPT,...,0x800,0x200000)/\EFI\linux\linux-linux612-fallback.efi
   ```

10. Reboot, enter UEFI setup and configure a `Linux (...) (default)` entry as
    the default boot entry (optional)

11. (Re-)Boot system using a `Linux (...) (default)` boot entry and check if
    unlocking/booting works as expected

12. **All done.** Everything should be maintained automatically from now on
    (e.g. when performing system upgrades). Just make sure to keep an eye on
    `efibootmgr` as some UEFIs tend to mess up the boot order when entries are
    added/removed.

##

_Last updated: 07/25/25_
