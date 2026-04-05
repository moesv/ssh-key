# ssh-key

One-click SSH hardening scripts.

## Scripts

### disable-root-password-login.sh
Closes SSH password-based login and locks the root password.
Before making changes, it checks whether `/root/.ssh/authorized_keys` exists and is non-empty.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/disable-root-password-login.sh -o disable-root-password-login.sh && chmod +x disable-root-password-login.sh && bash disable-root-password-login.sh
```

## Warning

The script now checks whether `/root/.ssh/authorized_keys` exists and is non-empty before continuing.
Still, make sure SSH key login already works before running it, or you may lock yourself out of the server.
