# ssh-key

One-click SSH hardening scripts.

## Scripts

### disable-root-password-login.sh
Closes SSH password-based login and locks the root password.
Before making changes, it checks `/root/.ssh/authorized_keys` for a valid public key.
If none is found, it prompts you to paste one and then asks you to confirm key login works
before continuing — so you won't get locked out.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/disable-root-password-login.sh -o disable-root-password-login.sh && chmod +x disable-root-password-login.sh && bash disable-root-password-login.sh
```

> Run with `bash <file>` (not `curl ... | bash`), the script needs an interactive terminal
> to read the public key you paste.

## Warning

Even though the script guards against missing keys, you should still test key-based
login from a separate terminal before answering `yes` to the final confirmation.
