# Installing Vivado 2024.1 for Artix-7 without interaction

`vivado/install.sh` installs AMD Vivado ML Standard 2024.1 with Artix-7 device support
and nothing else. That is the Vivado release and device family of the Artix-7 FPGA in
the C64 Ultimate and the Ultimate 64 Elite II (XC7A50T and XC7A100T). The install runs
unattended, including the AMD login the web installer needs.

## Before the first run

1. Download the Linux web installer
   `FPGAs_AdaptiveSoCs_Unified_2024.1_0522_2023_Lin64.bin` (about 300 MB) from AMD's
   2024.1 downloads page into `~/Downloads`. The page requires an AMD account and a
   name and address form for US export control, so this step stays manual.
2. Put the AMD account credentials in `~/.env`, or export them:

   ```
   AMD_EMAIL=you@example.com
   AMD_PASSWORD=...
   ```

   `export` prefixes and quoted values are accepted. Keep the file private
   (`chmod 600 ~/.env`).

## Running it

```bash
vivado/install.sh --dry-run      # prints each step, changes nothing
vivado/install.sh                # installs to ~/Xilinx/Vivado/2024.1
vivado/install.sh --dest /opt/Xilinx
```

The script:

1. refuses to run if `<dest>/Vivado/2024.1` already exists, or if the destination
   filesystem has less than 80 GB free;
2. unpacks the installer client into
   `~/.cache/1541ultimate-tools/vivado-2024.1-installer`, and warns if the installer's
   MD5 is not `8b0e99a41b851b50592d5d6ef1b1263d`;
3. runs `auth_token.py --ensure`, which obtains a login token when there is none or
   when the current one has less than a day left;
4. runs `xsetup -b Install -a XilinxEULA,3rdPartyEULA -c vivado/install_config.txt -l <dest>`.

The download is 13.4 GB and the installed tree is 27 GB. At 10 MB/s the whole install
takes about 35 minutes.

## The login token

The web installer authenticates with a token that `xsetup -b AuthTokenGen` writes to
`~/.Xilinx/wi_authentication_key`. The token is valid for 7 days. `auth_token.py` runs
that command on a pseudo-terminal and answers its e-mail and password prompts from
`AMD_EMAIL` and `AMD_PASSWORD`. Values in the environment take precedence over
`~/.env`.

Neither value appears in the script's output or in a log. The e-mail the installer
echoes back is replaced by `<hidden>`, and the rest of the password line is dropped.
When AMD rejects the login, the installer asks again. The script stops at that second
prompt rather than waiting for its timeout.

```bash
python3 vivado/auth_token.py --xsetup <client dir>/xsetup --ensure   # renew if needed
python3 vivado/auth_token.py --xsetup <client dir>/xsetup            # renew now
python3 vivado/test_auth_token.py                                    # host tests
```

The tests drive a fake `xsetup` and do not contact AMD.

## What the configuration selects

`vivado/install_config.txt` is the 2024.1 `ConfigGen` output for Vivado ML Standard
with only `Artix-7:1`. DocNav, Vitis, Vitis Model Composer, Power Design Manager, the
Kria and Alveo device sets and every other device family are off. No post-install
scripts run, and no desktop shortcuts, menu entries or file associations are created.

The installer matches module names literally, and the names change between releases
(`Artix-7` in 2024.x, `Artix-7 FPGAs` in 2025.x). For another release, generate a
fresh file with `<client dir>/xsetup -b ConfigGen` and copy only the 0/1 choices.

The IP cores the Artix-7 projects use (`mig_7series` 4.2, `gtwizard` 3.6 and
`clk_wiz` 6.0) are part of the Vivado IP catalog and need no extra module.

## Licensing

No license file is needed. AMD's UG973 for 2024.1 states that Vivado ML Standard
Edition has needed no license since 2016.x, and lists XC7A12T to XC7A200T as
supported by it. The gtwizard (PG168) and clk_wiz (PG065) product guides state that
the cores are "provided at no additional cost with the Xilinx Vivado Design Suite".

## Host libraries

UG973 lists Ubuntu 20.04 and 22.04 up to 22.04.3. Newer releases work but produce an
"OS version that is not officially supported" warning during the install.

- Without `libtinfo.so.5`, the installer stops at "Generating installed device list".
  Ubuntu 22.04 provides it as `libtinfo5`. Ubuntu 24.04 has no such package, so
  install the 22.04 `libtinfo5` and `libncurses5` .deb files.
- Running Vivado in batch mode in a minimal Ubuntu 22.04 container additionally needs
  `locales` with a UTF-8 locale, plus `libxrender1`, `libxtst6`, `libxi6` and
  `fontconfig` for the bundled Java runtime used by IP generation:

  ```bash
  apt-get install -y libtinfo5 libncurses5 locales libxrender1 libxtst6 libxi6 fontconfig
  locale-gen en_US.UTF-8 && export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  ```

`<dest>/Vivado/2024.1/settings64.sh` contains absolute paths. In a container that
mounts the tree elsewhere, call `<mount>/Vivado/2024.1/bin/vivado` directly instead
of sourcing it.

## Sources

- UG973 2024.1, batch mode:
  [Running the Installer](https://docs.amd.com/r/2024.1-English/ug973-vivado-release-notes-install-license/Running-the-Installer),
  [Acquire Authentication Token](https://docs.amd.com/r/2024.1-English/ug973-vivado-release-notes-install-license/Acquire-Authentication-Token),
  [Supported Devices](https://docs.amd.com/r/2024.1-English/ug973-vivado-release-notes-install-license/Supported-Devices)
- [PG168 Licensing and Ordering](https://docs.amd.com/r/en-US/pg168-gtwizard/Licensing-and-Ordering),
  [PG065 Licensing and Ordering](https://docs.amd.com/r/en-US/pg065-clk-wiz/Licensing-and-Ordering)
- 2024.1 module names: the Arch Linux AUR `vivado` package at commit 8283132,
  `install_config-vivado.txt`
