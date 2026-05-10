# ssh-key

One-click SSH hardening scripts.

## Scripts

### disable-root-password-login.sh
Closes SSH password-based login and locks the root password.

Interactive flow:
1. Verify `/root/.ssh/authorized_keys` has a valid public key. If not, you can paste one
   and the script will install it (with correct permissions).
2. Confirm key-based login works before going further — so you won't get locked out.
3. Optionally change the SSH port. The script suggests a random unused port in
   **50000–65530**; press Enter to apply, type a custom port, or `n` to keep the current one.
4. Disable `PasswordAuthentication` / `KbdInteractiveAuthentication` /
   `ChallengeResponseAuthentication`, restart sshd, and `passwd -l root`.

The script only edits `sshd_config` — it does **not** touch your firewall or cloud
security group. If you change the port, make sure the new port is allowed there yourself.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/disable-root-password-login.sh -o disable-root-password-login.sh && chmod +x disable-root-password-login.sh && bash disable-root-password-login.sh
```

> Run with `bash <file>` (not `curl ... | bash`), the script needs an interactive terminal
> to read the public key you paste.

## Warning

Even though the script guards against missing keys, you should still test key-based
login from a separate terminal before answering `yes` to the final confirmation.
