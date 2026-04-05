# ssh-key

One-click SSH hardening scripts.

## Scripts

### disable-root-password-login.sh
Closes SSH password-based login and locks the root password.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/moesv/ssh-key/main/disable-root-password-login.sh -o disable-root-password-login.sh && chmod +x disable-root-password-login.sh && bash disable-root-password-login.sh
```

## Warning

Make sure SSH key login already works before running this script, or you may lock yourself out of the server.
