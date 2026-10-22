# Security

RoomCast is a local, unauthenticated audio stream. Anyone who can reach the Mac on the listener port can hear it. That is intentional. Do not put the Mac on a network you do not trust, and do not forward the port to the internet.

## Reporting a vulnerability

Please use GitHub private vulnerability reporting:

https://github.com/walterkaan/public-earfi/security/advisories/new

Do not open a public issue for an unfixed security problem. Include the macOS version, how you reproduced the problem, and the output of **Copy diagnostics** if it does not itself contain secrets.

The RTSP publish port and the MediaMTX API are bound to 127.0.0.1. Please report it if a build listens on those ports from the LAN.
