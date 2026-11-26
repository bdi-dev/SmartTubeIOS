# NAS HTTPS over Tailscale — feature plan

> Status: proposed, not started. Personal-use build only. Independent of the other NAS plans and
> can be done at any point; it matters most once [personal tokens](2026-11-25-nas-multi-user.md)
> exist, because tokens should not travel in cleartext.

## Goal
Reach the NAS server over HTTPS with a certificate every device already trusts, and stop exposing
the plain HTTP port. Tailscale provides both the certificate and the private network.

## Approach
Use **Tailscale Serve** to terminate TLS in front of the existing server, with no change to
`server.py`. Serve gets a `*.ts.net` certificate from Tailscale (Let's Encrypt behind the scenes),
so iOS trusts it with no profile install.

## Steps
1. In the Tailscale admin console, enable **MagicDNS** and **HTTPS Certificates** for the tailnet.
2. Put Tailscale on the NAS. Preferred: a `tailscale` sidecar service in the `smarttube-ytdlp`
   Portainer stack (`TS_AUTHKEY` as a stack environment value, persistent state volume, `TS_SERVE_CONFIG`
   proxying `https:443` to `http://ytdlp:8787`). Alternative: the NAS's own Tailscale app and
   `tailscale serve --bg --https=443 http://127.0.0.1:8790`.
3. Verify from the iPhone (Tailscale app connected): `https://<name>.<tailnet>.ts.net/v1/health`
   loads in Safari with no warning.
4. Point the app at the new URL in Settings > NAS. Confirm library, download and playback.
5. Then close the old door: stop publishing `8790` on the LAN (bind it to loopback, or drop the
   `ports` entry when using the sidecar), and update the README and the how-to docs.

## Considerations
- **Devices must be on the tailnet.** Each person installs the Tailscale app and is invited to
  the tailnet (or the NAS node is shared to their tailnet). Tailscale "Funnel" (public internet) is
  deliberately not used.
- **Access control.** An ACL can restrict the NAS node to the family's devices, as defence in
  depth. Personal tokens still decide who can see which list.
- **Playback and large downloads** go through the Serve proxy; check seeking (range requests) works,
  since it streams MP4 files.
- **Fallback.** Keep the LAN HTTP port bound to loopback only; if Tailscale is down, use the
  Portainer console, not an open port.
- **App.** An `https://` base URL needs no code change. Review whether an ATS exception for plain
  HTTP can now be tightened; only do that if nothing else relies on it.

## Non-goals
- No public internet exposure, no custom domain, no certificate management in the server.
