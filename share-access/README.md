# share-access — AWS access setup

This folder **is tracked in git** — it carries the setup script, the Windows
launcher, and the credentials template. Only `share-access/SECRETS` (your real AWS
credentials) is git-ignored, so secrets are never pushed to GitHub. The folder
is also included when the project is shared as a `.zip`.

## Project owner — to share access

1. Create your secrets file from the template (the copy is git-ignored):

   ```bash
   cp share-access/SECRETS.template share-access/SECRETS
   ```

   Open `share-access/SECRETS` and fill in your AWS **access key id**, **secret
   access key**, and (optionally) the 12-digit **account id**.
2. Share the project:
   - **Via git:** commit and push. `share-access/` goes up, but `share-access/SECRETS`
     does not — it's git-ignored. Whoever clones recreates SECRETS from the
     template on their own machine.
   - **Via zip:** a zip *does* include `share-access/SECRETS`, so the recipient gets
     the credentials directly. Send it privately.
3. *(Optional — zero-install bash for a Windows recipient)* download the
   **64-bit Git for Windows Portable** archive from
   <https://git-scm.com/download/win> and extract it into `share-access/PortableGit/`
   so `git-bash.exe` sits directly in that folder. `open-git-bash.bat` will then
   use it and the recipient installs nothing. (`PortableGit/` is git-ignored, so
   it only travels in a zip.)

## Recipient — to set up on a new machine

1. Get the project (git clone or unzip).
2. **Open a shell in the project folder.**
   - **Windows (no WSL required):** double-click `share-access/open-git-bash.bat`.
     It opens Git Bash in the project folder. If no Git Bash is found it links
     *Git for Windows* — a normal per-user installer (no admin, no reboot);
     install it and double-click the `.bat` again.
   - **macOS / Linux:** open a terminal and `cd` into the project folder.
3. Make sure `share-access/SECRETS` exists and is filled in:
   - If you received a **zip**, it is probably already there.
   - If you **cloned from git**, create it:
     `cp share-access/SECRETS.template share-access/SECRETS`, then fill it in.
4. Run the setup script:

   ```bash
   bash share-access/setup.sh
   ```

   It installs the AWS CLI (and supporting tools), writes the `mc_server` AWS
   profile from `SECRETS`, and wires up `AWS_PROFILE`.
5. Open a fresh shell (on Windows, double-click the `.bat` again) — or run
   `export AWS_PROFILE=mc_server` — then use the deployment scripts:

   ```bash
   ./scripts/deploy.sh 1.20.4
   ./scripts/server-start.sh 1.20.4
   ./scripts/server-stop.sh 1.20.4
   ```

## ⚠️ Security

`share-access/SECRETS` holds live AWS credentials and is git-ignored, so it never
reaches GitHub. A project **zip** *does* contain it — share zips privately;
anyone with the credentials has the same AWS access as the owner. Never put
real credentials in `SECRETS.template` — that file **is** committed.
