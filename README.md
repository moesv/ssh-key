# ssh-key

One-click SSH hardening scripts.

## Scripts

### harden.sh
Closes SSH password-based login and locks the root password.

Interactive flow:
1. Verify `/root/.ssh/authorized_keys`. If empty, paste one or more public keys; if it
   already has keys, you can choose to append more. Duplicates are skipped automatically.
2. Confirm key-based login works (for **every** key you intend to keep) before going further
   — so you won't get locked out.
3. Optionally change the SSH port. The script suggests a random unused port in
   **50000–65530**; press Enter to apply, type a custom port, or `n` to keep the current one.
4. Disable `PasswordAuthentication` / `KbdInteractiveAuthentication` /
   `ChallengeResponseAuthentication`, restart sshd, and `passwd -l root`.

The script only edits `sshd_config` — it does **not** touch your firewall or cloud
security group. If you change the port, make sure the new port is allowed there yourself.

## Usage

One-liner (preferred — runs directly, no file left behind):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/harden.sh)
```

Or download then run (use this if your terminal app mangles URLs / `<(...)`):

```bash
curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/harden.sh -o harden.sh && bash harden.sh
```

> Do **not** use `curl ... | bash` — the script is interactive (asks you to paste a
> public key, choose a port, etc.) and a pipe takes away its stdin.

## Warning

Even though the script guards against missing keys, you should still test key-based
login from a separate terminal before answering `yes` to the final confirmation.
