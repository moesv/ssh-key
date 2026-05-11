# ssh-key

One-click SSH hardening scripts.

## Scripts

### harden.sh
Closes SSH password-based login and locks the root password.

Idempotency: if the host already has authorized keys, a non-default SSH port,
password & keyboard-interactive auth disabled, and an active fail2ban with the
sshd jail, the script enters "maintenance mode" — it prints the current status
and offers a single `[y/N]` prompt to append more public keys. Choosing `N`
exits cleanly without touching anything else.

Interactive flow (when not yet hardened):
1. Verify `/root/.ssh/authorized_keys`. If empty, paste one or more public keys; if it
   already has keys, you can choose to append more. Duplicates are skipped automatically.
2. If the current SSH port is still **22**, offer a random unused port in
   50000–65530. If a non-default port is already in use, the port prompt is skipped.
3. Offer to install **fail2ban** with a minimal `sshd` jail (bantime 1h, findtime 10m, maxretry 5).
4. Offer to install a **login banner** at `/etc/profile.d/00-server-init.sh` that prints
   the SSH port / user / auth type / fail2ban status on every interactive login.
5. Final confirm — preflight checklist with everything that will change. You'll be reminded
   to test key login (for **every** key) from a separate terminal before answering `yes`.

Then the apply phase, in this order (so a partial failure leaves you with a working login):

6. Back up `sshd_config` (and any existing `jail.local`).
7. Edit `sshd_config`, `sshd -t`, restart sshd.
8. Verify sshd is actually listening on the target port.
9. Install + configure fail2ban (if chosen).
10. Install the login banner (if chosen).
11. **Lock root password** (last — only after every earlier step succeeded).
12. Print a summary block with the final port, authorized-key count, fail2ban status,
    banner status, and the exact `ssh -p <port> root@<ip>` command to use next time.

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
