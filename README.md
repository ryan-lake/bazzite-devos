# bazzite-devos &nbsp; [![bluebuild build badge](https://github.com/ryan-lake/bazzite-devos/actions/workflows/build.yml/badge.svg)](https://github.com/ryan-lake/bazzite-devos/actions/workflows/build.yml)

See the [BlueBuild docs](https://blue-build.org/how-to/setup/) for quick setup instructions for setting up your own repository based on this template.

After setup, it is recommended you update this README to describe your custom image.

## Installation

> [!WARNING]
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

To rebase an existing atomic Fedora installation to the latest build:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/ryan-lake/bazzite-devos:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/ryan-lake/bazzite-devos:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## Kernel Module Signing

This image can sign custom kernel modules during CI. The same signing keypair can be reused for any future modules added to the image. Secure Boot systems need the signing certificate enrolled before signed custom modules can load.

Create a module signing keypair locally:

```bash
mkdir -p ~/.local/share/module-signing
openssl req -new -x509 -newkey rsa:4096 \
  -keyout ~/.local/share/module-signing/kernel-module-signing.key \
  -outform DER \
  -out ~/.local/share/module-signing/kernel-module-signing.der \
  -nodes \
  -days 3650 \
  -subj "/CN=Kernel module signing/"
```

Add these GitHub repository secrets before running the image build:

- `KERNEL_MODULE_SIGNING_KEY`: contents of `~/.local/share/module-signing/kernel-module-signing.key`
- `KERNEL_MODULE_SIGNING_CERT`: base64 output of `~/.local/share/module-signing/kernel-module-signing.der`

```bash
base64 -w0 ~/.local/share/module-signing/kernel-module-signing.der
```

Enroll the same certificate on Secure Boot systems:

```bash
sudo mokutil --import ~/.local/share/module-signing/kernel-module-signing.der
```

Reboot and complete enrollment in the MOK manager. After rebasing to the built image, the public cert is also available at `/etc/pki/akmods/certs/kernel-module-signing.der` for verification.

## ACP Mic Kernel Modules

This image builds the temporary AMD ACP mic modules needed for the Bazzite OGC kernel issue where `snd-acp-pci` and `snd-acp-legacy-mach` are missing from the fc44 kernel config. The build uses the generic kernel module signing key above.

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/how-to/generate-iso/#_top). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/ryan-lake/bazzite-devos
```
